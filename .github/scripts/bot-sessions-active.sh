#!/usr/bin/env bash
# R2641 (operator): "没有200的429才计算进连续3轮，并且要求所有bot对应的
# 会话都不是活跃（错误/停止）的时候才停".
#
# The 3-round no-200 quota-429 stop is a last resort. Before pausing the loop
# the workflow must prove that EVERY registered bot session is inactive, i.e.
# stopped by the operator or errored/unusable:
#   * token-invalid   -> cannot poll at all            (error)
#   * loop-ctl stopped -> operator ran /stop or /loop stop (stopped)
#   * no bot state / no front+pinned session           (nothing to resume)
#   * front session in halted (after halt-release)     (stopped)
# and, when the session database is readable:
#   * idle_outcome = failed / interrupted              (error/stopped)
#   * time_archived / time_suspended is set            (not active)
#
# If at least one bot is still active the loop MUST keep relaying: a running
# bot is exactly the thing pausing would strand. Unreadable state is treated as
# "active" (fail-open): never pause on unknown information.
#
# Exit codes:
#   0 = at least one bot session is active (or state unreadable) -> DO NOT pause
#   1 = every bot session is inactive (stopped/errored)          -> pausing is allowed
#
# Env overrides (tests must not touch production state):
#   OPENCODE_CONFIG_DIR   default: $HOME/.config/opencode
#   OPENCODE_DB           default: $HOME/.local/share/opencode/opencode.db
set -uo pipefail

CFG="${OPENCODE_CONFIG_DIR:-${HOME:-/root}/.config/opencode}"
DB="${OPENCODE_DB:-${HOME:-/root}/.local/share/opencode/opencode.db}"
REG="$CFG/tg-bots.json"
CTL="$CFG/loop-ctl.json"
INVALID="$CFG/tg-token-invalid.json"
RELEASE="$CFG/halt-release.json"

# Unknown registry = cannot enumerate bots = never pause.
if [ ! -f "$REG" ] || ! command -v jq >/dev/null 2>&1; then
  echo "bot-sessions: registry unreadable ($REG); assuming a bot may be active (no pause)"
  exit 0
fi
if ! BOTS_JSON=$(jq -er '.' "$REG" 2>/dev/null); then
  echo "bot-sessions: registry is not valid JSON; assuming a bot may be active (no pause)"
  exit 0
fi
mapfile -t BOTS < <(jq -r '.bots[]?.id // empty' <<<"$BOTS_JSON" 2>/dev/null)
if [ "${#BOTS[@]}" -eq 0 ]; then
  echo "bot-sessions: registry lists no bots; assuming a bot may be active (no pause)"
  exit 0
fi

# loop-ctl.json is the cross-instance stop gate. A corrupt file is unknown
# state -> fail-open. A missing file simply means nobody has stopped a bot.
CTL_JSON='{}'
if [ -f "$CTL" ]; then
  if ! CTL_JSON=$(jq -er '.' "$CTL" 2>/dev/null); then
    echo "bot-sessions: loop-ctl.json is not valid JSON; assuming a bot may be active (no pause)"
    exit 0
  fi
fi

INVALID_IDS=""
if [ -f "$INVALID" ]; then
  INVALID_IDS=$(jq -r '.bots[]?.id // empty' "$INVALID" 2>/dev/null || true)
fi

# halted is the union across bot state files, minus the shared release table
# (same contract as auto-continue.ts:haltedSessions()).
HALTED=""
for f in "$CFG"/tg-chats.json "$CFG"/tg-chats-*.json; do
  [ -f "$f" ] || continue
  HALTED+=$(jq -r '.halted[]? // empty' "$f" 2>/dev/null || true)$'\n'
done
RELEASED=""
if [ -f "$RELEASE" ]; then
  RELEASED=$(jq -r 'keys[]' "$RELEASE" 2>/dev/null || true)
fi
is_released() {
  [ -n "$1" ] || return 1
  printf '%s\n' "$RELEASED" | grep -qxF -- "$1"
}

# Resolve the bot's session: front first, then pinned (run-opencode.sh uses the
# same order when it decides which session to resume).
state_of() {
  local id="$1" first="$2" f=""
  if [ "$first" = "1" ]; then
    f="$CFG/tg-chats.json"
  else
    f="$CFG/tg-chats-${id}.json"
  fi
  [ -f "$f" ] || return 0
  local sid
  sid=$(jq -r '.front // empty' "$f" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid"; return 0 ;; esac
  sid=$(jq -r '.pinned // empty' "$f" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid" ;; esac
}

# Optional session-status probe. Only used to *reduce* activity (failed /
# interrupted / archived / suspended); a missing row or unreadable DB leaves
# the bot active so unknown state never causes a pause.
session_status() {
  local sid="$1"
  [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 1
  case "$sid" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  sqlite3 "$DB" "SELECT COALESCE(idle_outcome,'') || '|' || COALESCE(time_archived,0) || '|' || COALESCE(time_suspended,0) FROM session_v2 WHERE id='$sid' LIMIT 1;" 2>/dev/null
}

first=1
for id in "${BOTS[@]}"; do
  [ -n "$id" ] || continue
  if [ -n "$INVALID_IDS" ] && printf '%s\n' "$INVALID_IDS" | grep -qxF -- "$id"; then
    echo "bot-sessions: $id inactive (error: token invalid)"
    first=0
    continue
  fi
  stopped=$(jq -r --arg id "$id" '(.bots[$id].stopped // false) | tostring' <<<"$CTL_JSON" 2>/dev/null || true)
  if [ "$stopped" = "true" ]; then
    echo "bot-sessions: $id inactive (stopped by operator)"
    first=0
    continue
  fi
  sid=$(state_of "$id" "$first")
  first=0
  if [ -z "$sid" ]; then
    echo "bot-sessions: $id inactive (no resumable session)"
    continue
  fi
  if printf '%s' "$HALTED" | grep -qxF -- "$sid" && ! is_released "$sid"; then
    echo "bot-sessions: $id inactive (session halted: $sid)"
    continue
  fi
  if row=$(session_status "$sid") && [ -n "$row" ]; then
    outcome="${row%%|*}"
    rest="${row#*|}"
    archived="${rest%%|*}"
    suspended="${rest#*|}"
    case "$outcome" in
      failed|interrupted)
        echo "bot-sessions: $id inactive (session $outcome: $sid)"
        continue
        ;;
    esac
    if [ "$archived" != "0" ] || [ "$suspended" != "0" ]; then
      echo "bot-sessions: $id inactive (session archived/suspended: $sid)"
      continue
    fi
  fi
  echo "bot-sessions: $id ACTIVE (session $sid) -> do not pause the loop"
  exit 0
done

echo "bot-sessions: all ${#BOTS[@]} registered bot session(s) are stopped/errored -> pausing is allowed"
exit 1
