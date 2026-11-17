#!/usr/bin/env bash
# R2755 (operator: "增加一个恢复模式：要求使用干净环境，自动新增一个会话并且临时将
# 一个bot的会话切换到这个会话，并且注入提示词，要求其修复ci，同时其他会话都不
# 运行，完成之后也不保存会话").
#
# This script runs after the environment restore and before OpenCode starts. It turns
# the restored runtime into a clean, single-session repair environment:
#   * pick one Bot (first online registry entry; override with CI_RECOVERY_BOT),
#   * remember its old front so the bridge can inherit the model,
#   * halt every known session (fronts, pinned, watch, loop-sessions),
#   * clear fronts/pins/queues so no old session can start,
#   * delete the session DB/snapshots (clean room; the save gate is disabled in
#     recovery mode, so this NEVER reaches the release),
#   * write ~/.config/opencode/ci-recovery.json for the bridge; the matching Bot
#     creates the new session, switches to it, and injects the repair prompt;
#   * write ci-recovery-active.json so sibling Bot instances cannot adopt the
#     single fresh session through their boot-time resume fallback.
#
# It is intentionally idempotent: a crashed boot can re-run it and still produce one
# request. No network calls here.
set -euo pipefail

CFG="$HOME/.config/opencode"
STATE_HOME="$HOME/.local/share/opencode"
TARGETS="${TARGETS_DIR:-/home/runner/work/targets}"
RUN="${CI_RECOVERY_RUN:-}"
REASON="${CI_RECOVERY_REASON:-CI failure (no reason supplied)}"
REPO="${GITHUB_REPOSITORY:-unknown/repo}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
SESSIONS="${SESSIONS_DIR:-/home/runner/work/sessions}"

mkdir -p "$CFG"
rm -f "$CFG/ci-recovery.json" "$CFG"/ci-recovery.json.claimed-* 2>/dev/null || true

# Resolve the registry in the same order as tg-bridge / auto-continue:
# first entry owns tg-chats.json, the rest own tg-chats-<id>.json.
REG="$CFG/tg-bots.json"
BOT="${CI_RECOVERY_BOT:-}"
if [ -z "$BOT" ] && [ -s "$REG" ] && command -v jq >/dev/null 2>&1; then
  BOT=$(jq -r '.bots[0].id // empty' "$REG" 2>/dev/null || true)
fi
[ -n "$BOT" ] || BOT=primary
if ! printf '%s' "$BOT" | grep -Eq '^[A-Za-z0-9_-]+$'; then
  echo "::error::prepare-recovery: unsafe bot id '$BOT'"
  exit 1
fi
BOT_STATE="$CFG/tg-chats-$BOT.json"
if [ -s "$REG" ] && command -v jq >/dev/null 2>&1; then
  FIRST=$(jq -r '.bots[0].id // empty' "$REG" 2>/dev/null || true)
  [ "$FIRST" = "$BOT" ] && BOT_STATE="$CFG/tg-chats.json"
elif [ "$BOT" = "primary" ]; then
  BOT_STATE="$CFG/tg-chats.json"
fi

OLD_SID=""
if [ -s "$BOT_STATE" ] && command -v jq >/dev/null 2>&1; then
  OLD_SID=$(jq -r '.front // .pinned // empty' "$BOT_STATE" 2>/dev/null || true)
fi
case "$OLD_SID" in ses_*) ;; *) OLD_SID="" ;; esac

# Remember the old session's model before the clean-room DB deletion. The bridge
# normally inherits the model from the old session (R2658), but that session no
# longer exists once this script deletes opencode.db. Keep the exact
# provider/model/variant so the repair turn runs on the Bot's current model
# instead of the host default. Missing DB/table/row is fine: model stays null.
MODEL_JSON=""
if [ -n "$OLD_SID" ] && [ -s "$STATE_HOME/opencode.db" ] && command -v python3 >/dev/null 2>&1; then
  MODEL_JSON=$(python3 - "$STATE_HOME/opencode.db" "$OLD_SID" <<'PYMODEL' 2>/dev/null || true
import json, sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1])
    row = con.execute("select model from session_v2 where id = ?", (sys.argv[2],)).fetchone()
    model = json.loads(row[0]) if row and row[0] else None
    if isinstance(model, dict) and isinstance(model.get("id"), str) and isinstance(model.get("providerID"), str):
        print(json.dumps(model, ensure_ascii=False))
except Exception:
    pass
PYMODEL
)
fi
case "$MODEL_JSON" in \{*) ;; *) MODEL_JSON="" ;; esac

# Every session this run knows about must be halted. auto-continue reads the union
# of all Bot state files, so putting the union into each file is safe and survives
# a Bot that boots late.
HALT=$(mktemp)
: > "$HALT"
for st in "$CFG"/tg-chats.json "$CFG"/tg-chats-*.json; do
  [ -f "$st" ] || continue
  jq -r '(.halted // [])[]?, .front?, .pinned?, (.watch // [])[]?' "$st" 2>/dev/null >> "$HALT" || true
done
if [ -s "$CFG/loop-sessions.json" ]; then
  jq -r '.[]?' "$CFG/loop-sessions.json" 2>/dev/null >> "$HALT" || true
fi
sort -u "$HALT" | grep -E '^ses_[A-Za-z0-9_-]+$' > "${HALT}.clean" || true
HALTED_JSON=$(jq -R -s 'split("\n") | map(select(length > 0))' < "${HALT}.clean")
rm -f "$HALT" "${HALT}.clean"

