#!/usr/bin/env bash
# Zero-message path preflight.
#
# The free tier meters provider *messages*, not prompt tokens. A zengate probe
# is a real inference request, so a probe 200 only proves "at least one free
# message remained before the probe"; the probe itself spends that message and
# the next real turn can still hit FreeUsageLimitError. This script deliberately
# sends NO inference request. It only proves:
#   - the candidate tunnel reaches the provider edge (Cloudflare trace), and
#   - a relay keeps a stable exit IP (so the real turn uses the IP we checked).
# The first real turn is the quota test; the watcher counts a quota 429 from it
# exactly like any other real turn.
#
# Usage: egress-preflight-path.sh <direct|relay|http> <target> [timeout]
# Stdout: "<http-code>\t<reason>" (reason is path_ok, transport, unstable, or
# egress_changed). Optional meta lines are written to EGRESS_PREFLIGHT_META:
#   mode=path
#   messages=0
#   egress=<observed exit ip>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

KIND="${1:?usage: egress-preflight-path.sh <direct|relay|http> <target> [timeout]}"
TARGET="${2:-}"
TMO="${3:-8}"
META="${EGRESS_PREFLIGHT_META:-}"

meta() {
  [ -n "$META" ] || return 0
  printf '%s\n' "$1" >> "$META" 2>/dev/null || true
}

case "$KIND" in
  direct)
    ip=$(egress_trace_direct "$TMO")
    if [ -z "$ip" ]; then
      meta "mode=path"; meta "messages=0"
      printf '000\ttransport\n'
      exit 1
    fi
    # A direct trace that resolves to a different IP than the one the selector
    # recorded means the runner's NAT changed between selection and the probe.
    # Refuse it instead of writing a stale egress_ip into the run state.
    if [ -n "${EGRESS_EXPECTED_IP:-}" ] && [ "$ip" != "$EGRESS_EXPECTED_IP" ]; then
      meta "mode=path"; meta "messages=0"; meta "egress=$ip"
      printf '000\tegress_changed\n'
      exit 1
    fi
    meta "mode=path"; meta "messages=0"; meta "egress=$ip"
    printf '200\tpath_ok\n'
    ;;
  relay|http)
    # egress_trace_stable samples 8 parallel CONNECTs; a rotating relay must be
    # rejected because the real turn could land on a different (exhausted) IP.
    if ! stable=$(EGRESS_TRACE_TIMEOUT="$TMO" egress_trace_stable "$KIND" "$TARGET" 8); then
      meta "mode=path"; meta "messages=0"
      case "${EGRESS_TRACE_SEEN:-}" in
        ""|unreachable|*unreachable*) printf '000\ttransport\n' ;;
        *) printf '000\tunstable\n' ;;
      esac
      exit 1
    fi
    if [ -z "$stable" ]; then
      meta "mode=path"; meta "messages=0"
      printf '000\ttransport\n'
      exit 1
    fi
    meta "mode=path"; meta "messages=0"; meta "egress=$stable"
    printf '200\tpath_ok\n'
    ;;
  *)
    meta "mode=path"; meta "messages=0"
    printf '000\tbad_kind\n'
    exit 1
    ;;
esac
