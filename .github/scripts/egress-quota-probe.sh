#!/usr/bin/env bash
# R2625: round-end quota-scope diagnostic.
#
# The zero-message gateway preflight sends malformed JSON and always receives
# 400: the gateway validates the request body before it evaluates quota. Live
# R2622-R2624 evidence: the probe returned 400 at 05:54:44 while the real turn
# hit FreeUsageLimitError at 05:55:08 (24s later). So that probe proves
# reachability, not quota, and its 429 branch is only a safety net.
#
# The operator asked (2026-11-13): "3 rounds still had very little quota and
# were all direct; use zengate again when CI ends on 429? is 429 really
# prioritized over 400?" This script answers the useful half of that question
# with a REAL zengate request on an ALTERNATE egress after the round has
# already ended on a verified quota 429:
#   - round used direct -> probe up to N relay candidates
#   - round used relay  -> probe direct
#
# Outcome:
#   scope=path-specific : alternate path returned 200 (it has quota to spend)
#   scope=shared        : alternate path also returned FreeUsageLimit 429
#   scope=inconclusive  : transport/HTTP error on every alternate
#
# Diagnostic only: it never changes selection, the stop reason, or the relay
# policy. A 200 spends one free message on the alternate path; a 429 spends
# none. The round's own egress is already blacklisted for its Retry-After, so
# this cannot steal quota from the next real turn on a fresh candidate.
#
# Usage: egress-quota-probe.sh
# Env:
#   EGRESS_STATE_DIR                  round egress state (upstream, relays.txt)
#   EGRESS_QUOTA_PROBE=0              disable (default: enabled)
#   EGRESS_QUOTA_PROBE_TIMEOUT=15     per-probe timeout (seconds)
#   EGRESS_QUOTA_PROBE_MAX_ALTERNATES=2
#   EGRESS_QUOTA_PROBE_RELAY=ip:port  force one alternate relay
#   EGRESS_QUOTA_PROBE_META=...       metadata output path
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

STATE_DIR="${EGRESS_STATE_DIR:-${RUNNER_TEMP:-/tmp}/egress}"
UP_FILE="$STATE_DIR/upstream"
META="${EGRESS_QUOTA_PROBE_META:-$STATE_DIR/quota-probe.meta}"
TMO="${EGRESS_QUOTA_PROBE_TIMEOUT:-15}"
case "$TMO" in ''|*[!0-9]*) TMO=15 ;; esac
# zengate rejects REQUEST_TIMEOUT_MS below 10000; clamp the per-probe timeout
# so a small diagnostic value cannot prevent the probe server from starting.
[ "$TMO" -lt 10 ] && TMO=10
MAX_ALT="${EGRESS_QUOTA_PROBE_MAX_ALTERNATES:-2}"
START_TMO="${EGRESS_QUOTA_PROBE_START_TIMEOUT:-30}"

log() { echo "quota-end zengate probe: $*"; }
meta() { printf '%s\n' "$1" >> "$META" 2>/dev/null || true; }

: > "$META" 2>/dev/null || true

if [ "${EGRESS_QUOTA_PROBE:-1}" = "0" ]; then
  log "disabled by EGRESS_QUOTA_PROBE=0"
  exit 0
fi
if ! command -v zengate >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  log "zengate/python3 unavailable; skipped"
  meta "scope=inconclusive"
  meta "note=zengate or python3 unavailable"
  exit 0
fi

UP=$(cat "$UP_FILE" 2>/dev/null || echo direct)
case "$UP" in
  relay:*) CUR_KIND=relay;  CUR_TARGET="${UP#relay:}" ;;
  http:*)  CUR_KIND=http;   CUR_TARGET="${UP#http:}" ;;
  *)       CUR_KIND=direct; CUR_TARGET="" ;;
esac
meta "round_up=$UP"

