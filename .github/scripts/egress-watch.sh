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

# blacklist_selected <reason> [ttl-seconds]
# Persist the selected candidate for at least 6h (or the provider's Retry-After,
# whichever is longer). Direct keys include the runner egress
# IP so they never match a future runner, which is intended: the direct path is
# still allowed, but this exact exhausted IP must not be reused in this run.
blacklist_selected() {
  local reason="$1" ttl="${2:-21600}" key=""
  case "$CUR_UP" in
    relay:*) key="$CUR_UP" ;;
    http:*)  key="$CUR_UP" ;;
    direct)  key="direct:${selected_direct_ip:-unknown}" ;;
  esac
  if [ -z "$key" ]; then
    log "cannot blacklist selected egress: upstream=$CUR_UP has no candidate key"
    return 1
  fi
  if egress_bl_add "$key" "${selected_egress:-}" "$reason" "$ttl"; then
    log "blacklisted $key for ${ttl}s reason=$reason egress=${selected_egress:-?}"
  else
    log "warning: failed to persist blacklist entry for $key reason=$reason"
    return 1
  fi
}

# current_egress_ip: ask the same proxy the OpenCode process uses. The probe
# host must be a provider host: the local proxy only routes provider traffic
# through the selected upstream, so www.cloudflare.com would always report the
# runner's direct IP even when a relay is in use (R2567).
current_egress_ip() {
  if [ "${EGRESS_WATCH_SKIP_EGRESS_PROBE:-0}" = "1" ]; then
    echo "skipped"
    return 0
  fi
  curl -sS -m "${EGRESS_WATCH_TRACE_TIMEOUT:-8}" \
    -x "http://127.0.0.1:${EGRESS_LOCAL_PORT}" \
    "$EGRESS_TRACE_URL" 2>/dev/null \
    | sed -n 's/^ip=//p' | head -1
}

# R2582 (operator rollback): direct is a supported production egress again.
# Do NOT stop the run just because upstream=direct; the free quota is per
# egress IP and a fresh runner IP is usually the freshest bucket.

# R2567 (operator priority): verify before the first turn that provider traffic
# really leaves through the selected upstream. A relay selection that reports
# the runner's own direct IP means the proxy bypassed the relay (silent direct);
# a different non-direct IP means the relay rotated its exit after selection —
# the known "preflight 200 but immediate 429" failure mode. Both cases end the
# round instead of spending the remaining budget on an unverified path.
provider_egress=""
if [ "${EGRESS_WATCH_SKIP_EGRESS_PROBE:-0}" != "1" ]; then
  provider_egress=$(current_egress_ip 2>/dev/null || true)
fi
log "egress path check kind=${selected_kind:-?} upstream=$CUR_UP selected_egress=${selected_egress:-?} provider_egress=${provider_egress:-unreachable} direct_ip=${selected_direct_ip:-?}"
case "$selected_kind" in
  relay|http)
    if [ -n "$provider_egress" ] && [ -n "$selected_direct_ip" ] \
       && [ "$provider_egress" = "$selected_direct_ip" ]; then
      log "CRITICAL: provider egress equals the runner direct IP ($provider_egress); the selected $selected_kind upstream was bypassed — no silent direct allowed"
      stop_run "provider traffic bypassed the selected $selected_kind upstream (provider_egress=$provider_egress equals direct_ip); refusing silent direct"
    elif [ -n "$provider_egress" ] && [ -n "$selected_egress" ] \
         && [ "$provider_egress" != "$selected_egress" ]; then
      log "CRITICAL: provider egress rotated after selection (selected=$selected_egress provider=$provider_egress); blacklisting candidate for 21600s"
      blacklist_selected "egress-rotation-before-run" 21600 || true
      stop_run "selected $selected_kind upstream egress rotated before the first turn (selected=$selected_egress provider=$provider_egress); ending this round so the next run selects a fresh egress"
    fi
    ;;
  direct)
    if [ -n "$provider_egress" ] && [ -n "$selected_direct_ip" ] \
       && [ "$provider_egress" != "$selected_direct_ip" ]; then
      log "warning: direct egress changed after selection (selected=$selected_direct_ip provider=$provider_egress); keeping the run"
    fi
    ;;
