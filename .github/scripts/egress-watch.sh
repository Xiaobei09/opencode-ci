#!/usr/bin/env bash
# Watch the OpenCode run log and the local proxy log. Rotate egress on quota
# errors or on repeated provider transport failures/timeouts. Stop the run after
# three consecutive failed egress recovery attempts, or after three preflight
# false positives (a candidate answers 200 but real generation hits quota
# within 600s). A stop is a **controlled end of round**: the workflow keeps the
# step green and relays a fresh run; only three consecutive no-success rounds
# pause the loop (operator rule R2520).
#
# Usage: egress-watch.sh <run-log> [proxy-log]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

LOG="${1:?usage: egress-watch.sh <run-log> [proxy-log]}"
PROXY_LOG="${2:-$EGRESS_STATE_DIR/proxy.log}"
mkdir -p "$EGRESS_STATE_DIR"
WATCH_LOG="$EGRESS_STATE_DIR/watch.log"
STOP_FILE="$EGRESS_STATE_DIR/stop"
: > "$WATCH_LOG"
rm -f "$STOP_FILE"

last=0
fail_until=0
trans_fails=0
trans_first=0
rotate_fail_streak=0
probe_false_streak=0
last_rotate_ok_at=0
# R2520（运营者）：每轮 CI 出问题时优先重选出口，但最多重选 3 次。
# 只统计 watcher 运行期的 rotate（不含启动时 select-proxy 的首次选择）。
reselections=0
RESELECT_LIMIT=3
# 全候选都返回 quota 的连续次数：账号级额度耗尽时，重选 IP 不会恢复额度。
# 连续 3 次仍全 quota 就受控停本轮，避免每 4 分钟 relay 一次的空转。
quota_streak=0

log() { echo "$(egress_iso) $*" >> "$WATCH_LOG"; }

log "watch start log=$LOG proxy_log=$PROXY_LOG upstream=$(cat "$EGRESS_UPSTREAM_FILE" 2>/dev/null || echo '?')"

