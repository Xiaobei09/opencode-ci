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
BODY_FILE=$(mktemp)
trap 'rm -f "$HDR" "$BODY_FILE"' EXIT
REQ_TMO="$TMO"
if [ "${EGRESS_PROBE_BIG:-0}" = "1" ]; then
  # R2598 (D8): a 4k probe cannot prove that a shared relay has enough of its
  # per-IP bucket left for one resumed turn (~100k prompt tokens). Live tests
  # showed relays that answer the 4k probe with 200 but 429 the next real turn,
  # while other relays served two consecutive ~86k-token requests. Send the
  # same context size as a real turn so "200" means "can serve a turn".
  #
  # This costs one real provider request (~86k tokens in live measurement), so
  # it is opt-in (EGRESS_BIG_PROBE=1) and runs only after direct failed. By
  # default the selector relies on the small path probe; the first real turn
  # is the quota test.
  FILLER="$PROBE_DIR/filler.txt"
  WANT_BYTES="${EGRESS_BIG_PROBE_BYTES:-400000}"
  if [ ! -s "$FILLER" ] || [ "$(wc -c < "$FILLER" 2>/dev/null || echo 0)" -lt "$WANT_BYTES" ]; then
    python3 - "$FILLER" "$WANT_BYTES" <<'PY' 2>/dev/null || true
import sys
path, want = sys.argv[1], int(sys.argv[2])
unit = "The quick brown fox jumps over the lazy dog while the CI runner waits for the provider. "
with open(path, "w", encoding="utf-8") as f:
    while f.tell() < want:
        f.write(unit)
PY
  fi
  if [ ! -s "$FILLER" ]; then
    printf '000\tprobe_setup\n'
    exit 1
  fi
  jq -nc --rawfile ctx "$FILLER" --arg m "$MODEL" --arg want "$WANT" \
    '{model:$m,stream:false,max_tokens:32,messages:[{role:"user",content:("Long context (the repetition is intentional; it makes this request the same size as a real resumed turn):\n" + $ctx + "\nEnd of context. Reply with exactly: " + $want)}]}' > "$BODY_FILE"
  REQ_TMO="${EGRESS_BIG_PROBE_REQUEST_TIMEOUT:-50}"
  echo "zengate big preflight body=$(wc -c < "$BODY_FILE" 2>/dev/null || echo ?) bytes model=$MODEL" >&2
else
  jq -nc --arg m "$MODEL" --arg want "$WANT" \
    '{model:$m,stream:false,max_tokens:32,messages:[{role:"user",content:("Reply with exactly: " + $want)}]}' > "$BODY_FILE"
fi
raw=$(curl -sS -m "$REQ_TMO" --noproxy '*' -D "$HDR" -w '\n%{http_code}' \
  -H 'Content-Type: application/json' --data-binary @"$BODY_FILE" \
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
    printf 'big=%s\n' "${EGRESS_PROBE_BIG:-0}"
    printf 'body_bytes=%s\n' "$(wc -c < "$BODY_FILE" 2>/dev/null || echo 0)"
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
