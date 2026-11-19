#!/usr/bin/env bash
# R2728/R2729/R2732/R2733/R2837: regression for the per-Bot card-ops switch in
# tg-notify.sh; the egress line now rides the round-end card instead of its own.
# Operator: "不是全局，是bot单独设置，设置本bot推不推" and
#           "我说的是ci结束/开始/tg限流这些全局信息的开关".
# Runs with a fake curl/PATH and a temp HOME; never contacts Telegram.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/tg-notify.sh"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/bin" "$TD/home/.config/opencode" "$TD/home/.opencode"
LOG="$TD/curl.log"
: > "$LOG"

cat > "$TD/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url=""
for a in "$@"; do
  case "$a" in https://api.telegram.org/*) url="$a" ;; esac
done
tok=${url#https://api.telegram.org/bot}
tok=${tok%%/*}
printf '%s\n' "$tok" >> "$FAKE_LOG"
case " ${FAKE_FAIL_TOKENS:-} " in
  *" $tok "*) printf '%s\n%s\n' '{"ok":false,"description":"fake failure"}' 500 ;;
  *) printf '%s\n%s\n' '{"ok":true}' 200 ;;
esac
FAKE
chmod +x "$TD/bin/curl"

export PATH="$TD/bin:$PATH"
export HOME="$TD/home"
unset OPENCODE_CONFIG_DIR
export TG_NOTIFY_NO_SLEEP=1 TG_NOTIFY_MAX_ATTEMPTS=1 TG_NOTIFY_PREFERRED_ATTEMPTS=1
export TG_NOTIFY_PEER_LEDGER="$TD/peer.json"
export TG_BOT_TOKEN="111:primary-token" TG_PUSH_CHAT="8104398008"
export FAKE_LOG="$LOG"
export FAKE_FAIL_TOKENS=""

cat > "$HOME/.opencode/tg.env" <<'EOF'
TG_BOT_TOKEN=111:primary-token
TG_PUSH_CHAT=8104398008
EOF
cat > "$HOME/.config/opencode/tg-bot6.env" <<'EOF'
TG_BOT_TOKEN=666:bot6-token
TG_PUSH_CHAT=8104398008
EOF
cat > "$HOME/.config/opencode/tg-bot5.env" <<'EOF'
TG_BOT_TOKEN=555:bot5-token
TG_PUSH_CHAT=8104398008
EOF
cat > "$HOME/.config/opencode/tg-bots.json" <<EOF
{"bots":[
  {"id":"primary","label":"CI","envFile":"$HOME/.opencode/tg.env"},
  {"id":"bot5","label":"@opencodev2_bot","envFile":"$HOME/.config/opencode/tg-bot5.env"},
  {"id":"bot6","label":"@codecilbot","envFile":"$HOME/.config/opencode/tg-bot6.env"}
]}
EOF
OPS="$HOME/.config/opencode/card-ops.json"
setops() { printf '%s\n' "$1" > "$OPS"; }
setledger() {
  printf '%s\n' "$1" > "$TG_NOTIFY_PEER_LEDGER"
}
# Default: bot6 was used last; all bots default ON.
setledger '{"bot6":{"in":200,"seen":300},"bot5":{"in":100,"seen":100},"primary":{"in":50,"seen":50}}'
setops '{"bots":{"bot6":{"enabled":true}},"notifyBot":"bot6"}'

checks=0
fail=0
ck() {
  local name="$1" cond="$2"
  checks=$((checks + 1))
  if [ "$cond" = "yes" ]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    fail=1
  fi
}

run() {
  : > "$LOG"
  out=$(printf 'quota 429 test\n' | TG_NOTIFY_CLASS="${1:-}" bash "$SCRIPT" round-end 2>&1)
  rc=$?
}

# Per-Bot ON: bot6 was used last -> bot6 token.
run quota
ck "R2729: 429 通知跟最近使用的 Bot（bot6）" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"
ck "R2729: bot6 成功后不再打扰主 Bot" "$(grep -qx '666:bot6-token' "$LOG" && ! grep -qx '111:primary-token' "$LOG" && echo yes)"

# Only bot6 OFF: latest bot5 is still allowed, so bot5 must be used.
setops '{"bots":{"bot6":{"enabled":false},"bot5":{"enabled":true}},"notifyBot":"bot6"}'
setledger '{"bot5":{"in":300,"seen":300},"bot6":{"in":200,"seen":200}}'
run quota
ck "R2729: 关掉 bot6 不影响 bot5 自己推" "$(printf '%s' "$out" | grep -q 'via=bot5' && echo yes)"
ck "R2729: bot5 已推时不再发 bot6/主 Bot" "$(grep -qx '555:bot5-token' "$LOG" && ! grep -q '666:bot6-token' "$LOG" && ! grep -q '111:primary-token' "$LOG" && echo yes)"

# Latest bot5 OFF, bot6 ON -> fall back to bot6, not primary.
setops '{"bots":{"bot5":{"enabled":false},"bot6":{"enabled":true}},"notifyBot":"bot6"}'
setledger '{"bot5":{"in":300,"seen":300},"bot6":{"in":200,"seen":200}}'
run quota
ck "R2729: 最近使用的 bot5 关了就换 bot6（不越级到主 Bot）" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"
ck "R2729: 被关闭的 bot5 不产生请求" "$(! grep -qx '555:bot5-token' "$LOG" && echo yes)"

# All off -> explicit opt-out: skip with success, no Telegram request at all.
setops '{"bots":{"bot5":{"enabled":false},"bot6":{"enabled":false},"primary":{"enabled":false}},"notifyBot":"bot6"}'
run quota
ck "R2729: 所有 Bot 都关时不推 429（尊重本 Bot 设置）" "$(printf '%s' "$out" | grep -q 'all notice routes disabled' && echo yes)"
ck "R2729: 全部关闭时不发任何请求" "$([ ! -s "$LOG" ] && echo yes)"
ck "R2729: 全部关闭是主动跳过，不算失败" "$([ "$rc" = 0 ] && echo yes)"

# R2732: ordinary round-end/relay notices now follow the same per-Bot switch.
setops '{"bots":{"bot6":{"enabled":true},"bot5":{"enabled":false},"primary":{"enabled":false}},"notifyBot":"bot6"}'
setledger '{"bot6":{"in":200,"seen":300},"bot5":{"in":100,"seen":100}}'
run ""
ck "R2732: 普通结束/接力通知也跟随本 Bot 开关（bot6 开）" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"
ck "R2732: 普通通知不会再无视开关硬发主 Bot" "$(! grep -qx '111:primary-token' "$LOG" && echo yes)"

# Ordinary notice with the last-used Bot OFF -> next enabled Bot.
setops '{"bots":{"bot6":{"enabled":false},"bot5":{"enabled":true},"primary":{"enabled":false}},"notifyBot":"bot6"}'
run ""
ck "R2732: 普通通知遇到本 Bot 关闭就换下一个已开启 Bot" "$(printf '%s' "$out" | grep -q 'via=bot5' && echo yes)"
ck "R2732: 关闭的 bot6 不产生普通通知请求" "$(! grep -qx '666:bot6-token' "$LOG" && echo yes)"

# Ordinary notice all off -> intentional skip, exit 0, no request.
setops '{"bots":{"bot5":{"enabled":false},"bot6":{"enabled":false},"primary":{"enabled":false}},"notifyBot":"bot6"}'
run ""
ck "R2732: 普通通知全部关闭时也不推" "$(printf '%s' "$out" | grep -q 'all notice routes disabled' && echo yes)"
ck "R2732: 普通通知全部关闭时不发请求且不算失败" "$([ ! -s "$LOG" ] && [ "$rc" = 0 ] && echo yes)"

# R2837 (operator: "精简 ci 本轮结束，🌐 … 改为 ci 本轮结束（尾部添加）"): the
# run-start egress card is gone. select-egress persists CI_EGRESS_TAIL and the
# round-end / loop-stop card appends it as its last line, so a round sends one
# global notice instead of two and the line still follows the per-Bot switch.
sel="$HERE/select-egress-step.sh"
wf="$HERE/../workflows/iterate.yml"
ck "R2837: 选代理结果不再单独发卡" \
  "$(! grep -q 'tg-notify.sh" egress' "$sel" && ! grep -q 'sendMessage' "$sel" && echo yes)"
ck "R2837: 选代理结果写入 CI_EGRESS_TAIL" \
  "$(grep -q 'CI_EGRESS_TAIL' "$sel" && echo yes)"
ck "R2837: 结束卡/停止卡尾部追加选代理结果" \
  "$([ "$(grep -c 'CI_EGRESS_TAIL' "$wf")" -ge 2 ] && echo yes)"

# Registry tail: bot6/primary OFF but bot5 ON must still be reachable even
# though bot5 is neither last-used nor notifyBot.
setops '{"bots":{"bot6":{"enabled":false},"primary":{"enabled":false},"bot5":{"enabled":true}},"notifyBot":"bot6"}'
setledger '{"bot6":{"in":300,"seen":300}}'
run quota
ck "R2732: 最近/默认/主 Bot 都关闭时仍能找到注册表里开启的 bot5" "$(printf '%s' "$out" | grep -q 'via=bot5' && echo yes)"
ck "R2732: 注册表兜底不会请求已关闭的 Bot" "$(! grep -q '666:bot6-token' "$LOG" && ! grep -q '111:primary-token' "$LOG" && echo yes)"

# Primary OFF, latest primary, bot6 ON -> bot6 pushes.
setops '{"bots":{"primary":{"enabled":false},"bot6":{"enabled":true}},"notifyBot":"bot6"}'
setledger '{"primary":{"in":400,"seen":400},"bot6":{"in":200,"seen":200}}'
run quota
ck "R2729: 主 Bot 自己关了就由 bot6 推" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"

# Preferred bot missing token -> next enabled route (primary).
setops '{"bots":{"bot6":{"enabled":true}}}'
setledger '{"bot6":{"in":200,"seen":300},"bot5":{"in":100,"seen":100}}'
mv "$HOME/.config/opencode/tg-bot6.env" "$TD/bot6.bak"
run quota
ck "R2729: 目标 Bot 缺 token 时回退下一个已开启的路由" "$(printf '%s' "$out" | grep -q 'via=primary' && echo yes)"
mv "$TD/bot6.bak" "$HOME/.config/opencode/tg-bot6.env"

# Preferred send fails -> primary fallback (primary default ON).
setops '{"bots":{"bot6":{"enabled":true}}}'
export FAKE_FAIL_TOKENS="666:bot6-token"
run quota
ck "R2729: 目标 Bot 发送失败时回退主 Bot" "$(printf '%s' "$out" | grep -q 'via=primary' && echo yes)"
ck "R2729: 回退失败路径有明确 warning" "$(printf '%s' "$out" | grep -q 'falling back' && echo yes)"
export FAKE_FAIL_TOKENS=""

# Corrupt switch file behaves like ON (same default as the bridge).
printf '{bad' > "$OPS"
run quota
ck "R2729: 开关文件损坏时按默认开处理" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"

# Legacy R2728 global file: false is the fallback for bots without an entry.
setops '{"enabled":false,"notifyBot":"bot6"}'
run quota
ck "R2729: 旧全局关文件不再误推主 Bot" "$(printf '%s' "$out" | grep -q 'all notice routes disabled' && echo yes)"
setops '{"enabled":false,"bots":{"bot5":{"enabled":true}},"notifyBot":"bot6"}'
setledger '{"bot5":{"in":300,"seen":300}}'
run quota
ck "R2729: 旧全局关 + 单 Bot 显式开启时按该 Bot 推" "$(printf '%s' "$out" | grep -q 'via=bot5' && echo yes)"

# R2731: ids from the ledger/switch file reach a file path and jq args; reject
# anything outside the registry alphabet instead of trusting the JSON.
setops '{"bots":{"bot6":{"enabled":true}},"notifyBot":"bot6"}'
setledger '{"../../evil":{"in":999,"seen":999},"bot6":{"in":100,"seen":100}}'
run quota
ck "R2731: 账本里的非法 bot id 不作为路由" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"
ck "R2731: 非法 id 不产生请求" "$(! grep -q 'evil' "$LOG" && echo yes)"

setops '{"bots":{"bot6":{"enabled":true}},"notifyBot":"../evil"}'
setledger '{}'
run quota
ck "R2731: 非法 notifyBot 回退默认 bot6" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"
ck "R2731: 非法 notifyBot 不越级到主 Bot" "$(! grep -q '111:primary-token' "$LOG" && echo yes)"

# R2732: jq-less fallback. The old "tg-bot${bot}.env" guess turned the current
# id style into "tg-botbot6.env"; a runner without jq could not load any
# non-primary Bot and every notice silently fell back to primary.
NOJQ="$TD/nojq"
mkdir -p "$NOJQ"
for c in cat sed head tail tr cut grep mktemp rm sleep bash; do
  ln -s "$(command -v "$c")" "$NOJQ/$c"
done
cp "$TD/bin/curl" "$NOJQ/curl"
setops '{"bots":{"bot6":{"enabled":true}},"notifyBot":"bot6"}'
setledger '{"bot6":{"in":200,"seen":300}}'
: > "$LOG"
out=$(printf 'normal\n' | PATH="$NOJQ" TG_NOTIFY_NO_SLEEP=1 TG_NOTIFY_MAX_ATTEMPTS=1 \
  TG_NOTIFY_PREFERRED_ATTEMPTS=1 bash "$SCRIPT" round-end 2>&1)
rc=$?
ck "R2732: 无 jq 时仍能按 bot6 的 envFile 兜底加载 token" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"
ck "R2732: 无 jq 时不会把 bot6 拼成 tg-botbot6.env" "$(printf '%s' "$out" | grep -q 'missing token/chat' && echo no || echo yes)"
ck "R2732: 无 jq 时确实调用了 bot6 token" "$(grep -qx '666:bot6-token' "$LOG" && echo yes)"

# Legacy global off is parsed coarsely without jq and must still skip.
setops '{"enabled":false}'
: > "$LOG"
out=$(printf 'normal\n' | PATH="$NOJQ" TG_NOTIFY_NO_SLEEP=1 TG_NOTIFY_MAX_ATTEMPTS=1 \
  TG_NOTIFY_PREFERRED_ATTEMPTS=1 bash "$SCRIPT" round-end 2>&1)
rc=$?
ck "R2732: 无 jq 时旧全局关仍能主动跳过" "$(printf '%s' "$out" | grep -q 'all notice routes disabled' && [ "$rc" = 0 ] && echo yes)"
ck "R2732: 无 jq 旧全局关不发请求" "$([ ! -s "$LOG" ] && echo yes)"

echo "tg-notify: $([ "$fail" = 0 ] && echo PASS || echo FAIL) ($checks checks)"
exit "$fail"
