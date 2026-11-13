#!/usr/bin/env bash
# R2622: zero-message gateway preflight through the already-selected egress.
#
# The free tier meters provider messages, not prompt tokens. A deliberately
# malformed JSON body is rejected by the inference gateway with HTTP 400 before
# any model call, so this probe spends NO free message. It proves the exact
# completion endpoint is reachable through the selected path (the local proxy
# has already been pointed at the chosen upstream).
#
# R2625 live finding (operator: "确认 429 比 400 优先吗?"): NO. The gateway
# validates the body BEFORE quota. At 05:54:44 this probe returned 400 while
# the real turn hit FreeUsageLimitError at 05:55:08 (24s later). The 429 branch
# below is only a safety net for a future gateway change; it cannot be used as
# an early quota signal. The first real turn is authoritative, and the R2625
# round-end zengate probe answers whether the quota is path-specific.
#
# Usage: egress-preflight-gateway.sh [timeout-seconds]
# Env:
#   HTTPS_PROXY / https_proxy  local egress proxy (required unless DIRECT=1)
#   EGRESS_GATEWAY_DIRECT=1    bypass proxy (tests/local diagnostics)
#   EGRESS_GATEWAY_URL=...     override endpoint (tests)
#   EGRESS_GATEWAY_META=...    write probe metadata here
# Stdout: "<http-code>\t<reason>"
#   ok | quota | rate_limit | transport | http_<code>
set -uo pipefail

TMO="${1:-8}"
URL="${EGRESS_GATEWAY_URL:-https://opencode.ai/inference/v1/chat/completions}"
META="${EGRESS_GATEWAY_META:-}"
PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
DIRECT="${EGRESS_GATEWAY_DIRECT:-0}"

HDR=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$HDR" "$BODY"' EXIT

echo "gateway preflight url=$URL messages=0 (malformed JSON is rejected before inference)" >&2

ARGS=(-sS -m "$TMO" -D "$HDR" -o "$BODY" -w '%{http_code}')
if [ "$DIRECT" = "1" ] || [ -z "$PROXY" ]; then
  # Explicit direct mode (tests) or no proxy handoff: never silently use a
  # stale proxy from the runner environment.
  ARGS+=(--noproxy '*')
else
  # Force the selected local proxy even if NO_PROXY happens to list the host.
  ARGS+=(-x "$PROXY" --noproxy '')
fi

# The body is intentionally invalid JSON. The gateway rejects it with 400
# before invoking a model, so it cannot spend a free message. The headers mimic
# the real anonymous free-tier request so a relay cannot treat this as an
# arbitrary API probe.
code=$(curl "${ARGS[@]}" \
  -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -H 'User-Agent: opencode/1.18.32' \
  -H 'Authorization: Bearer public' \
  --data-binary '{' 2>/dev/null)
[ -n "$code" ] || code=000

# Preserve the provider's Retry-After. Numeric seconds are used as-is; an
# HTTP-date is converted to seconds from now.
ra=""
if [ -s "$HDR" ]; then
  # Keep the whole value: an HTTP-date contains spaces ("Wed, 21 Oct ... GMT"),
  # so splitting on whitespace would truncate it.
  raw_ra=$(awk 'tolower($1)=="retry-after:" {sub(/^[^:]*:[ \t]*/, ""); gsub("\r", ""); print}' "$HDR" | tail -1)
  case "$raw_ra" in
    '') ;;
    *[!0-9]*)
      _e=$(date -u -d "$raw_ra" +%s 2>/dev/null || true)
      if [ -n "$_e" ]; then
        ra=$((_e - $(date +%s)))
        [ "$ra" -lt 0 ] && ra=0
      fi
      ;;
    *) ra="$raw_ra" ;;
  esac
fi

log_id=0
grep -qi '^x-opencode-log-id:' "$HDR" 2>/dev/null && log_id=1
free_body=0
grep -qiE 'FreeUsageLimit|free usage limit|provider\.free-limit' "$BODY" 2>/dev/null && free_body=1

# 400/422 is the expected gateway response to malformed JSON. A 200 with the
# gateway log header is also accepted (some gateways surface the parse error as
# a 200), but a bare 200 is treated as unverified (captive portal/cache).
# A 429 is only a quota signal when the body proves FreeUsageLimitError; a bare
# 429 is a transient/relay rate limit and must not stop a healthy round.
reason=ok
case "$code" in
  400|422) reason=ok ;;
  200)
    if [ "$log_id" = "1" ]; then reason=ok; else reason=http_200; fi
    ;;
  429)
    if [ "$free_body" = "1" ]; then reason=quota; else reason=rate_limit; fi
    ;;
  000) reason=transport ;;
  5*) reason=transport ;;
  *) reason="http_$code" ;;
esac

if [ -n "$META" ]; then
  {
    printf 'mode=gateway\n'
    printf 'messages=0\n'
    printf 'code=%s\n' "$code"
    printf 'reason=%s\n' "$reason"
    printf 'gateway_log_id=%s\n' "$log_id"
    printf 'free_body=%s\n' "$free_body"
    printf 'retry_after=%s\n' "${ra:-}"
    printf 'body_bytes=%s\n' "$(wc -c < "$BODY" 2>/dev/null || echo 0)"
  } > "$META" 2>/dev/null || true
fi

printf '%s\t%s\n' "$code" "$reason"
[ "$reason" = "ok" ] && exit 0
exit 1
