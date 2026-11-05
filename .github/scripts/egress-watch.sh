#!/usr/bin/env bash
# Watch the structured plugin log and the local proxy log. NEVER parse the TUI
# run log: it contains the assistant's own prose (and our diagnostics), so words
# like `idle_timeout`/`quota` in a report would self-trigger rotations. The
# proxy log carries transport/idle events; the plugin log carries provider
# errors (`error=provider.free-limit`) and healthy-turn markers. Rotate egress
# on quota errors or on repeated provider transport failures/timeouts. Stop the run after
# three consecutive failed egress recovery attempts, or after three preflight
# false positives (a candidate answers 200 but real generation hits quota
# within 120s). A stop is a **controlled end of round**: the workflow keeps the
# step green and relays a fresh run; only three consecutive no-success rounds
# pause the loop (operator rule R2520).
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
# 全候选都返回 quota 的连续次数：匿名免费额度按出口 IP 计（实测 05:15:25
# relay 429 → 05:15:34 换 IP → 05:16:25 healthy turn）。egress-rotate 用
# run-scoped 列表避免同一轮反复探测已 quota 的 IP；连续 3 次仍全 quota 则受控
# 停本轮，新 run 重新选新鲜 IP。
quota_streak=0

log() { echo "$(egress_iso) $*" >> "$WATCH_LOG"; }

# R2544：插件日志有两种 quota 行——`rate-limit/quota error (... upstream=...)`
# 和 `eval ... error=provider.free-limit`。后者没有 upstream=，rotate 后 tail
# 仍会读到 rotate 前的同一批错误，被误算成“200 then quota after 0s”。
# 这里按行首 ISO 时间戳判定：早于最近一次成功 rotate 的行一定是旧账。
line_epoch() {
  local ts
  ts=$(printf '%s' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z' | head -1)
  [ -n "$ts" ] || return 1
  date -u -d "$ts" +%s 2>/dev/null || return 1
}

CUR_UP=$(cat "$EGRESS_UPSTREAM_FILE" 2>/dev/null || echo '?')
log "watch start run_log=$LOG proxy_log=$PROXY_LOG plugin_log=$PLUGIN_LOG upstream=$CUR_UP"

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
    stop_run "egress re-selection limit exceeded (${reselections}/${RESELECT_LIMIT}); ending this round (relay unless 3 consecutive rounds without success)"
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
    CUR_UP=$(jq -r '.upstream // "?"' "$EGRESS_STATE_FILE" 2>/dev/null || echo '?')
    state=$(jq -c '{kind,upstream,egress_ip}' "$EGRESS_STATE_FILE" 2>/dev/null || echo '{}')
    log "rotate ok $state"
  elif [ "$rc" -eq 2 ]; then
    # Every probed candidate answered quota. Quota is anonymous/IP-scoped, but
    # this run has exhausted its fresh-IP probe budget (egress-rotate's
    # run-scoped quota-blocked list). Count consecutive all-quota rotations and
    # stop the round after 3 (operator rule: any failure 3x => controlled stop),
    # then relay a fresh run that re-selects fresh egress IPs.
    quota_streak=$((quota_streak + 1))
    last_rotate_ok_at=0
    fail_until=$((last + 30))
    log "rotate skipped: all probed candidates quota-limited (streak=$quota_streak/3); keeping current egress (backoff 30s)"
    if [ "$quota_streak" -ge 3 ]; then
      stop_run "three consecutive all-candidate quota rotations; ending this round (anonymous quota is IP-scoped; relay gives the next run fresh egress IPs)"
    fi
  else
    rotate_fail_streak=$((rotate_fail_streak + 1))
    last_rotate_ok_at=0
    fail_until=$((last + 60))
    log "rotate failed (streak=$rotate_fail_streak/3); keeping current egress"
    if [ "$rotate_fail_streak" -ge 3 ]; then
      stop_run "three consecutive egress rotation failures; ending this round"
    fi
  fi
  # 第 3 次重选后无论成功与否都受控结束本轮：relay 起的新 run 会重新做一次
  # 完整出口选择；继续留在本轮只会在同一额度/代理问题上空转。
  if [ "$reselections" -ge "$RESELECT_LIMIT" ]; then
    stop_run "reached ${RESELECT_LIMIT} egress re-selections this round (last reason=$reason rc=$rc); ending this round (relay unless 3 consecutive rounds without success)"
  fi
}

while IFS= read -r line; do
  now=$(egress_now)
  case "$line" in
    *"Free usage limit reached"*|*"FreeUsageLimitError"*|*"free usage limit reached"*|*"provider.free-limit"*)
      # R2535：插件日志会带 `upstream=relay:...`。rotate 后 tail 仍可能读到
      # rotate 之前那一轮的延迟日志；若 upstream 已不是当前出口，它既不是
      # 新出口的误报，也不该再次触发 rotate（实测 03:13:24 把旧 relay 的
      # 延迟 quota 行算成 “200 then quota after 0s”）。
      err_up=$(printf '%s' "$line" | sed -nE 's/.*upstream=([^ )]+).*/\1/p' | head -1)
      if [ -n "$err_up" ] && [ "$CUR_UP" != "?" ] && [ "$err_up" != "$CUR_UP" ]; then
        log "stale quota line from upstream=$err_up (current=$CUR_UP); ignoring"
        continue
      fi
      # R2544：无 upstream 的 eval 行按时间戳丢弃 rotate 前的旧错误。
      if [ "$last_rotate_ok_at" -gt 0 ]; then
        err_at=$(line_epoch "$line" || true)
        if [ -n "$err_at" ] && [ "$err_at" -lt "$last_rotate_ok_at" ]; then
          log "stale quota line predates rotation (line_ts=$err_at, rotate=$last_rotate_ok_at); ignoring"
          continue
        fi
      fi
      # R2511: a candidate that answered 200 but hits quota within 120s is a
      # false positive, not a real recovery. Count it even inside the 20s
      # rotation cool-down (the cool-down only suppresses another rotation).
      if [ "$last_rotate_ok_at" -gt 0 ] && [ $((now - last_rotate_ok_at)) -le 120 ]; then
        probe_false_streak=$((probe_false_streak + 1))
        log "preflight false positive: 200 then quota after $((now - last_rotate_ok_at))s (streak=$probe_false_streak/3)"
        last_rotate_ok_at=0
        if [ "$probe_false_streak" -ge 3 ]; then
          stop_run "three consecutive preflight false positives (200 then quota); anonymous free quota is IP-scoped, but this egress IP still hit quota within 120s; ending the round so the next run selects fresh IPs"
        fi
      fi
      if [ "$now" -lt "$fail_until" ] || [ $((now - last)) -lt 20 ]; then
        continue
      fi
      log "quota error detected"
      rotate quota
      ;;
    *"auto-continue: healthy turn"*)
      # R2536：只认 auto-continue 在**真实正常回合**写下的结构化日志。旧实现
      # 匹配 `injected round prompt`，但那只是注入动作；实测注入后同一 upstream
      # 立即 quota，会错误重置误报窗口。正常回合跑通才说明 rotate 后的 200 不是误报。
      if [ "$probe_false_streak" -ne 0 ] || [ "$last_rotate_ok_at" -gt 0 ]; then
        log "healthy turn after rotation; reset preflight false-positive window (streak=$probe_false_streak)"
        probe_false_streak=0
        last_rotate_ok_at=0
      fi
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
done < <(tail -q -n +1 -F -- "$PROXY_LOG" "$PLUGIN_LOG" 2>/dev/null)

log "watch end"
