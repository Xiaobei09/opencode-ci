#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
set +e
# R2626 (operator: "改，给我一个菜单的选择按钮/界面"): capture the
# PREVIOUS run's selected egress before selection overwrites it. A
# pre-boot quota/429 tail is only recoverable in Option C when this
# run picked a genuinely different exit; same exit keeps
# skip=quota-error so we do not immediately burn another 429.
PREV_EXIT="$RUNNER_TEMP/exit-proxy.prev.json"
rm -f "$PREV_EXIT"
if [ -s "$HOME/.config/opencode/exit-proxy.json" ]; then
  cp "$HOME/.config/opencode/exit-proxy.json" "$PREV_EXIT" 2>/dev/null || true
fi
bash "$GITHUB_WORKSPACE/.github/scripts/select-proxy.sh" 2>&1 | tee "$RUNNER_TEMP/select-proxy.log"
rc=${PIPESTATUS[0]}
echo "select-proxy rc=$rc"
if [ "$rc" -ne 0 ]; then
  # Do not leave a stale selection behind: the next run must select
  # afresh, and the failure notification must not claim an egress.
  rm -f "$HOME/.config/opencode/exit-proxy.json" "$RUNNER_TEMP/exit-proxy.env" \
        "$RUNNER_TEMP/egress/upstream" "$RUNNER_TEMP/egress/candidates.tsv"
  # R2588/R2617：失败原因必须区分。direct quota 耗尽时探测拿到的是
  # 429；是否试过 relay 由 select-proxy 的 ERROR 行说明（当前默认
  # 不限量，所以通常是“no relay passed the path probe”）。
  sel_err=$(grep -aE '^\[egress-select\] ERROR: ' "$RUNNER_TEMP/select-proxy.log" 2>/dev/null | tail -1 | sed -E 's/^\[egress-select\] ERROR: //' | cut -c1-240)
  if printf '%s' "$sel_err" | grep -q 'direct free-quota exhausted'; then
    reason="${sel_err:-direct free-quota exhausted}"
    echo "::error::egress selection failed: $reason; ending this run so the next run can select a fresh egress"
  elif printf '%s' "$sel_err" | grep -q 'path probe'; then
    reason="${sel_err:-no candidate passed the path probe}"
    echo "::error::egress selection failed: $reason; ending this run so the next run can select a fresh egress"
  else
    reason="no egress candidate answered 200 (select-proxy rc=$rc)"
    echo "::error::egress selection failed: neither direct nor any relay answered 200; ending this run (no unverified egress)"
  fi
  echo "reason=$reason" >> "$GITHUB_OUTPUT"
  exit 1
fi
if [ ! -s "$HOME/.config/opencode/exit-proxy.json" ]; then
  echo "reason=egress selection reported success but exit-proxy state is missing" >> "$GITHUB_OUTPUT"
  echo "::error::egress selection reported success but exit-proxy state is missing; ending this run"
  exit 1
fi
# R2575 (D8): the state file alone is not enough. Run OpenCode consumes
# this env handoff to start the local proxy; without it the round used
# to fall back to a direct connection while selection looked green.
if [ ! -s "$RUNNER_TEMP/exit-proxy.env" ] \
   || ! grep -q '^HTTPS_PROXY=http://127\.0\.0\.1:' "$RUNNER_TEMP/exit-proxy.env"; then
  rm -f "$HOME/.config/opencode/exit-proxy.json" "$RUNNER_TEMP/exit-proxy.env" \
        "$RUNNER_TEMP/egress/upstream" "$RUNNER_TEMP/egress/candidates.tsv"
  echo "reason=egress selection reported success but the proxy handoff env is missing/incomplete" >> "$GITHUB_OUTPUT"
  echo "::error::egress selection reported success but $RUNNER_TEMP/exit-proxy.env is missing/incomplete; ending this run (no direct fallback)"
  exit 1
