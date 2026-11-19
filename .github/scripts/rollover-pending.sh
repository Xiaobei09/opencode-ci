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
  case "$sid" in ses_*) printf '%s' "$sid" ;; esac
}

_ro_pinned() {
  local f="$1" sid=""
  sid=$(jq -r '.pinned // empty' "$f" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid" ;; esac
}

# R2785: a session that was the front when a synthetic prompt was injected may
# have moved out of front/pinned by the time its 429 arrives. It stays in the
# Bot's durable `halted` list, so that is also an ownership hint for the stop
# gate (halt-release is still honored by _ro_bot_stopped).
_ro_halted() {
  local f="$1"
  jq -r '(.halted // [])[]? | select(type == "string")' "$f" 2>/dev/null || true
}

# Mirrors tg-bridge's quotaForkMine(): only the Bot whose persisted front or
# pinned target is this session will claim the request. loop-ctl sids are NOT
# an ownership source there, so a stale request whose front already moved is
# an orphan and must not suppress anything.
_ro_bot_owns() {
  local f="$1" sid="$2"
  [ "$(_ro_front "$f")" = "$sid" ] && return 0
  [ "$(_ro_pinned "$f")" = "$sid" ] && return 0
  return 1
}

# Mirrors tg-bridge's per-Bot rollover switches. If either is off the bridge
# returns before reading requests; such a request is waiting, not actionable.
_ro_rollover_enabled_for() {
  local f="$1"
  case "${ROLLOVER_ON_429:-1}" in 0) return 1 ;; esac
  jq -e '.rollover429 == false' "$f" >/dev/null 2>&1 && return 1
  return 0
}

# Mirrors halt-release.ts: a released sid is not halted even if it is still
# present in the Bot's persisted `halted` array.
_ro_halt_released() {
  local sid="$1" rel
  rel="${HALT_RELEASE_PATH:-$(_ro_home)/.config/opencode/halt-release.json}"
  [ -s "$rel" ] && _ro_have_jq || return 1
  jq -e --arg sid "$sid" 'type == "object" and has($sid)' "$rel" >/dev/null 2>&1
}

# R2795: a real user turn's 429 may bypass the loop-stop gate, but never the
# per-session ⏹ halt. Keep the halt decision separate so the actionable gate
# can distinguish "user stopped the loop" from "user stopped this session".
_ro_bot_halted() {
  local f="$1" sid="$2" halted
  halted=$(jq -r --arg sid "$sid" '(.halted // []) | index($sid) != null' "$f" 2>/dev/null || echo false)
  [ "$halted" = "true" ] && ! _ro_halt_released "$sid"
}

# Mirrors tg-bridge's rollover gate: !manual && (loopStopped() || haltedSet).
# loopStopped() uses the Bot's current front (persistedFront), not the request
# sid, so a request for an already-remapped session is not falsely blocked.
_ro_bot_stopped() {
  local id="$1" f="$2" sid="$3" ctl front
  _ro_bot_halted "$f" "$sid" && return 0
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

# R2785: public wrapper for non-rollover callers that must honor the same
# per-Bot stop gate as the bridge. Option C arming uses it so a stopped Bot's
# front is never even armed for a quota-tail recovery.
bot_sid_stopped() {
  local id="$1" f="$2" sid="$3"
  [ -n "$id" ] && [ -n "$f" ] && [ -n "$sid" ] || return 1
  _ro_bot_stopped "$id" "$f" "$sid"
}

# R2797: the ⏹ halt part of the stop gate, exposed separately. A rollover seed
# may bypass `/loop stop` for its one recovery attempt, but never a session the
# user explicitly halted.
bot_sid_halted() {
  local id="$1" f="$2" sid="$3"
  [ -n "$id" ] && [ -n "$f" ] && [ -n "$sid" ] || return 1
  _ro_bot_halted "$f" "$sid"
}

_ro_seed_dir() { printf '%s' "${ROLLOVER_SEED_DIR:-$(_ro_home)/.config/opencode/rollover-seeds}"; }
# R2814: a seed marker only suppresses/arms the successor's own first turn.
# Keep the default in sync with write-rollover-requests.sh and tg-bridge.
_ro_seed_doa_window() {
  local w="${ROLLOVER_SEED_DOA_WINDOW_MS:-600000}"
  case "$w" in ''|*[!0-9]*) w=600000 ;; esac
  [ "$w" -gt 0 ] || w=600000
  [ "$w" -le 3600000 ] || w=3600000
  printf '%s' "$w"
}

