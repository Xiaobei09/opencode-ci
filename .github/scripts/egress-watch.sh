#!/usr/bin/env bash
# Watch the structured plugin log and the local proxy log. NEVER parse the TUI
# run log: it contains the assistant's own prose (and our diagnostics), so words
# like `idle_timeout`/`quota` in a report would self-trigger false alarms.
#
# R2562 (operator): the egress is selected exactly once in the "Select egress
# proxy" step. This watcher no longer rotates or re-selects inside a run. It
# only:
#   - counts consecutive quota / transport failures and stops the round after 3
#     (the relay then starts a fresh run that selects a new egress);
#   - if the selected egress answered 200 in preflight but hits quota within
#     120s, blacklists it for 6h and stops this round immediately;
#   - resets the consecutive-failure counter on a real healthy turn.
# A stop is a controlled end of round: the workflow keeps the step green and
# relays a fresh run; only three consecutive no-success rounds pause the loop.
#
# Usage: egress-watch.sh <run-log> [proxy-log] [plugin-log]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

LOG="${1:?usage: egress-watch.sh <run-log> [proxy-log] [plugin-log]}"
PROXY_LOG="${2:-$EGRESS_STATE_DIR/proxy.log}"
PLUGIN_LOG="${3:-${AC_TAP_PATH:-/tmp/opencode/v2plugin.log}}"
mkdir -p "$EGRESS_STATE_DIR"
WATCH_LOG="$EGRESS_STATE_DIR/watch.log"
STOP_FILE="$EGRESS_STATE_DIR/stop"
: > "$WATCH_LOG"
rm -f "$STOP_FILE"

# The blacklist is persisted under $HOME/.config/opencode and restored across
# runs. Ensure it exists before a 200->quota event tries to write to it.
egress_bl_init
egress_bl_prune

FAIL_LIMIT=3
PROBE_FALSE_WINDOW=120
FAIL_DEDUPE_SECONDS=20

fail_streak=0
last_fail_at=0
selected_at=0
selected_kind=""
selected_egress=""
selected_direct_ip=""

log() { echo "$(egress_iso) $*" >> "$WATCH_LOG"; }

# Plugin log lines carry an ISO timestamp. Quota lines without `upstream=`
# can still be stale after a previous run's state was restored; drop anything
# older than the selection this run.
line_epoch() {
  local ts
  ts=$(printf '%s' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z' | head -1)
  [ -n "$ts" ] || return 1
  date -u -d "$ts" +%s 2>/dev/null || return 1
}

if [ -f "$EGRESS_STATE_FILE" ]; then
  selected_kind=$(jq -r '.kind // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  selected_egress=$(jq -r '.egress_ip // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  selected_direct_ip=$(jq -r '.direct_ip // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  _picked=$(jq -r '.picked_at // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  if [ -n "$_picked" ]; then
    selected_at=$(date -u -d "$_picked" +%s 2>/dev/null || echo 0)
  fi
fi

CUR_UP=$(cat "$EGRESS_UPSTREAM_FILE" 2>/dev/null || echo '?')
if [ "$CUR_UP" = "?" ] && [ -n "$selected_kind" ]; then
  case "$selected_kind" in
    direct) CUR_UP="direct" ;;
    relay|http)
      _up=$(jq -r '.upstream // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
      [ -n "$_up" ] && CUR_UP="$_up"
      ;;
  esac
fi
log "watch start run_log=$LOG proxy_log=$PROXY_LOG plugin_log=$PLUGIN_LOG upstream=$CUR_UP selected_at=$selected_at mode=select-once"

while [ ! -f "$LOG" ]; do sleep 1; done
# The proxy is started immediately before this watcher, but make tail tolerant
# of a missing file during the first second.
[ -f "$PROXY_LOG" ] || : > "$PROXY_LOG"

stop_run() {
  local why="${1:-three consecutive egress failures}"
  log "STOP: $why"
  printf '%s\n' "$why" > "$STOP_FILE"
  # Kill the long-lived interactive OpenCode process, not zengate's private
  # `opencode serve` backend (which has no --standalone flag).
  pkill -TERM -f 'opencode --standalone' 2>/dev/null || true
  sleep 2
  pkill -KILL -f 'opencode --standalone' 2>/dev/null || true
  exit 0
}

# record_failure <quota|transport> <log-line>
# Count one distinct failure per 20s window. A single provider failure often
# produces several log lines; counting each would stop the round prematurely.
record_failure() {
  local kind="$1" line="$2" now
  now=$(egress_now)
  if [ "$last_fail_at" -gt 0 ] && [ $((now - last_fail_at)) -lt "$FAIL_DEDUPE_SECONDS" ]; then
    log "duplicate $kind failure within ${FAIL_DEDUPE_SECONDS}s ignored (streak=$fail_streak/$FAIL_LIMIT, upstream=$CUR_UP): ${line:0:200}"
    return 0
  fi
  fail_streak=$((fail_streak + 1))
  last_fail_at=$now
  log "egress failure kind=$kind (streak=$fail_streak/$FAIL_LIMIT, upstream=$CUR_UP): ${line:0:240}"
  if [ "$fail_streak" -ge "$FAIL_LIMIT" ]; then
    stop_run "three consecutive egress failures (last=$kind, upstream=$CUR_UP); ending this round so the next run selects a fresh egress"
  fi
}

# blacklist_selected <reason>
# Persist the selected candidate for 6h. Direct keys include the runner egress
# IP so they never match a future runner, which is intended: the direct path is
# still allowed, but this exact exhausted IP must not be reused in this run.
blacklist_selected() {
  local reason="$1" key=""
  case "$CUR_UP" in
    relay:*) key="$CUR_UP" ;;
    http:*)  key="$CUR_UP" ;;
    direct)  key="direct:${selected_direct_ip:-unknown}" ;;
  esac
  if [ -z "$key" ]; then
    log "cannot blacklist selected egress: upstream=$CUR_UP has no candidate key"
    return 1
  fi
  if egress_bl_add "$key" "${selected_egress:-}" "$reason" 21600; then
    log "blacklisted $key for 21600s reason=$reason egress=${selected_egress:-?}"
  else
    log "warning: failed to persist blacklist entry for $key reason=$reason"
    return 1
  fi
}