# R2511: select-proxy may have picked a candidate seconds ago. Treat that
# preflight as the "200" side of the false-positive window, so a quota error
# right after startup (the operator-reported 11:04 case) is counted even though
# the watcher itself has not rotated yet. `fallback-direct` means no candidate
# actually passed, so it must not count.
if [ -f "$EGRESS_STATE_FILE" ]; then
  _src=$(jq -r '.source // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  _picked=$(jq -r '.picked_at // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  if [ -n "$_picked" ] && [ "$_src" != "fallback-direct" ]; then
    last_rotate_ok_at=$(date -u -d "$_picked" +%s 2>/dev/null || echo 0)
  fi
fi

while [ ! -f "$LOG" ]; do sleep 1; done
# The proxy is started immediately before this watcher, but make tail tolerant
# of a missing file during the first second.
[ -f "$PROXY_LOG" ] || : > "$PROXY_LOG"

stop_run() {
  local why="${1:-three consecutive egress recovery failures}"
  log "STOP: $why"
  printf '%s\n' "$why" > "$STOP_FILE"
  # Kill the long-lived interactive OpenCode process, not zengate's private
  # `opencode serve` backend (which has no --standalone flag).
  pkill -TERM -f 'opencode --standalone' 2>/dev/null || true
  sleep 2
  pkill -KILL -f 'opencode --standalone' 2>/dev/null || true
  exit 0
}

rotate() {
  local reason="$1" rc
  reselections=$((reselections + 1))
  if [ "$reselections" -gt "$RESELECT_LIMIT" ]; then
    stop_run "egress re-selection limit exceeded (${reselections}/${RESELECT_LIMIT}); pausing the loop"
  fi
  log "reselection ${reselections}/${RESELECT_LIMIT} reason=$reason"
  log "rotating egress reason=$reason"
  bash "$SCRIPT_DIR/egress-rotate.sh" --reason "$reason" >> "$WATCH_LOG" 2>&1
  rc=$?
  last=$(egress_now)
  if [ "$rc" -eq 0 ]; then
    rotate_fail_streak=0
    quota_streak=0
    last_rotate_ok_at=$last
    state=$(jq -c '{kind,upstream,egress_ip}' "$EGRESS_STATE_FILE" 2>/dev/null || echo '{}')
    log "rotate ok $state"
  elif [ "$rc" -eq 2 ]; then
    # Every candidate answered quota. This is account-wide: retrying another IP
    # cannot buy quota back. Count consecutive all-quota rotations and stop the
    # round after 3 (operator rule: any failure 3x => controlled stop), with a
    # short 30s backoff so the 3 attempts can fit inside one run.
    quota_streak=$((quota_streak + 1))
    last_rotate_ok_at=0
    fail_until=$((last + 30))
    log "rotate skipped: all candidates quota-limited (streak=$quota_streak/3); keeping current egress (backoff 30s)"
    if [ "$quota_streak" -ge 3 ]; then
      stop_run "three consecutive all-candidate quota rotations; pausing the loop"
    fi
  else
    rotate_fail_streak=$((rotate_fail_streak + 1))
    last_rotate_ok_at=0
    fail_until=$((last + 60))
    log "rotate failed (streak=$rotate_fail_streak/3); keeping current egress"
    if [ "$rotate_fail_streak" -ge 3 ]; then
      stop_run "three consecutive egress rotation failures"
    fi
  fi
  # 第 3 次重选后无论成功与否都受控结束本轮：relay 起的新 run 会重新做一次
  # 完整出口选择；继续留在本轮只会在同一额度/代理问题上空转。
  if [ "$reselections" -ge "$RESELECT_LIMIT" ]; then
    stop_run "reached ${RESELECT_LIMIT} egress re-selections this round (last reason=$reason rc=$rc); pausing the loop"
  fi
}

while IFS= read -r line; do
  now=$(egress_now)
  case "$line" in
    *"Free usage limit reached"*|*"FreeUsageLimitError"*|*"free usage limit reached"*|*"provider.free-limit"*)
      # R2511: a candidate that answered 200 but hits quota within 120s is a
      # false positive, not a real recovery. Count it even inside the 20s
      # rotation cool-down (the cool-down only suppresses another rotation).
      if [ "$last_rotate_ok_at" -gt 0 ] && [ $((now - last_rotate_ok_at)) -le 120 ]; then
        probe_false_streak=$((probe_false_streak + 1))
        log "preflight false positive: 200 then quota after $((now - last_rotate_ok_at))s (streak=$probe_false_streak/3)"
        last_rotate_ok_at=0
        if [ "$probe_false_streak" -ge 3 ]; then
          stop_run "three consecutive preflight false positives (200 then quota)"
        fi
      fi
      if [ "$now" -lt "$fail_until" ] || [ $((now - last)) -lt 20 ]; then
        continue
      fi
      log "quota error detected"
      rotate quota
      ;;
    *idle_timeout*)
      if [ "$now" -lt "$fail_until" ] || [ $((now - last)) -lt 20 ]; then
        continue
      fi
      log "provider tunnel idle timeout detected: ${line:0:240}"
      trans_fails=0
      rotate transport
      ;;
    *"error target="*opencode.ai*)
      if [ "$now" -lt "$fail_until" ] || [ $((now - last)) -lt 20 ]; then
        continue
      fi
      if [ "$trans_fails" -eq 0 ]; then trans_first=$now; fi
      trans_fails=$((trans_fails + 1))
      log "provider transport error detected ($trans_fails in $((now - trans_first))s): ${line:0:240}"
      if [ "$trans_fails" -ge 2 ] && [ $((now - trans_first)) -le 60 ]; then
        trans_fails=0
        rotate transport
      fi
      ;;
    *"connect "*"target="*opencode.ai*"upstream="*)
      if [ "$trans_fails" -ne 0 ]; then
        log "provider connection recovered; reset transport error streak"
        trans_fails=0
      fi
      ;;
  esac
done < <(tail -n +1 -F -- "$LOG" "$PROXY_LOG" 2>/dev/null)

log "watch end"