# R2797: a 429 rollover-created successor whose seed prompt immediately 429'd
# must still be armed for Option C even when the Bot's loop is stopped. The
# seed is one-shot: attempts>=1 or older than 24h no longer arms anything.
# R2814: when the caller knows the observed 429 time, the marker only counts
# while that 429 is still the seed's first turn; otherwise a healthy successor
# that later hit the normal quota would be misclassified forever.
rollover_seed_pending() {
  local sid="$1" observed="${2:-0}" f at attempts now
  [[ "$sid" =~ ^ses_[A-Za-z0-9_-]+$ ]] || return 1
  f="$(_ro_seed_dir)/$sid.json"
  [ -s "$f" ] && _ro_have_jq || return 1
  attempts=$(jq -r '.attempts // 0' "$f" 2>/dev/null || echo 0)
  at=$(jq -r '.at // 0' "$f" 2>/dev/null || echo 0)
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  [ "$attempts" -lt 1 ] || return 1
  [ "$at" -gt 0 ] || return 1
  [ "$(jq -r --arg sid "$sid" '.sid // empty' "$f" 2>/dev/null)" = "$sid" ] || return 1
  now=$(date +%s%3N)
  [ $((now - at)) -le 86400000 ] || return 1
  case "$observed" in ''|*[!0-9]*) observed=0 ;; esac
  if [ "$observed" -gt 0 ]; then
    [ $((observed - at)) -ge -10000 ] || return 1
    [ $((observed - at)) -le "$(_ro_seed_doa_window)" ] || return 1
  fi
  return 0
}

# R2785: map a session id from a plugin log line (auto-continue truncates it to
# 8 chars in public logs) to its unique Bot owner, then apply the stop/halt
# gate. Returns 1 for orphan/shared prefixes so a real 429 is never hidden.
# egress-watch.sh uses this to ignore a quota 429 produced by an intentionally
# stopped Bot instead of ending and relaying the whole CI round.
# R2800: the resolver is separate so egress-watch can ask other questions about
# the same unique owner (e.g. "does it have a pending rollover seed?").
sid_owner_resolve() {
  local raw="$1" id state front pinned halts cand hit_id="" hit_state="" hit_sid="" hits=0 found=""
  [ -n "$raw" ] || return 1
  _ro_have_jq || return 1
  while IFS=$'\t' read -r id state; do
    [ -n "$id" ] || continue
    front=$(_ro_front "$state")
    pinned=$(_ro_pinned "$state")
    halts=$(_ro_halted "$state")
    found=""
    for cand in "$front" "$pinned" $halts; do
      [ -n "$cand" ] || continue
      case "$cand" in
        "$raw"|"$raw"*) found=1; break ;;
      esac
    done
    [ -n "$found" ] || continue
    hits=$((hits + 1))
    [ "$hits" -eq 1 ] || return 1
    hit_id="$id"
    hit_state="$state"
    hit_sid="$cand"
  done < <(_ro_bot_states)
  [ "$hits" -eq 1 ] || return 1
  printf '%s\t%s\t%s' "$hit_id" "$hit_state" "$hit_sid"
}

sid_owner_stopped() {
  local raw="$1" resolved id state sid
  resolved=$(sid_owner_resolve "$raw") || return 1
  IFS=$'\t' read -r id state sid <<< "$resolved"
  _ro_bot_stopped "$id" "$state" "$sid"
}

# R2805: ⏹ halted is the hard gate for tail recovery; `/loop stop` is not.
# Arming skips halted sessions so we do not even query them, but a stopped Bot
# is still armed — resume-once only injects when the tail is actually
# interrupted (clean tails stay skipped).
sid_owner_halted() {
  local raw="$1" resolved _state sid
  resolved=$(sid_owner_resolve "$raw") || return 1
  IFS=$'\t' read -r _ _state sid <<< "$resolved"
  _ro_bot_halted "$_state" "$sid"
}

