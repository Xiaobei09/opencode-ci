#!/usr/bin/env bash
# R2628: round-end quota diagnostic — re-probe the CURRENT egress.
#
# R2625 probed an ALTERNATE egress after a verified quota 429 (direct -> relay,
# relay -> direct). Live runs showed the alternate is always fresh: relay2
# returned 200 on all four rounds, so "scope=path-specific" was the trivially
# expected answer and carried no signal. The operator (2026-11-13): "改为探测
# 当前出口，因为探测新出口没有意义".
#
# This script now re-probes the SAME path the round used:
#   - round used direct -> probe direct (the same runner IP)
#   - round used relay  -> probe that same relay entry
#   - round used http   -> probe that same http entry
#
# zengate is still required: the zero-message gateway preflight sends a
# malformed body and always gets 400 before the gateway evaluates quota, so it
# cannot answer a quota question.
#
# The question is no longer "does a new path have quota?", but "what does the
# path that just 429'd report right now?":
#   result=current-exhausted : same path still returns FreeUsageLimit 429
#   result=current-ok        : same path returned 200 (quota looks available;
#                              this spends one free message)
#   result=inconclusive      : transport/HTTP error, no quota claim
#
# Diagnostic only: it never changes selection, the stop reason, or the relay
# policy. A quota 429 spends no message; a 200 spends one.
#
# Usage: egress-quota-probe.sh
# Env:
#   EGRESS_STATE_DIR                  round egress state (upstream)
#   EGRESS_QUOTA_PROBE=0              disable (default: enabled)
#   EGRESS_QUOTA_PROBE_TIMEOUT=15     probe timeout (seconds)
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
  meta "result=inconclusive"
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
meta "probe_target=current"

if [ "$CUR_KIND" != "direct" ] && [ -z "$CUR_TARGET" ]; then
  meta "result=inconclusive"
  meta "note=current egress has no target"
  log "current egress has no target; skipped (up=$UP)"
  exit 0
fi

PROBE_STARTED=0
cleanup() {
  if [ "$PROBE_STARTED" = "1" ]; then
    bash "$SCRIPT_DIR/egress-probe-server.sh" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! EGRESS_PROBE_REQUEST_TIMEOUT_MS=$((TMO * 1000)) \
     timeout "$START_TMO" bash "$SCRIPT_DIR/egress-probe-server.sh" start \
       >> "$STATE_DIR/quota-probe-server.log" 2>&1; then
  bash "$SCRIPT_DIR/egress-probe-server.sh" stop >/dev/null 2>&1 || true
  meta "result=inconclusive"
  meta "note=probe server unavailable"
  log "probe server unavailable; skipped"
  exit 0
fi
PROBE_STARTED=1

pm="$STATE_DIR/quota-probe-current.meta"
rm -f "$pm"
out=$(EGRESS_PREFLIGHT_META="$pm" timeout "$TMO" \
  bash "$SCRIPT_DIR/egress-preflight-zengate.sh" "$CUR_KIND" "$CUR_TARGET" "$TMO" 2>/dev/null || true)
code=${out%%$'\t'*}
reason=${out##*$'\t'}
[ -n "$code" ] || code=000
[ -n "$reason" ] || reason=transport
ra=$(sed -n 's/^retry_after=//p' "$pm" 2>/dev/null | head -1)
up="$CUR_KIND${CUR_TARGET:+:$CUR_TARGET}"
meta "current_up=$up"
meta "code=$code"
meta "reason=$reason"
meta "retry_after=${ra:-}"
log "current up=$up code=$code reason=$reason retry_after=${ra:-?}"

case "$reason" in
  ok)    result=current-ok ;;
  quota) result=current-exhausted ;;
  *)     result=inconclusive ;;
esac
meta "result=$result"
log "result=$result (current=$up code=$code reason=$reason)"
exit 0
