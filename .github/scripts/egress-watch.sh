#!/usr/bin/env bash
# Watch the OpenCode run log for the free-tier quota error and rotate egress.
# Runs in the same step as OpenCode so it inherits the local proxy environment.
#
# Usage: egress-watch.sh <run-log>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

LOG="${1:?usage: egress-watch.sh <run-log>}"
mkdir -p "$EGRESS_STATE_DIR"
WATCH_LOG="$EGRESS_STATE_DIR/watch.log"
: > "$WATCH_LOG"

last=0
fail_until=0

log() { echo "$(egress_iso) $*" >> "$WATCH_LOG"; }

log "watch start log=$LOG upstream=$(cat "$EGRESS_UPSTREAM_FILE" 2>/dev/null || echo '?')"

while [ ! -f "$LOG" ]; do sleep 1; done

while IFS= read -r line; do
  case "$line" in
    *"Free usage limit reached"*|*"FreeUsageLimitError"*|*"free usage limit reached"*)
      now=$(egress_now)
      if [ "$now" -lt "$fail_until" ]; then
        continue
      fi
      if [ $((now - last)) -lt 20 ]; then
        continue
      fi
      last=$now
      log "quota error detected; rotating egress"
      if bash "$SCRIPT_DIR/egress-rotate.sh" --reason quota >> "$WATCH_LOG" 2>&1; then
        # The rotation can take 10-60s. Reset the debounce *after* it returns so
        # 429 lines already buffered from the old egress cannot immediately
        # blacklist the freshly selected one.
        last=$(egress_now)
        state=$(jq -c '{kind,upstream,egress_ip}' "$EGRESS_STATE_FILE" 2>/dev/null || echo '{}')
        log "rotate ok $state"
      else
        last=$(egress_now)
        log "rotate failed; keeping current egress"
        fail_until=$((last + 60))
      fi
      ;;
  esac
done < <(tail -n +1 -F "$LOG" 2>/dev/null)

log "watch end"
