#!/usr/bin/env bash
# R2884 (operator: "增加一个模式让换出口代替ci重启"): hot-switch engine for
# EGRESS_HOT_SWITCH=1. run-opencode.sh is the only caller: after a verified
# quota 429 (or a manual /proxy next) it rotates the local proxy's upstream and
# restarts only the OpenCode process inside the same CI run. The watcher still
# never rotates (R2562); outside this mode the workflow still selects exactly
# once per run. Do not wire this into egress-watch.sh.
#
# Move the local CONNECT proxy to the next candidate that passes the preflight.
# The current candidate is skipped first, so a quota-exhausted relay is not
# retried immediately. With the default path preflight this spends no provider
# message; set EGRESS_PREFLIGHT_MODE=zengate to use the real-OpenCode probe.
#
# Usage: egress-rotate.sh [--reason quota|manual|transport|http]
#
# The candidate list is produced by select-proxy.sh:
#   <direct|relay|http>\t<target>\t<source>
# with target "-" for direct.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

# R2511: rotate with the same model the real session uses (see
# egress_probe_model); a big-pickle probe can 200 while deepseek is exhausted.
export EGRESS_PROBE_MODEL="${EGRESS_PROBE_MODEL:-$(egress_probe_model)}"

REASON="${1:-quota}"
[ "$REASON" = "--reason" ] && REASON="${2:-quota}"
case "$REASON" in
  quota)     TTL=1800 ;;  # 30m: anonymous free quota is IP-scoped; cool the limited IP down
  transport) TTL=1800 ;;  # 30m for dead relays
  manual)    TTL=600 ;;   # operator asked to move; only failed candidates cool down
  *)         TTL=3600  ;;
esac

egress_bl_init
egress_bl_prune
mkdir -p "$EGRESS_STATE_DIR"
[ -f "$EGRESS_CANDIDATES_FILE" ] || { echo "rotate: no candidate list"; exit 1; }

PREFLIGHT_TMO="${EGRESS_PREFLIGHT_TIMEOUT:-20}"
# R2884: use the same preflight mode as the run's selection. The default
# zero-message path probe is important here: a hot switch happens right after a
# quota 429, and a real-inference probe on the new exit could spend the fresh
# message and reproduce "probe 200, real turn 429".
PROBE_ENGINE="${EGRESS_PREFLIGHT_MODE:-path}"
case "$PROBE_ENGINE" in
  path|zengate|curl) ;;
  *) echo "rotate: warning: unknown EGRESS_PREFLIGHT_MODE=$PROBE_ENGINE; using path"; PROBE_ENGINE=path ;;
esac
if [ "$PROBE_ENGINE" = "zengate" ]; then
  if bash "$SCRIPT_DIR/egress-probe-server.sh" start; then
    trap 'bash "$SCRIPT_DIR/egress-probe-server.sh" stop' EXIT
    echo "rotate: preflight engine=zengate model=$EGRESS_PROBE_MODEL (real OpenCode, fresh session per candidate)"
  else
    echo "rotate: warning: zengate probe unavailable; falling back to zero-message path preflight"
    PROBE_ENGINE=path
  fi
else
  echo "rotate: preflight engine=$PROBE_ENGINE (path spends no provider message)"
fi

CUR_KIND=$(jq -r '.kind // "direct"' "$EGRESS_STATE_FILE" 2>/dev/null || echo direct)
CUR_UP=$(jq -r '.upstream // "direct"' "$EGRESS_STATE_FILE" 2>/dev/null || echo direct)
DIRECT_IP=$(jq -r '.direct_ip // empty' "$EGRESS_STATE_FILE" 2>/dev/null || true)
[ -n "$DIRECT_IP" ] || DIRECT_IP=$(egress_trace_direct)
[ -n "$DIRECT_IP" ] || DIRECT_IP="unknown"

case "$CUR_KIND" in
  direct) CUR_KEY="direct:$DIRECT_IP" ;;
  *)      CUR_KEY="$CUR_UP" ;;
