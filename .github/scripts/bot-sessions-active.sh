#!/usr/bin/env bash
# R2642 (operator): "只有在输出才算活跃，自然结束不算".
#
# The 3-round no-200 quota-429 stop is a last resort. Before pausing, the
# workflow must confirm that NO bot session is producing output right now.
#
# Active  = the session has an unfinished turn:
#             * session_v2.time_busy > time_idle (last transition was to busy)
#             * OR the latest message is an assistant message without
#               time.completed (still streaming / tool running)
#           and that activity happened during this round (>= OPENCODE_START_T0)
#           or, when no round start is supplied, within BOT_ACTIVE_WINDOW_SECONDS.
# Inactive = natural end (latest message is `idle`, or time_idle >= time_busy),
#            errored/interrupted turn, archived session, token-invalid bot, or
#            no resumable session. A stopped bot that is still finishing its
#            turn IS active; a stopped bot with no in-flight turn is not.
#
# Unreadable state (missing registry/DB) is treated as "active" (fail-open):
# never pause on unknown information.
#
# Exit codes:
#   0 = at least one bot is outputting now (or state unreadable) -> DO NOT pause
#   1 = every bot is idle/ended/stopped/errored                  -> pausing allowed
#
# Env overrides (tests must not touch production state):
#   OPENCODE_CONFIG_DIR        default: $HOME/.config/opencode
#   OPENCODE_DB                default: $HOME/.local/share/opencode/opencode.db
#   OPENCODE_START_T0          epoch seconds when the round started (optional)
#   BOT_ACTIVE_WINDOW_SECONDS  recency fallback when no round start (default 900)
set -uo pipefail

CFG="${OPENCODE_CONFIG_DIR:-${HOME:-/root}/.config/opencode}"
DB="${OPENCODE_DB:-${HOME:-/root}/.local/share/opencode/opencode.db}"
REG="$CFG/tg-bots.json"
INVALID="$CFG/tg-token-invalid.json"
WINDOW="${BOT_ACTIVE_WINDOW_SECONDS:-900}"

# Unknown registry = cannot enumerate bots = never pause.
if [ ! -f "$REG" ] || ! command -v jq >/dev/null 2>&1; then
  echo "bot-sessions: registry unreadable ($REG); assuming a bot may be outputting (no pause)"
  exit 0
fi
if ! BOTS_JSON=$(jq -er '.' "$REG" 2>/dev/null); then
  echo "bot-sessions: registry is not valid JSON; assuming a bot may be outputting (no pause)"
  exit 0
fi
mapfile -t BOTS < <(jq -r '.bots[]?.id // empty' <<<"$BOTS_JSON" 2>/dev/null)
if [ "${#BOTS[@]}" -eq 0 ]; then
  echo "bot-sessions: registry lists no bots; assuming a bot may be outputting (no pause)"
  exit 0
fi

# Unreadable session DB = cannot prove every bot is idle = never pause.
if [ ! -f "$DB" ] || ! command -v sqlite3 >/dev/null 2>&1; then
  echo "bot-sessions: session database unreadable ($DB); assuming a bot may be outputting (no pause)"
  exit 0
fi

INVALID_IDS=""
if [ -f "$INVALID" ]; then
  INVALID_IDS=$(jq -r '.bots[]?.id // empty' "$INVALID" 2>/dev/null || true)
fi

# Everything older than this is a stale leftover from a previous round, not
# "currently outputting". The failure_guard passes OPENCODE_START_T0 so only
# output produced *this* round counts.
NOW_MS=$(date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )))
if [ -n "${OPENCODE_START_T0:-}" ]; then
  case "$OPENCODE_START_T0" in
    ''|*[!0-9]*) SINCE_MS=$(( NOW_MS - WINDOW * 1000 )); SINCE_LABEL="last ${WINDOW}s (bad round start)" ;;
    *) SINCE_MS=$(( OPENCODE_START_T0 * 1000 )); SINCE_LABEL="round start ${OPENCODE_START_T0}" ;;
  esac