esac

# handle_quota <line>
handle_quota() {
  local line="$1" now err_up err_at msg_at msg_at_epoch retry_after ttl cur_egress
  now=$(egress_now)

  # R2566 (operator priority: still widespread 429 after a 200 preflight):
  # only the structured quota line emitted by auto-continue is evidence. Other
  # plugin lines also contain the error name (`eval ... error=provider.free-limit
  # -> RECOVER`, tg-bridge error cards), and treating them as quota made three
  # fresh relays look exhausted at ~63s in R2565. Require the explicit source
  # marker plus positive this_run=true; unverifiable lines are ignored.
  if ! printf '%s' "$line" | grep -q 'src=auto-continue'; then
    log "quota-like line without src=auto-continue; ignoring for stop/blacklist: ${line:0:220}"
    return 0
  fi
  if ! printf '%s' "$line" | grep -q 'this_run=true'; then
    log "stale/unattributed quota line (this_run!=true); ignoring"
    return 0
  fi
  msg_at=$(printf '%s' "$line" | sed -nE 's/.*msg_at=([^ ,)]+).*/\1/p' | head -1)
  if [ -z "$msg_at" ] || [ "$msg_at" = "?" ]; then
    # No timestamp means we cannot prove the error belongs to this run. The
    # plugin's own 3-consecutive-error policy still ends a genuinely bad round.
    log "quota line has no parseable msg_at; ignoring for stop/blacklist"
    return 0
  fi
  msg_at_epoch=$(date -u -d "$msg_at" +%s 2>/dev/null || true)
  if [ -z "$msg_at_epoch" ] || [ "$selected_at" -le 0 ]; then
    log "quota line unverifiable (msg_at=$msg_at epoch=${msg_at_epoch:-?} selected_at=$selected_at); ignoring for stop/blacklist"
    return 0
  fi
  if [ "$msg_at_epoch" -lt "$selected_at" ]; then
    log "stale quota line msg_at=$msg_at predates selection (selected=$selected_at); ignoring"
    return 0
  fi

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
  # run; blacklist it for at least 6h and let the next run select a fresh
  # egress. R2565: the provider's Retry-After was observed at ~12.9h; honoring
  # it avoids retrying the same exhausted IP before its bucket resets.
  retry_after=$(printf '%s' "$line" | sed -nE 's/.*retry_after_s=([0-9]+).*/\1/p' | head -1)
  ttl=21600
  if [ -n "$retry_after" ] && [ "$retry_after" -gt "$ttl" ] 2>/dev/null; then ttl="$retry_after"; fi
  if [ "$selected_at" -gt 0 ] && [ $((now - selected_at)) -le "$PROBE_FALSE_WINDOW" ]; then
    cur_egress=$(current_egress_ip || true)
    [ -n "$cur_egress" ] || cur_egress="?"
    log "selected egress answered 200 in preflight but hit quota after $((now - selected_at))s (upstream=$CUR_UP, selected_egress=${selected_egress:-?}, current_egress=$cur_egress, retry_after=${retry_after:-?}s, msg_at=$msg_at); stopping this round and blacklisting for ${ttl}s"
    if [ "$cur_egress" != "?" ] && [ -n "$selected_egress" ] && [ "$cur_egress" != "$selected_egress" ]; then
      log "warning: relay egress rotated after selection (selected=$selected_egress current=$cur_egress); quota was hit on the current exit but the candidate entry stayed the same"
    fi
    blacklist_selected "quota-after-preflight-200" "$ttl" || true
    stop_run "selected egress $CUR_UP answered 200 in preflight but hit quota after $((now - selected_at))s (current_egress=$cur_egress); blacklisted for ${ttl}s; ending this round so the next run selects a fresh egress"
  fi

  log "quota error detected (upstream=$CUR_UP, retry_after=${retry_after:-?}s)"
  # A quota error after the 120s preflight window still means this egress IP is
  # exhausted (possibly after a long healthy run). Keep it out of future
  # selection for the provider's reset window too.
  if [ "$selected_at" -gt 0 ] && [ $((now - selected_at)) -gt "$PROBE_FALSE_WINDOW" ]; then
    blacklist_selected "quota-after-healthy-window" "$ttl" || true
    # R2594 (D8): a verified Free usage limit with a long Retry-After is bucket
    # exhaustion, not a transient burst. Waiting for the 3-consecutive policy
    # spent two more auto-continue turns (~2 min) on an egress that cannot
    # recover within the run; the bucket is per egress IP and refills only when
    # the provider's Retry-After elapses. End the round now so the relay starts
    # the next run with a fresh runner IP. Short/unparseable Retry-After keeps
    # the streak policy (possible burst window).
    if [ -z "$retry_after" ] \
       || [ "$retry_after" -ge "${EGRESS_QUOTA_HARD_STOP_SECONDS:-600}" ] 2>/dev/null; then
      stop_run "quota exhausted on egress $CUR_UP after $((now - selected_at))s (retry_after=${retry_after:-?}s); blacklisted for ${ttl}s; ending this round so the next run selects a fresh egress"
    fi
  fi
  record_failure quota "$line"
}