esac

# R2546（运营者：没有登录账号、使用匿名，429 不可能是账号限制）：免费额度按
# **出口 IP** 计。实测 05:15:25 relay 126.217.78.118 → 429，05:15:34 换到
# 114.204.39.195，05:16:25 即 healthy turn（新 IP ⇒ 新额度）。因此同一轮内
# 绝不能反复探测已经 quota 的 IP：用 run-scoped 列表记住它们，每次 rotate 都
# 往后面的新鲜候选推进。新 run 的 RUNNER_TEMP/egress 是新目录，列表自动清空。
# transport 失败仍走原有黑名单/全量候选预算。
MAX_TRIES=${EGRESS_SELECT_MAX:-12}
[ "$REASON" = "quota" ] && MAX_TRIES=${EGRESS_QUOTA_PROBE_MAX:-4}
[ "$REASON" = "manual" ] && MAX_TRIES=${EGRESS_HOT_SWITCH_PROBE_MAX:-4}

QUOTA_BLOCKED_FILE="$EGRESS_STATE_DIR/quota-blocked.txt"
touch "$QUOTA_BLOCKED_FILE" 2>/dev/null || true
quota_blocked() { grep -Fxq "$1" "$QUOTA_BLOCKED_FILE" 2>/dev/null; }
quota_block_add() { quota_blocked "$1" || printf '%s\n' "$1" >> "$QUOTA_BLOCKED_FILE"; }

# R2551: 出口 IP 会轮换的 relay 对“preflight 200”没有意义（下一次 CONNECT
# 可能换到另一个已 quota 的 IP）。同一轮里记住它们，后续 rotate 不再重试。
UNSTABLE_BLOCKED_FILE="$EGRESS_STATE_DIR/unstable-blocked.txt"
touch "$UNSTABLE_BLOCKED_FILE" 2>/dev/null || true
unstable_blocked() { grep -Fxq "$1" "$UNSTABLE_BLOCKED_FILE" 2>/dev/null; }
unstable_block_add() { unstable_blocked "$1" || printf '%s\n' "$1" >> "$UNSTABLE_BLOCKED_FILE"; }

# Mark the current egress as unusable for a while. For a relay/http candidate
# the key is the entry address; the preflight that just failed was the same one.
CUR_EGRESS=$(jq -r '.egress_ip // empty' "$EGRESS_STATE_FILE" 2>/dev/null || true)
if [ "$REASON" = "quota" ]; then
  quota_block_add "$CUR_KEY"
  echo "rotate: quota is anonymous/IP-scoped; skipping $CUR_KEY for the rest of this run (run-scoped, not persistent)"
elif [ "$REASON" = "manual" ]; then
  echo "rotate: manual switch; current $CUR_KEY stays eligible (no blacklist)"
else
  egress_bl_add "$CUR_KEY" "$CUR_EGRESS" "$REASON" "$TTL" || true
  if [ "$EGRESS_BLACKLIST_ENABLED" = "1" ]; then
    echo "rotate: blacklisted $CUR_KEY ($REASON, ${TTL}s)"
  else
    echo "rotate: blacklist disabled; did not persist $CUR_KEY"
  fi
fi

