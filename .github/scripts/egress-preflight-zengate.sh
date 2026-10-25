#!/usr/bin/env bash
# Validate one egress candidate with zengate (real OpenCode, fresh session).
# The probe server must already be running; see egress-probe-server.sh.
#
# Usage: egress-preflight-zengate.sh <direct|relay|http> <target> [timeout]
# Stdout: "<http-code>\t<reason>"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-${RUNNER_TEMP:-/tmp}/egress}"
PROBE_DIR="${EGRESS_PROBE_DIR:-$EGRESS_STATE_DIR/probe}"
ZG_PORT="${EGRESS_ZENGATE_PORT:-18083}"
KIND="${1:?usage: egress-preflight-zengate.sh <direct|relay|http> <target> [timeout]}"
TARGET="${2:-}"
TMO="${3:-20}"
MODEL="${EGRESS_PROBE_MODEL:-big-pickle}"

case "$KIND" in
  direct) UP="direct" ;;
  relay)  [ -n "$TARGET" ] || { printf '000\ttransport\n'; exit 1; }; UP="relay:$TARGET" ;;
  http)   [ -n "$TARGET" ] || { printf '000\ttransport\n'; exit 1; }; UP="http:$TARGET" ;;
  *) printf '000\tbad_kind\n'; exit 64 ;;
esac

printf '%s\n' "$UP" > "$PROBE_DIR/upstream"
epoch=$(($(cat "$PROBE_DIR/epoch" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$epoch" > "$PROBE_DIR/epoch"
# The probe proxy polls epoch every 0.4s. Wait for the tunnel close before the
# next request so it cannot reuse the previous candidate's provider connection.
sleep 0.8

body=$(jq -nc --arg m "$MODEL" \
  '{model:$m,stream:false,max_tokens:24,messages:[{role:"user",content:"Reply with exactly: OK"}]}')
raw=$(curl -sS -m "$TMO" --noproxy '*' -w '\n%{http_code}' \
  -H 'Content-Type: application/json' -d "$body" \
  "http://127.0.0.1:${ZG_PORT}/v1/chat/completions" 2>/dev/null || true)
code=${raw##*$'\n'}
js=${raw%$'\n'*}
[ -n "$code" ] || code=000
content=$(printf '%s' "$js" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
err=$(printf '%s' "$js" | jq -r '.error.message // empty' 2>/dev/null || true)
all="$js $err"

reason=ok
if [ "$code" = "200" ] && [ -n "$content" ]; then
  reason=ok
elif [ "$code" = "429" ] || printf '%s' "$all" | grep -qiE 'FreeUsageLimit|free usage limit|quota|rate.?limit'; then
  reason=quota
elif [ "$code" = "000" ] || [ "$code" = "502" ] || [ "$code" = "503" ] || [ "$code" = "504" ] \
     || printf '%s' "$all" | grep -qiE 'ECONN|ETIMEDOUT|timed out|socket|connect|network'; then
  reason=transport
elif [ "$code" != "200" ]; then
  reason="http_${code}"
else
  reason=body_error
fi

printf '%s\t%s\n' "$code" "$reason"
[ "$reason" = "ok" ] && exit 0
exit 1