# Clear every mutable session binding/queue while preserving credentials, chat
# registries, filters and other configuration. tmp+rename keeps the file valid if
# OpenCode starts while we write.
for st in "$CFG"/tg-chats.json "$CFG"/tg-chats-*.json; do
  [ -f "$st" ] || continue
  tmp="$st.tmp-recovery-$$"
  if jq --argjson halt "$HALTED_JSON" '
      .halted = (($halt + (.halted // [])) | map(select(. != null)) | unique)
      | .front = ""
      | .pinned = ""
      | .queue = []
      | .pinqueue = []
      | .qmap = []
      | .qpin = {}
      | .qpinon = {}
      | .bar = {}
      | .watch = []
      | .lastmsgs = []
      | .pushask = []
      | .qpinhist = []
    ' "$st" > "$tmp" 2>/dev/null && mv -f "$tmp" "$st"; then
    :
  else
    rm -f "$tmp" 2>/dev/null || true
    echo "::warning::prepare-recovery: could not clean $st"
  fi
done

# A clean recovery must not inherit a stopped loop or a pending quota rollover.
rm -f "$CFG/loop-ctl.json" \
      "$CFG/loop-sessions.json" "$CFG/loop-sessions-off.json" \
      "$CFG/loop-marker.json" "$CFG/loop-guard.json" \
      "$CFG/halt-release.json" \
      "$CFG/quota-429-evidence.json" "$CFG/quota-429-streaks.json" \
      "$CFG"/inject-card-*.json 2>/dev/null || true
rm -rf "$CFG/rollover-requests" 2>/dev/null || true

# Clean-room session data: the save steps are disabled in recovery mode, so this
# only affects this run. Old histories cannot be resumed or auto-continued.
rm -f "$STATE_HOME/opencode.db" "$STATE_HOME/opencode.db-shm" "$STATE_HOME/opencode.db-wal" 2>/dev/null || true
rm -rf "$STATE_HOME/snapshot" "$STATE_HOME/shell" "$STATE_HOME/tool-output" 2>/dev/null || true
rm -rf "${TARGETS:?}"/* 2>/dev/null || true

if [ -n "$RUN" ]; then
  RUN_URL="https://github.com/$REPO/actions/runs/$RUN"
  RUN_LINE="CI 运行：$RUN_URL"
  LOG_HINT="1. 先看真实日志：gh run view $RUN --log-failed（或 gh run view $RUN --log）。"
else
  RUN_URL=""
  RUN_LINE="CI 运行：手动启动（未提供失败 run id）"
  LOG_HINT="1. 先看失败轮日志：gh run list --limit 10，再对相关 run 用 gh run view <id> --log-failed。"
fi
PROMPT=$(cat <<PROMPT_EOF
你正在执行 CI 干净恢复模式（一次性；本轮结束不保存会话/环境快照）。

$RUN_LINE
失败原因：$REASON

目标：定位并修复导致这次 CI 失败的问题，使下一轮 iterate 能正常运行。

工作区：
- CI 仓库（当前目录）：$WORKSPACE
- 会话仓库：$SESSIONS/opencode
- 目标工作区已刻意不还原（干净环境）；不要依赖旧 workspace 或旧会话历史。

要求：
$LOG_HINT
2. 只做最小修复；优先根因，不要用 exit 0、吞错或跳过检查来掩盖失败。
3. 改完运行相关测试；至少跑你改动范围内的测试/静态检查。
4. 把修复提交并 push 到对应仓库的 main（CI 修复通常在当前仓库）。
5. 不要恢复其他会话、不要开启自动循环、不要写 secrets/token，不要保存会话或环境快照。
6. 完成后用一两句话报告改了什么、测试结果；无法修复就说明原因后停止，不要反复重试。
PROMPT_EOF
)

TMP="$CFG/ci-recovery.json.tmp-$$"
jq -n \
  --arg bot "$BOT" \
  --arg oldSid "$OLD_SID" \
  --arg prompt "$PROMPT" \
  --arg run "$RUN" \
  --arg reason "$REASON" \
  --arg runUrl "$RUN_URL" \
  --argjson model "${MODEL_JSON:-null}" \
  --argjson ts "$(date +%s%3N)" \
  '{bot:$bot,oldSid:$oldSid,prompt:$prompt,run:$run,reason:$reason,runUrl:$runUrl,model:$model,ts:$ts,clean:true,haltOthers:true,ephemeral:true}' \
  > "$TMP"
mv -f "$TMP" "$CFG/ci-recovery.json"
chmod 600 "$CFG/ci-recovery.json" 2>/dev/null || true

# Run-scoped marker for the OTHER Bot instances: only the designated Bot may bind
# the fresh session (their resume-fallback would otherwise adopt the only session
# in the clean DB). It is deliberately not consumed by the bridge and disappears
# with the runner because recovery runs never snapshot the environment.
TMPA="$CFG/ci-recovery-active.json.tmp-$$"
jq -n \
  --arg bot "$BOT" \
  --arg run "$RUN" \
  --argjson ts "$(date +%s%3N)" \
  '{bot:$bot,run:$run,ts:$ts}' > "$TMPA"
mv -f "$TMPA" "$CFG/ci-recovery-active.json"
chmod 600 "$CFG/ci-recovery-active.json" 2>/dev/null || true

echo "clean recovery prepared: bot=$BOT oldSid=${OLD_SID:0:12} halted=$(printf '%s' "$HALTED_JSON" | jq 'length') run=$RUN"
echo "recovery request: $CFG/ci-recovery.json"
