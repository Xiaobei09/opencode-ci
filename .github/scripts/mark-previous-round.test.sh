#!/usr/bin/env bash
# R2861: offline matrix for mark-previous-round.sh.
#
# The successor edits the finishing run's round-end card from
# "🔄 CI 本轮结束 · 接力中" to:
#   🌐 relay · run <prev> → <current>
#   🔄 CI 上一轮结束 · <reason>
#   <rest>
# A fake gh + fake tg-notify keep this fast and network-free.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/mark-previous-round.sh"
TD="$(mktemp -d)"
export TD
trap 'rm -rf "$TD"' EXIT
fail=0
total=0
ck() {
  total=$((total + 1))
  if [ "$2" = yes ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

mkdir -p "$TD/bin" "$TD/ws"
cat > "$TD/bin/gh" <<'EOS'
#!/usr/bin/env bash
set -u
cmd="$1 $2"
shift 2 || true
case "$cmd" in
  "variable get")
    cat "$TD/card.json" 2>/dev/null || exit 1
    ;;
  "variable set")
    name="$1"; shift
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) body="$2"; shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s' "$body" > "$TD/$name.out"
    ;;
  "variable delete")
    rm -f "$TD/card.json"
    : > "$TD/deleted"
    ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$TD/bin/gh"

cat > "$TD/tg-notify.sh" <<'EOS'
#!/usr/bin/env bash
cat > "$TD/notify.txt"
printf '%s\n' "$*" > "$TD/notify.args"
env | grep -E '^TG_NOTIFY_(MODE|EDIT_BOT|EDIT_MSG)=' > "$TD/notify.env"
rc="${FAKE_EDIT_RC:-0}"
if [ "$rc" != 0 ]; then
  echo "fake edit failed rc=$rc" >&2
  exit "$rc"
fi
echo "telegram round-end edited (msg=4242, via=bot6)"
EOS
chmod +x "$TD/tg-notify.sh"

make_card() {
  local body="$1" b64
  b64=$(printf '%s' "$body" | base64 | tr -d '\n')
  jq -cn --arg bot bot6 --arg msg 4242 --arg run 111 --arg text "$b64" \
    '{bot:$bot,msg:$msg,run:$run,text:$text}' > "$TD/card.json"
}
orig_body=$'🔄 CI 本轮结束 · 接力中\n原因：opencode 正常结束\nrun 111\n🌐 direct · 出口 1.2.3.4'
make_card "$orig_body"

run_mark() {
  PATH="$TD/bin:$PATH" \
  GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=222 \
  GITHUB_WORKSPACE="$TD/ws" TG_NOTIFY_BIN="$TD/tg-notify.sh" \
    bash "$SCRIPT" > "$TD/out" 2>&1
}

run_mark
rc=$?
ck "R2861: 正常编辑退出 0" "$([ "$rc" = 0 ] && echo yes)"
ck "R2861: 首行是 relay 上一轮 → 本轮" \
  "$([ "$(head -1 "$TD/notify.txt")" = '🌐 relay · run 111 → 222' ] && echo yes)"
ck "R2861: 标题改为上一轮结束并带原因" \
  "$(grep -qx '🔄 CI 上一轮结束 · opencode 正常结束' "$TD/notify.txt" && echo yes)"
ck "R2861: 不再重复原因行" "$(! grep -q '^原因：' "$TD/notify.txt" && echo yes)"
ck "R2861: 保留原卡剩余内容" \
  "$(grep -qx 'run 111' "$TD/notify.txt" && grep -qx '🌐 direct · 出口 1.2.3.4' "$TD/notify.txt" && echo yes)"
ck "R2861: 编辑走原 Bot/原消息" \
  "$(grep -qx 'TG_NOTIFY_MODE=edit' "$TD/notify.env" \
     && grep -qx 'TG_NOTIFY_EDIT_BOT=bot6' "$TD/notify.env" \
     && grep -qx 'TG_NOTIFY_EDIT_MSG=4242' "$TD/notify.env" && echo yes)"
ck "R2861: 写回标记文本与 relayed_by" \
  "$(jq -e '.relayed_by == "222"' "$TD/CI_LAST_ROUND_CARD.out" >/dev/null \
     && [ "$(jq -r '.text' "$TD/CI_LAST_ROUND_CARD.out" | base64 -d | head -1)" = '🌐 relay · run 111 → 222' ] \
     && echo yes)"

# Idempotent: the successor fails before sending its own card, so the next
# relay sees the already-marked card and must not prepend a second relay line.
cp "$TD/CI_LAST_ROUND_CARD.out" "$TD/card.json"
rm -f "$TD/notify.txt"
run_mark
rc=$?
ck "R2861: 已标记的卡不再重复编辑" "$([ "$rc" = 0 ] && [ ! -f "$TD/notify.txt" ] && echo yes)"
ck "R2861: 跳过时日志说明 already marked" "$(grep -q 'already marked' "$TD/out" && echo yes)"

# Deleted message / Bot switched off -> exit 2, clear the variable, keep run green.
make_card "$orig_body"
rm -f "$TD/deleted" "$TD/notify.txt"
FAKE_EDIT_RC=2 run_mark
rc=$?
ck "R2861: 原卡不可编辑仍退出 0（不影响本轮）" "$([ "$rc" = 0 ] && echo yes)"
ck "R2861: 原卡不可编辑时清除变量，避免每轮重试" "$([ -f "$TD/deleted" ] && echo yes)"

# No previous card (first manual run) -> silent no-op.
rm -f "$TD/card.json" "$TD/notify.txt" "$TD/out"
run_mark
rc=$?
ck "R2861: 没有上一轮卡时静默跳过" \
  "$([ "$rc" = 0 ] && [ ! -f "$TD/notify.txt" ] && grep -q 'nothing to mark' "$TD/out" && echo yes)"

echo "mark-previous-round: $((total - fail))/$total PASS"
[ "$fail" = 0 ]