else
  SINCE_MS=$(( NOW_MS - WINDOW * 1000 ))
  SINCE_LABEL="last ${WINDOW}s"
fi

state_of() {
  local id="$1" first="$2" f="" sid
  if [ "$first" = "1" ]; then
    f="$CFG/tg-chats.json"
  else
    f="$CFG/tg-chats-${id}.json"
  fi
  [ -f "$f" ] || return 0
  sid=$(jq -r '.front // empty' "$f" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid"; return 0 ;; esac
  sid=$(jq -r '.pinned // empty' "$f" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid" ;; esac
}

# Echo "active" or "idle"; echo nothing when the session is unknown/archived.
session_activity() {
  local sid="$1" row busy idle upd arch
  [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  case "$sid" in *[!A-Za-z0-9_-]*) return 0 ;; esac
  row=$(sqlite3 "$DB" "SELECT COALESCE(time_busy,0) || '|' || COALESCE(time_idle,0) || '|' || COALESCE(time_updated,0) || '|' || COALESCE(time_archived,0) FROM session_v2 WHERE id='$sid' LIMIT 1;" 2>/dev/null || true)
  [ -n "$row" ] || return 0
  busy="${row%%|*}"; row="${row#*|}"
  idle="${row%%|*}"; row="${row#*|}"
  upd="${row%%|*}"; arch="${row#*|}"
  case "$busy" in ''|*[!0-9]*) busy=0 ;; esac
  case "$idle" in ''|*[!0-9]*) idle=0 ;; esac
  case "$upd" in ''|*[!0-9]*) upd=0 ;; esac
  case "$arch" in ''|*[!0-9]*) arch=0 ;; esac
  # time_suspended is NOT an inactive flag: OpenCode sets it equal to
  # time_busy on a live turn (verified on live sessions). Only archive is a
  # real "not active" marker.
  if [ "$arch" != "0" ]; then
    echo "idle"
    return 0
  fi
  if [ "$busy" -gt "$idle" ] && [ "$upd" -ge "$SINCE_MS" ]; then
    echo "active"
    return 0
  fi
  # Fallback: the latest assistant message never completed (still streaming).
  local msg type mupd completed
  msg=$(sqlite3 "$DB" "SELECT type || '|' || COALESCE(time_updated,0) || '|' || COALESCE(json_extract(data,'\$.time.completed'),0) FROM session_message WHERE session_id='$sid' ORDER BY time_created DESC LIMIT 1;" 2>/dev/null || true)
  [ -n "$msg" ] || { echo "idle"; return 0; }
  type="${msg%%|*}"; msg="${msg#*|}"
  mupd="${msg%%|*}"; completed="${msg#*|}"
  case "$mupd" in ''|*[!0-9]*) mupd=0 ;; esac
  case "$completed" in ''|*[!0-9]*) completed=0 ;; esac
  if [ "$type" = "assistant" ] && [ "$completed" = "0" ] && [ "$mupd" -ge "$SINCE_MS" ]; then
    echo "active"
    return 0
  fi
  echo "idle"
}

first=1
for id in "${BOTS[@]}"; do
  [ -n "$id" ] || continue
  if [ -n "$INVALID_IDS" ] && printf '%s\n' "$INVALID_IDS" | grep -qxF -- "$id"; then
    echo "bot-sessions: $id inactive (token invalid, cannot output)"
    first=0
    continue
  fi
  sid=$(state_of "$id" "$first")
  first=0
  if [ -z "$sid" ]; then
    echo "bot-sessions: $id inactive (no resumable session)"
    continue
  fi
  act=$(session_activity "$sid")
  if [ "$act" = "active" ]; then
    echo "bot-sessions: $id ACTIVE (outputting now: $sid, since $SINCE_LABEL) -> do not pause"
    exit 0
  fi
  echo "bot-sessions: $id inactive (session idle/ended/errored: $sid)"
done

echo "bot-sessions: no bot is outputting (all idle/ended/stopped/errored) -> pausing is allowed"
exit 1