# R2578 (operator: "200 后仍 429"): the startup check only proves the first
# minute. A relay can rotate its exit (or silently bypass to the runner IP)
# after the first provider turn. Re-check through the same local proxy every
# EGRESS_WATCH_RECHECK_SECONDS (default 300s); a changed/leaked egress stops the
# round and blacklists the candidate, so the next run selects a fresh relay.
RECHECK_SECONDS="${EGRESS_WATCH_RECHECK_SECONDS:-300}"
last_path_check=$(egress_now)

while IFS= read -r line; do
  now=$(egress_now)
  if [ "${EGRESS_WATCH_SKIP_EGRESS_PROBE:-0}" != "1" ] \
     && { [ "$selected_kind" = "relay" ] || [ "$selected_kind" = "http" ]; } \
     && [ "${RECHECK_SECONDS:-0}" -gt 0 ] 2>/dev/null \
     && [ $((now - last_path_check)) -ge "$RECHECK_SECONDS" ]; then
    last_path_check=$now
    cur=$(current_egress_ip 2>/dev/null || true)
    if [ -n "$cur" ] && [ -n "$selected_direct_ip" ] && [ "$cur" = "$selected_direct_ip" ]; then
      log "CRITICAL: provider egress during run equals the runner direct IP ($cur); the selected $selected_kind upstream was bypassed"
      stop_run "provider traffic bypassed the selected $selected_kind upstream during the run (provider_egress=$cur equals direct_ip); refusing silent direct"
    elif [ -n "$cur" ] && [ -n "$selected_egress" ] && [ "$cur" != "$selected_egress" ]; then
      log "CRITICAL: provider egress changed during run (selected=$selected_egress current=$cur); stopping and blacklisting the candidate"
      blacklist_selected "egress-rotation-during-run" 21600 || true
      stop_run "selected $selected_kind upstream egress rotated during the run (selected=$selected_egress current=$cur); ending this round so the next run selects a fresh egress"
    else
      log "egress path recheck ok (kind=$selected_kind egress=${cur:-unreachable})"
    fi
  fi
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
    *"close "*"target="*opencode.ai*"upstream="*)
      # R2594 (D8): byte accounting proves whether the tunnel carried a real
      # turn (100k+ prompt tokens, hundreds of KB) or only a small probe. This
      # is the direct answer to "did the endpoint really use the proxy exit?".
      log "provider tunnel closed (${line:0:220})"
      ;;
  esac
done < <(tail -q -n +1 -F -- "$PROXY_LOG" "$PLUGIN_LOG" 2>/dev/null)

log "watch end"