# handle_quota <line>
handle_quota() {
  local line="$1" now err_up err_at
  now=$(egress_now)

  # Delayed lines from an upstream other than the one this run selected are
  # not evidence about the current egress.
  err_up=$(printf '%s' "$line" | sed -nE 's/.*upstream=([^ )]+).*/\1/p' | head -1)
  if [ -n "$err_up" ] && [ "$CUR_UP" != "?" ] && [ "$err_up" != "$CUR_UP" ]; then
    log "stale quota line from upstream=$err_up (current=$CUR_UP); ignoring"
    return 0
  fi
  if [ "$selected_at" -gt 0 ]; then
    err_at=$(line_epoch "$line" || true)
    if [ -n "$err_at" ] && [ "$err_at" -lt "$selected_at" ]; then
      log "stale quota line predates selection (line_ts=$err_at, selected=$selected_at); ignoring"
      return 0
    fi
  fi

  # Operator priority: a candidate that passed the real 200 preflight but hits
  # anonymous free quota within 120s is exhausted. Do not rotate inside the
  # run; blacklist it for 6h and let the next run select a fresh egress.
  if [ "$selected_at" -gt 0 ] && [ $((now - selected_at)) -le "$PROBE_FALSE_WINDOW" ]; then
    log "selected egress answered 200 in preflight but hit quota after $((now - selected_at))s (upstream=$CUR_UP); stopping this round and blacklisting for 6h"
    blacklist_selected "quota-after-preflight-200" || true
    stop_run "selected egress $CUR_UP answered 200 in preflight but hit quota after $((now - selected_at))s; blacklisted for 21600s; ending this round so the next run selects a fresh egress"
  fi

  log "quota error detected (upstream=$CUR_UP)"
  record_failure quota "$line"
}

while IFS= read -r line; do
  case "$line" in
    *"Free usage limit reached"*|*"FreeUsageLimitError"*|*"free usage limit reached"*|*"provider.free-limit"*)
      handle_quota "$line"
      ;;
    *"auto-continue: healthy turn"*)
      # R2536: only a real healthy turn proves the selected egress works. The
      # injection action itself is not evidence. R2562: reset every consecutive
      # failure counter here; otherwise non-consecutive failures across healthy
      # turns accumulate to 3 and stop a healthy round (same class as R2559).
      if [ "$fail_streak" -ne 0 ] || [ "$last_fail_at" -ne 0 ]; then
        log "healthy turn; reset consecutive egress failure counter (was streak=$fail_streak/$FAIL_LIMIT)"
        fail_streak=0
        last_fail_at=0
      fi
      ;;
    *idle_timeout*)
      log "provider tunnel idle timeout detected: ${line:0:240}"
      record_failure transport "$line"
      ;;
    *"error target="*opencode.ai*)
      log "provider transport error detected: ${line:0:240}"
      record_failure transport "$line"
      ;;
    *"connect "*"target="*opencode.ai*"upstream="*)
      # Diagnostic only. A TCP tunnel does not prove the inference request will
      # succeed (quota is evaluated at the provider), so do not reset the
      # failure streak here; only a healthy turn does that.
      log "provider connection established (diagnostic, upstream=$CUR_UP)"
      ;;
  esac
done < <(tail -q -n +1 -F -- "$PROXY_LOG" "$PLUGIN_LOG" 2>/dev/null)

log "watch end"