ALT_FILE=$(mktemp)
PROBE_STARTED=0
cleanup() {
  rm -f "$ALT_FILE"
  if [ "$PROBE_STARTED" = "1" ]; then
    bash "$SCRIPT_DIR/egress-probe-server.sh" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

n=0
if [ "$CUR_KIND" = "direct" ]; then
  if [ -n "${EGRESS_QUOTA_PROBE_RELAY:-}" ]; then
    printf 'relay1\trelay\t%s\n' "$EGRESS_QUOTA_PROBE_RELAY" >> "$ALT_FILE"
  elif [ -s "$STATE_DIR/relays.txt" ]; then
    egress_bl_init
    while IFS= read -r hp; do
      [ -n "$hp" ] || continue
      case "$hp" in
        *[!0-9.:]*) continue ;;
      esac
      # exactly one colon (ipv4:port); reject malformed entries
      case "$hp" in
        *:*:*) continue ;;
        *:*) ;;
        *) continue ;;
      esac
      if [ "$EGRESS_BLACKLIST_ENABLED" = "1" ] && egress_bl_has "relay:$hp"; then
        continue
      fi
      n=$((n + 1))
      printf 'relay%d\trelay\t%s\n' "$n" "$hp" >> "$ALT_FILE"
      [ "$n" -ge "$MAX_ALT" ] && break
    done < <(head -n 60 "$STATE_DIR/relays.txt" | tr -d '\r' | sed 's/#.*//')
  fi
else
  printf 'direct\tdirect\t\n' >> "$ALT_FILE"
fi

if [ ! -s "$ALT_FILE" ]; then
  meta "scope=inconclusive"
  meta "note=no alternate candidate"
  log "no alternate candidate; skipped"
  exit 0
fi

if ! EGRESS_PROBE_REQUEST_TIMEOUT_MS=$((TMO * 1000)) \
     timeout "$START_TMO" bash "$SCRIPT_DIR/egress-probe-server.sh" start \
       >> "$STATE_DIR/quota-probe-server.log" 2>&1; then
  bash "$SCRIPT_DIR/egress-probe-server.sh" stop >/dev/null 2>&1 || true
  meta "scope=inconclusive"
  meta "note=probe server unavailable"
  log "probe server unavailable; skipped"
  exit 0
fi
PROBE_STARTED=1

alt_code=""
alt_reason=""
alt_up=""
while IFS=$'\t' read -r label kind target; do
  [ -n "$label" ] || continue
  pm="$STATE_DIR/quota-probe-${label}.meta"
  rm -f "$pm"
  out=$(EGRESS_PREFLIGHT_META="$pm" timeout "$TMO" \
    bash "$SCRIPT_DIR/egress-preflight-zengate.sh" "$kind" "${target:-}" "$TMO" 2>/dev/null || true)
  code=${out%%$'\t'*}
  reason=${out##*$'\t'}
  [ -n "$code" ] || code=000
  [ -n "$reason" ] || reason=transport
  ra=$(sed -n 's/^retry_after=//p' "$pm" 2>/dev/null | head -1)
  up="$kind${target:+:$target}"
  meta "${label}_code=$code"
  meta "${label}_reason=$reason"
  meta "${label}_up=$up"
  meta "${label}_retry_after=${ra:-}"
  log "$label up=$up code=$code reason=$reason retry_after=${ra:-?}"
  alt_code=$code
  alt_reason=$reason
  alt_up=$up
  case "$reason" in
    ok|quota) break ;;
  esac
done < "$ALT_FILE"

alt_code=${alt_code:-000}
alt_reason=${alt_reason:-transport}
alt_up=${alt_up:-?}
meta "alt_code=$alt_code"
meta "alt_reason=$alt_reason"
meta "alt_up=$alt_up"
case "$alt_reason" in
  ok)    scope=path-specific ;;
  quota) scope=shared ;;
  *)     scope=inconclusive ;;
esac
meta "scope=$scope"
log "scope=$scope (round=$UP alternate=$alt_up code=$alt_code reason=$alt_reason)"
exit 0