# R2800: a rollover successor whose seed prompt 429'd must end the round even
# when its Bot's loop is stopped, otherwise the watcher ignores the synthetic
# 429 and the successor stays dead until something else ends the run. The next
# run arms the seed (Option C) and performs the one retry. A ⏹ halted session
# is still ignored: recovery would refuse it, so restarting the round is pure
# churn. attempts>=1 / stale seeds are already excluded by rollover_seed_pending.
sid_owner_seed_pending() {
  local raw="$1" observed="${2:-0}" resolved _state sid
  resolved=$(sid_owner_resolve "$raw") || return 1
  IFS=$'\t' read -r _ _state sid <<< "$resolved"
  _ro_bot_halted "$_state" "$sid" && return 1
  rollover_seed_pending "$sid" "$observed"
}

# 0 = a request for this sid can be consumed this run. `manual=true` bypasses
# loop/halted gates, exactly like the bridge. `user=true` (R2795) bypasses only
# the loop-stop gate: a real user message that hit 429 must keep working even
# when the Bot's auto-loop was stopped earlier. A per-session ⏹ halt still
# blocks it. Shared by the request reader and the CI-side writer (R2780: an
# earlier 429 on a stopped Bot must not starve an active Bot's switch).
rollover_sid_actionable() {
  local sid="$1" manual="${2:-false}" user="${3:-false}" id state
  [[ "$sid" =~ ^ses_[A-Za-z0-9_-]+$ ]] || return 1
  _ro_have_jq || return 0 # no jq: keep the old conservative behavior
  # The bridge does not even read request files when the global switch is off.
  case "${ROLLOVER_ON_429:-1}" in 0) return 1 ;; esac
  while IFS=$'\t' read -r id state; do
    [ -n "$id" ] || continue
    _ro_bot_owns "$state" "$sid" || continue
    # A Bot with its per-Bot switch off will not consume the request.
    _ro_rollover_enabled_for "$state" || continue
    # An offline Bot cannot consume even a manual request; do not let an
    # orphan manual request block the next run forever.
    bot_is_offline "$id" && continue
    # Manual requests bypass loop/halted gates, exactly like the bridge.
    if [ "$manual" = "true" ]; then
      return 0
    fi
    # A real user turn may bypass the loop stop, but never a session halt.
    _ro_bot_halted "$state" "$sid" && continue
    if [ "$user" = "true" ] || ! _ro_bot_stopped "$id" "$state" "$sid"; then
      return 0
    fi
  done < <(_ro_bot_states)
  # No online, non-stopped owner can consume it -> not actionable.
  return 1
}

# 0 = the bridge can consume this request this run (so do not also resume the
#     session), 1 = waiting/orphan/expired (so quota-tail recovery may proceed).
rollover_request_actionable() {
  local f="$1" ts now sid manual user
  [ -f "$f" ] || return 1
  _ro_have_jq || return 0 # no jq: keep the old conservative behavior
  # The bridge does not even read request files when the global switch is off.
  case "${ROLLOVER_ON_429:-1}" in 0) return 1 ;; esac
  ts=$(jq -r '.ts // 0' "$f" 2>/dev/null || echo 0)
  now=$(date +%s%3N)
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  # The bridge deletes malformed/expired requests (>24h) instead of consuming.
  [ "$ts" -gt 0 ] || return 1
  [ $((now - ts)) -le 86400000 ] || return 1
  sid=$(jq -r '.sid // empty' "$f" 2>/dev/null || true)
  [ -n "$sid" ] || sid=$(basename "$f" .json)
  [[ "$sid" =~ ^ses_[A-Za-z0-9_-]+$ ]] || return 1
  manual=$(jq -r '.manual // false' "$f" 2>/dev/null || echo false)
  user=$(jq -r '.userInitiated // false' "$f" 2>/dev/null || echo false)
  rollover_sid_actionable "$sid" "$manual" "$user"
}

rollover_pending_for() {
  local sid="$1" f
  [ -n "$sid" ] || return 1
  f="$(_ro_dir)/$sid.json"
  rollover_request_actionable "$f"
}