tries=0
quota_fails=0
other_fails=0
skipped_quota=0
while IFS=$'\t' read -r kind target source; do
  [ -n "${kind:-}" ] || continue
  case "$kind" in
    direct) key="direct:$DIRECT_IP"; up="direct"; target="-" ;;
    relay)  key="relay:$target";     up="relay:$target" ;;
    http)   key="http:$target";      up="http:$target" ;;
    *) continue ;;
  esac

  [ "$up" = "$CUR_UP" ] && continue
  # R2546: never re-probe an IP that already answered quota earlier in this run.
  if [ "$REASON" = "quota" ] && quota_blocked "$key"; then
    echo "rotate: skip quota-limited $key (already tried this run)"
    skipped_quota=$((skipped_quota + 1))
    continue
  fi
  # R2551: 已在同一轮被判定出口轮换的 relay，不再浪费 preflight 预算。
  if unstable_blocked "$key"; then
    echo "rotate: skip unstable-egress $key (already rejected this run)"
    continue
  fi
  if egress_bl_has "$key"; then
    echo "rotate: skip blacklisted $key"
    continue
  fi
  tries=$((tries + 1))
  # Same tuning as select-proxy: 8s is enough for a real inference answer. Quota
  # rotations only sample EGRESS_QUOTA_PROBE_MAX relays (default 4); transport
  # rotations keep the full 48-candidate budget.
  [ "$tries" -gt "$MAX_TRIES" ] && { echo "rotate: candidate budget exhausted ($MAX_TRIES)"; break; }

  preflight_target="$([ "$kind" = direct ] && echo '' || echo "$target")"
  stable_egress=""
  if [ "$PROBE_ENGINE" = "path" ]; then
    _meta="$EGRESS_STATE_DIR/rotate-preflight.$$"
    rm -f "$_meta"
    _expected=""
    [ "$DIRECT_IP" != "unknown" ] && _expected="$DIRECT_IP"
    out=$(EGRESS_PREFLIGHT_META="$_meta" EGRESS_EXPECTED_IP="$_expected" \
      bash "$SCRIPT_DIR/egress-preflight-path.sh" "$kind" "$preflight_target" "$PREFLIGHT_TMO" 2>/dev/null || true)
    stable_egress=$(sed -n 's/^egress=//p' "$_meta" 2>/dev/null | tail -1)
    rm -f "$_meta"
  elif [ "$PROBE_ENGINE" = "zengate" ]; then
    out=$(bash "$SCRIPT_DIR/egress-preflight-zengate.sh" "$kind" "$preflight_target" "$PREFLIGHT_TMO" 2>/dev/null || true)
  else
    out=$(bash "$SCRIPT_DIR/egress-preflight.sh" "$kind" "$preflight_target" "$PREFLIGHT_TMO" 2>/dev/null || true)
  fi
  code=${out%%$'\t'*}
  why=${out##*$'\t'}
  [ -n "$code" ] || code=000
  [ -n "$why" ] || why=transport

  if [ "$code" = "200" ] && { [ "$why" = "ok" ] || [ "$why" = "path_ok" ]; }; then
    # R2551: 与 select-proxy 同一判据——relay 出口 IP 若轮换，preflight 的 200
    # 不能代表真实会话将使用的 IP，必须跳过，避免“200 后仍 429”。
    # R2884: the path preflight already sampled 8 parallel traces and returned
    # the stable IP; only the message-spending engines need the extra check.
    if [ "$PROBE_ENGINE" != "path" ] && { [ "$kind" = "relay" ] || [ "$kind" = "http" ]; }; then
      if ! egress_trace_stable "$kind" "$target" 8 > "$EGRESS_STATE_DIR/stable-rotate.$$"; then
        echo "rotate: candidate $kind $target passed preflight but egress rotates (saw ${EGRESS_TRACE_SEEN:-?}); skipping: preflight cannot validate the IP the real session will use"
        other_fails=$((other_fails + 1))
        unstable_block_add "$key"
        egress_bl_add "$key" "" "unstable-egress" "$TTL" || true
        continue
      fi
      stable_egress=$(cat "$EGRESS_STATE_DIR/stable-rotate.$$")
      rm -f "$EGRESS_STATE_DIR/stable-rotate.$$"
    fi
    if ! egress_write_upstream "$up"; then
      echo "rotate: failed to write $EGRESS_UPSTREAM_FILE; keeping $CUR_UP"
      exit 1
    fi
    case "$kind" in
      # The path preflight observed the live runner IP; prefer it over a stale
      # or unknown direct_ip from the previous state file.
      direct)
        [ -n "$stable_egress" ] && DIRECT_IP="$stable_egress"
        egress="$DIRECT_IP"
        ;;
      relay|http) egress="$stable_egress" ;;
    esac
    [ -n "$egress" ] || egress="unknown"
    if ! egress_write_state "$kind" "$up" "$egress" "$source" "$DIRECT_IP" "$PROBE_ENGINE"; then
      # The proxy is already on the new upstream; restore the old one so a
      # half-written switch cannot leave the run with a state/upstream mismatch.
      echo "rotate: failed to write $EGRESS_STATE_FILE; restoring $CUR_UP and refusing switch"
      egress_write_upstream "$CUR_UP" || true
      exit 1
    fi
    egress_bl_del "$key"
    echo "rotate: switched to $kind $target egress=$egress (source=$source preflight=$PROBE_ENGINE$( [ -n "$stable_egress" ] && echo ', egress sticky over 8 parallel traces' ))"
    exit 0
  fi

  if [ "$kind" = "direct" ]; then
    failed_egress="$DIRECT_IP"
  elif [ "$why" = "quota" ] || [ "$why" = "body_error" ]; then
    failed_egress=$(egress_candidate_ip "$kind" "$target" 2>/dev/null || true)
  else
    failed_egress=""
  fi
  if [ "$why" = "quota" ]; then
    quota_fails=$((quota_fails + 1))
    quota_block_add "$key"
  else
    other_fails=$((other_fails + 1))
  fi
  egress_bl_add "$key" "$failed_egress" "$why" "$TTL" || true
  if [ "$EGRESS_BLACKLIST_ENABLED" = "1" ]; then
    echo "rotate: candidate $kind $target failed code=$code reason=$why egress=${failed_egress:-?} (blacklist ${TTL}s)"
  else
    echo "rotate: candidate $kind $target failed code=$code reason=$why egress=${failed_egress:-?} (blacklist disabled)"
  fi
