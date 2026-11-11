#!/usr/bin/env bash
# Validate one egress candidate with zengate (real OpenCode, fresh session).
# The probe server must already be running; see egress-probe-server.sh.
#
# Usage: egress-preflight-zengate.sh <direct|relay|http> <target> [timeout]
# Stdout: "<http-code>\t<reason>"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"
PROBE_DIR="${EGRESS_PROBE_DIR:-$EGRESS_STATE_DIR/probe}"
ZG_PORT="${EGRESS_ZENGATE_PORT:-18083}"
KIND="${1:?usage: egress-preflight-zengate.sh <direct|relay|http> <target> [timeout]}"
TARGET="${2:-}"
TMO="${3:-20}"
# R2511: probe the model the agent really uses, not a fixed big-pickle. The
# free quota is per model; a mismatched probe can return 200 while the real
# session immediately fails with provider.free-limit.
MODEL="${EGRESS_PROBE_MODEL:-$(egress_probe_model)}"
echo "zengate preflight model=$MODEL" >&2
META="${EGRESS_PREFLIGHT_META:-}"
# R2565: a cache/proxy that replays a canned "OK" must not pass as a real
# provider completion. Ask for a fresh nonce and verify it appears in the
# content; this also proves the request traversed the candidate tunnel.
NONCE="$(date +%s%N)-${RANDOM}"
WANT="OK-${NONCE}"

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

HDR=$(mktemp)
trap 'rm -f "$HDR"' EXIT
body=$(jq -nc --arg m "$MODEL" --arg want "$WANT" \
  '{model:$m,stream:false,max_tokens:32,messages:[{role:"user",content:("Reply with exactly: " + $want)}]}')
raw=$(curl -sS -m "$TMO" --noproxy '*' -D "$HDR" -w '\n%{http_code}' \
  -H 'Content-Type: application/json' -d "$body" \
  "http://127.0.0.1:${ZG_PORT}/v1/chat/completions" 2>/dev/null || true)
code=${raw##*$'\n'}
js=${raw%$'\n'*}
[ -n "$code" ] || code=000
content=$(printf '%s' "$js" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
err=$(printf '%s' "$js" | jq -r '.error.message // empty' 2>/dev/null || true)
all="$js $err"

# R2565: preserve the provider's Retry-After so the selector can blacklist an
# exhausted egress for the real reset window instead of a fixed 6h.
ra=""
if [ -s "$HDR" ]; then
  raw_ra=$(awk 'tolower($1)=="retry-after:" {gsub("\r",""); print $2}' "$HDR" | tail -1)
  if [ -n "$raw_ra" ]; then
    case "$raw_ra" in
      *[!0-9]*)
        _e=$(date -u -d "$raw_ra" +%s 2>/dev/null || true)
        if [ -n "$_e" ]; then
          ra=$((_e - $(egress_now)))
          [ "$ra" -lt 0 ] && ra=0
        fi
        ;;
      *) ra="$raw_ra" ;;
    esac
  fi
fi
if [ -n "$META" ]; then
  {
    printf 'retry_after=%s\n' "${ra:-}"
    printf 'nonce=%s\n' "$NONCE"
    printf 'code=%s\n' "$code"
    # R2582: the probe is NOT free. zengate injects the OpenCode system prompt,
    # so even max_tokens=32 consumed ~4k prompt tokens in a live measurement.
    # Record it so selection logs show how much of the daily bucket the probe
    # itself spent ("200" only proves this much headroom existed).
    printf 'tokens=%s\n' "$(printf '%s' "$js" | jq -r '.usage.total_tokens // empty' 2>/dev/null)"
  } > "$META" 2>/dev/null || true
fi

reason=ok
if [ "$code" = "200" ] && printf '%s' "$content" | grep -qF "$NONCE"; then
  reason=ok
elif [ "$code" = "429" ] || printf '%s' "$all" | grep -qiE 'FreeUsageLimit|free usage limit|free-limit|provider\.free-limit|quota|rate.?limit'; then
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
