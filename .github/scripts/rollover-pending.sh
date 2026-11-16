#!/usr/bin/env bash
# R2665 (operator: "你怎么也没有额度尾恢复？"): decide whether a durable
# 429 rollover request is ACTIONABLE in this run.
#
# R2656 made a pending rollover suppress quota-tail recovery. That is only
# correct while the rollover can actually run. The bridge deliberately keeps a
# request when the Bot's loop is stopped or the session is halted, and it also
# keeps requests whose Bot is offline. Treating those "waiting" requests as
# pending deadlocks both mechanisms:
#   - quota-tail recovery is disabled for every Bot, and
#   - the rollover never runs because the loop is stopped.
# R2665: waiting/orphan requests must not suppress quota-tail recovery. Only a
# request that an online, non-stopped Bot can consume in this run counts.
#
# Callers:
#   select-egress-step.sh  -> visibility only; it no longer disables QR globally
#   run-opencode.sh        -> skip Option C for the session being rolled over
#
# Usage:
#   . "$(dirname "$0")/rollover-pending.sh"
#   rollover_request_actionable /path/to/ses_x.json
#   rollover_pending_for ses_x
#   bot_is_offline bot6

_ro_home() { printf '%s' "${HOME:-/root}"; }
_ro_dir() { printf '%s' "${ROLLOVER_REQUEST_DIR:-$(_ro_home)/.config/opencode/rollover-requests}"; }
_ro_ctl() { printf '%s' "${LOOP_CTL_PATH:-$(_ro_home)/.config/opencode/loop-ctl.json}"; }
_ro_have_jq() { command -v jq >/dev/null 2>&1; }

# Print "botid<TAB>statefile" in registry order (first registry entry owns
# tg-chats.json; the rest own tg-chats-<id>.json), matching
# auto-continue.resolveExtraTargetPaths and the Option C arming loop.
_ro_bot_states() {
  local reg first=1 id f
  reg="$(_ro_home)/.config/opencode/tg-bots.json"
  if [ -s "$reg" ] && _ro_have_jq; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if [ "$first" = 1 ]; then
        f="$(_ro_home)/.config/opencode/tg-chats.json"
        first=0
      else
        f="$(_ro_home)/.config/opencode/tg-chats-${id}.json"
      fi
      [ -f "$f" ] && printf '%s\t%s\n' "$id" "$f"
    done < <(jq -r '.bots[]?.id // empty' "$reg" 2>/dev/null || true)
    return 0
  fi
  for f in "$(_ro_home)/.config/opencode/tg-chats.json" "$(_ro_home)"/.config/opencode/tg-chats-*.json; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .json)
    if [ "$id" = "tg-chats" ]; then id=primary; else id=${id#tg-chats-}; fi
    printf '%s\t%s\n' "$id" "$f"
  done
}

# The bridge writes token-rejected/duplicate Bots here at boot; their state
# files still exist, but no process will consume a rollover or answer a resume.
bot_is_offline() {
  local id="$1" f
  [ -n "$id" ] || return 1
  f="$(_ro_home)/.config/opencode/tg-token-invalid.json"
  [ -s "$f" ] && _ro_have_jq || return 1
  jq -e --arg id "$id" 'any(.bots[]?; .id == $id)' "$f" >/dev/null 2>&1
}

_ro_front() {
  local f="$1" sid=""
  sid=$(jq -r '.front // empty' "$f" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid"; return 0 ;; esac
  sid=$(jq -r '.pinned // empty' "$f" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid" ;; esac
}

# Does this Bot own/claim the request's session? Front/pinned is the normal
# case; loop-ctl sids covers a shared session whose front has already moved.
_ro_bot_owns() {
  local id="$1" f="$2" sid="$3" ctl front
  front=$(_ro_front "$f")
  [ "$front" = "$sid" ] && return 0
  ctl="$(_ro_ctl)"
  [ -s "$ctl" ] && _ro_have_jq || return 1
  jq -e --arg bot "$id" --arg sid "$sid" \
    '(.bots[$bot].sids // []) | index($sid) != null' "$ctl" >/dev/null 2>&1
}

# Mirrors tg-bridge's rollover gate: !manual && (loopStopped() || haltedSet).
# loopStopped() uses the Bot's current front (persistedFront), not the request
# sid, so a request for an already-remapped session is not falsely blocked.
_ro_bot_stopped() {
  local id="$1" f="$2" sid="$3" ctl front halted
  halted=$(jq -r --arg sid "$sid" '(.halted // []) | index($sid) != null' "$f" 2>/dev/null || echo false)
  [ "$halted" = "true" ] && return 0
  ctl="$(_ro_ctl)"
  [ -s "$ctl" ] && _ro_have_jq || return 1
  front=$(_ro_front "$f")
  jq -e --arg bot "$id" --arg front "$front" '
    if .stopped == true then true
    else (.bots[$bot] // {}) as $e
      | ($e.stopped == true)
        and (((($e.sids // []) | length) == 0) or ((($e.sids // []) | index($front)) != null))
    end
  ' "$ctl" >/dev/null 2>&1
}

# 0 = the bridge can consume this request this run (so do not also resume the
#     session), 1 = waiting/orphan/expired (so quota-tail recovery may proceed).
rollover_request_actionable() {
  local f="$1" ts now sid manual id state
  [ -f "$f" ] || return 1
  _ro_have_jq || return 0 # no jq: keep the old conservative behavior
  ts=$(jq -r '.ts // 0' "$f" 2>/dev/null || echo 0)
  now=$(date +%s%3N)
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  if [ "$ts" -gt 0 ] && [ $((now - ts)) -gt 86400000 ]; then
    return 1 # the bridge deletes requests older than 24h
  fi
  manual=$(jq -r '.manual // false' "$f" 2>/dev/null || echo false)
  sid=$(jq -r '.sid // empty' "$f" 2>/dev/null || true)
  [ -n "$sid" ] || sid=$(basename "$f" .json)
  while IFS=$'\t' read -r id state; do
    [ -n "$id" ] || continue
    _ro_bot_owns "$id" "$state" "$sid" || continue
    # An offline Bot cannot consume even a manual request; do not let an
    # orphan manual request block the next run forever.
    bot_is_offline "$id" && continue
    # Manual requests bypass loop/halted gates, exactly like the bridge.
    if [ "$manual" = "true" ] || ! _ro_bot_stopped "$id" "$state" "$sid"; then
      return 0
    fi
  done < <(_ro_bot_states)
  # No online, non-stopped owner can consume it -> not actionable.
  return 1
}

rollover_pending_for() {
  local sid="$1" f
  [ -n "$sid" ] || return 1
  f="$(_ro_dir)/$sid.json"
  rollover_request_actionable "$f"
}
