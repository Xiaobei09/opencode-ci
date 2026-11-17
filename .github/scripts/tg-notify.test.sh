#!/usr/bin/env bash
# R2728: regression for the unified card-ops switch in tg-notify.sh.
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
cat > "$HOME/.config/opencode/card-ops.json" <<'EOF'
{"enabled":true,"notifyBot":"bot6"}
EOF
cat > "$TG_NOTIFY_PEER_LEDGER" <<'EOF'
{"bot6":{"in":200,"seen":300},"bot5":{"in":100,"seen":100},"primary":{"in":50,"seen":50}}
EOF

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

# ON + quota: peer ledger says bot6 was used last -> bot6 token.
run quota
ck "R2728: 429 通知跟最近使用的 Bot（bot6）" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"
ck "R2728: bot6 成功后不再打扰主 Bot" "$(grep -qx '666:bot6-token' "$LOG" && ! grep -qx '111:primary-token' "$LOG" && echo yes)"

# OFF: same quota notice falls back to the primary Bot.
cat > "$HOME/.config/opencode/card-ops.json" <<'EOF'
{"enabled":false,"notifyBot":"bot6"}
EOF
run quota
ck "R2728: 开关关闭时 429 仍走主 Bot（旧行为）" "$(printf '%s' "$out" | grep -q 'via=primary' && echo yes)"
ck "R2728: 关闭时没有请求非主 Bot" "$(grep -qx '111:primary-token' "$LOG" && ! grep -q 'bot6-token' "$LOG" && echo yes)"

# Non-quota notices never reroute, even when the switch is ON.
cat > "$HOME/.config/opencode/card-ops.json" <<'EOF'
{"enabled":true,"notifyBot":"bot6"}
EOF
run ""
ck "R2728: 普通结束通知仍走主 Bot（不误改 429 以外的消息）" "$(printf '%s' "$out" | grep -q 'via=primary' && echo yes)"

# Preferred bot missing token -> primary fallback.
mv "$HOME/.config/opencode/tg-bot6.env" "$TD/bot6.bak"
run quota
ck "R2728: 目标 Bot 缺 token 时回退主 Bot" "$(printf '%s' "$out" | grep -q 'via=primary' && echo yes)"
mv "$TD/bot6.bak" "$HOME/.config/opencode/tg-bot6.env"

# Preferred send fails -> primary fallback (not repeated forever).
export FAKE_FAIL_TOKENS="666:bot6-token"
run quota
ck "R2728: 目标 Bot 发送失败时回退主 Bot" "$(printf '%s' "$out" | grep -q 'via=primary' && echo yes)"
ck "R2728: 回退失败路径有明确 warning" "$(printf '%s' "$out" | grep -q 'falling back' && echo yes)"
export FAKE_FAIL_TOKENS=""

# Corrupt switch file behaves like ON (same default as the bridge).
printf '{bad' > "$HOME/.config/opencode/card-ops.json"
run quota
ck "R2728: 开关文件损坏时按默认开处理" "$(printf '%s' "$out" | grep -q 'via=bot6' && echo yes)"

echo "tg-notify: $([ "$fail" = 0 ] && echo PASS || echo FAIL) ($checks checks)"
exit "$fail"