done < "$EGRESS_CANDIDATES_FILE"

# No alternative passed. The egress we were already using is still the best
# choice we have, so keep it. A quota switch must NOT undo the persistent
# blacklist that egress-watch.sh / the gateway preflight already wrote: the
# supervisor is about to fall back to the relay path, and the next run must not
# immediately re-select the exhausted exit. A manual switch changes nothing
# about the current exit's blacklist state. Only transport/http rotation (the
# old diagnostic path) unblacklists the current entry to avoid no route.
if [ "$REASON" = "quota" ]; then
  echo "rotate: no candidate passed the preflight; keeping current egress $CUR_KEY (quota-blocked for the next run; quota_fails=$quota_fails other_fails=$other_fails skipped_quota=$skipped_quota)"
elif [ "$REASON" = "manual" ]; then
  echo "rotate: no candidate passed the preflight; keeping current egress $CUR_KEY (manual switch; blacklist unchanged; other_fails=$other_fails skipped_quota=$skipped_quota)"
else
  egress_bl_del "$CUR_KEY"
  echo "rotate: no candidate passed the preflight; keeping current egress and unblacklisting $CUR_KEY (quota_fails=$quota_fails other_fails=$other_fails skipped_quota=$skipped_quota)"
fi
echo "rotate: quota-blocked this run: $(paste -sd, "$QUOTA_BLOCKED_FILE" 2>/dev/null || echo none)"
echo "rotate: unstable-egress this run: $(paste -sd, "$UNSTABLE_BLOCKED_FILE" 2>/dev/null || echo none)"
if [ "$quota_fails" -gt 0 ] && [ "$other_fails" -eq 0 ]; then
  exit 2
fi
# R2546: every remaining candidate was already quota-limited earlier this run.
# The watcher must still count this as an all-quota rotation (not a transport
# rotation failure) so the 3-strike stop/relay semantics stay correct.
if [ "$quota_fails" -eq 0 ] && [ "$other_fails" -eq 0 ] && [ "$skipped_quota" -gt 0 ]; then
  echo "rotate: all remaining candidates were already quota-limited this run"
  exit 2
fi
exit 1