fi
# R2626: compare the previous run's egress with this run's selection.
# "Different" means a different upstream (direct|relay:ip:port|
# http:host:port) OR a different observed egress IP. A missing
# previous file is NOT evidence of a change (fresh snapshot/manual
# first run) → keep the conservative skip=quota-error.
PREV_UP=""; PREV_EG=""
if [ -s "$PREV_EXIT" ]; then
  PREV_UP=$(jq -r '.upstream // empty' "$PREV_EXIT" 2>/dev/null || true)
  PREV_EG=$(jq -r '.egress_ip // empty' "$PREV_EXIT" 2>/dev/null || true)
fi
NEW_UP=$(jq -r '.upstream // empty' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null || true)
NEW_EG=$(jq -r '.egress_ip // empty' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null || true)
EGRESS_CHANGED=0
if [ -n "$PREV_UP" ]; then
  if [ "$PREV_UP" != "$NEW_UP" ]; then
    EGRESS_CHANGED=1
  elif [ -n "$PREV_EG" ] && [ -n "$NEW_EG" ] && [ "$PREV_EG" != "$NEW_EG" ]; then
    EGRESS_CHANGED=1
  fi
fi
# R2626 menu preference (TG 循环/代理页 →「额度尾恢复」):
# auto = only after an egress change; off = always skip quota tails.
QR_MODE="auto"
QR_FILE="$HOME/.config/opencode/quota-recover.json"
if [ -f "$QR_FILE" ]; then
  QR_MODE=$(jq -r '.mode // "auto"' "$QR_FILE" 2>/dev/null || echo auto)
fi
[ "$QR_MODE" = "off" ] || QR_MODE="auto"
QR_ENABLED=0
if [ "$EGRESS_CHANGED" = "1" ] && [ "$QR_MODE" = "auto" ]; then
  case "${CI_QUOTA_TAIL_RECOVER:-1}" in
    0|false|no|off|OFF|False|No) QR_ENABLED=0 ;;
    *) QR_ENABLED=1 ;;
  esac
fi
# Consumed by the Run OpenCode step (and then by the Option C plugin).
echo "RESUME_ONCE_QUOTA_RECOVER=$QR_ENABLED" >> "$GITHUB_ENV"
echo "R2626 quota-tail recover: prev=${PREV_UP:-none}/${PREV_EG:-?} new=${NEW_UP:-?}/${NEW_EG:-?} changed=$EGRESS_CHANGED mode=$QR_MODE enabled=$QR_ENABLED"
if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_PUSH_CHAT:-}" ]; then
  # R2520：与 TG 错误卡 exitProxySummary() 使用完全相同的键名/顺序：
  # kind → upstream → local → egress → direct。旧格式 `CI egress: direct direct`
  # 与错误卡的 `exit proxy: http://127.0.0.1:8089 ...` 对不上。
  KIND=$(jq -r '.kind // "direct"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null)
  UP=$(jq -r '.upstream // "direct"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null)
  SCHEME=$(jq -r '.scheme // "http"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null)
  PROXY=$(jq -r '.proxy // "127.0.0.1:8089"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null)
  EIP=$(jq -r '.egress_ip // "?"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null)
  MSG="exit proxy: kind=${KIND} upstream=${UP} local=${SCHEME}://${PROXY} egress=${EIP} direct=$(jq -r '.direct_ip // "?"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null)"
  # R2626: visible proof that this run may recover a pre-boot quota
  # tail once (only when the egress actually changed).
  [ "$QR_ENABLED" = "1" ] && MSG="$MSG quota-tail-recover=on"
  curl -sS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_PUSH_CHAT}" --data-urlencode "text=${MSG}" \
    >/dev/null 2>&1 || echo "::warning::could not send the exit-proxy notice to telegram"
fi
if [ -n "${PRE_OPENCODE_T0:-}" ]; then
  echo "setup timing: pre-opencode $(( $(date +%s) - PRE_OPENCODE_T0 ))s (target <60s: checkout+restore+install+select)"
fi
exit 0
