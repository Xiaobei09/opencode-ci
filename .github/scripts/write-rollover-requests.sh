#!/usr/bin/env bash
# R2649 (operator: "在连续两次429后自动创建新会话，切换并且注入：
# 阅读（原会话id）对话历史，继续任务 的提示词").
# R2675 (operator: "没有429的会话不需要换会话，多条会话同时429连续两轮时只换
# 先429（时间戳）的那个"): the old writer queued a rollover for EVERY bound bot
# session, including sessions that never hit 429. The plugin log cannot identify
# them (session ids are truncated), so auto-continue records durable per-session
# evidence under ~/.config/opencode (full sid + first/last 429 timestamps + run
# id). This script joins that evidence with the sessions currently bound to a
# bot, counts quota rounds per session, and writes exactly ONE request.
# R2700 (operator: "改成1就换会话，重置为0，同时显示两个计数器"): switch as soon
# as a bound session has 429 evidence this round (streak >= 1); after writing the
# request reset that session's streak to 0. Still one request per round — the
# earliest first-429 session wins, the rest wait for later rounds.
# R2797 (operator: "还是没有429换会话/重启ci"): a rollover-created successor
# whose injected seed prompt immediately 429'd must NOT chain another rollover.
# That synthetic 429 (userInitiated=false) is the DOA signal; resume-once owns
# exactly one recovery attempt via ~/.config/opencode/rollover-seeds/<sid>.json.
# Legacy evidence without an explicit userInitiated field keeps the old behavior.
# R2814 (operator: "先修429换会话问题，全面排查"): "immediately" must be proven,
# not assumed from a 24h marker. The guard now requires the durable first429At
# to fall inside the seed's own first-turn window (and attempts<1). Otherwise a
# successor that ran healthily for hours is misclassified as DOA forever.
# R2769 (operator: "多个会话都429-下一轮直接给最先429的换；只有一个会话429，
# 等计数器到1时的新一轮换"):
#   * multiple sessions with fresh 429 evidence: switch the earliest first-429
#     session directly (no counter wait); the request is durable and the bridge
#     consumes it at the start of the next round;
#   * exactly one session: wait until the 429 counter (CI_429_STREAK, passed in
#     as ROLLOVER_429_COUNTER after this round's increment) reaches 1; then the
#     same next-round switch happens. This also covers a lone 429 in a round
#     that otherwise produced healthy turns.
# The caller now evaluates this script on ANY round with fresh evidence, not
# only on egress-only quota rounds, so the evidence is not deleted first.
#
# The request lives under $HOME/.config/opencode so the environment snapshot
# (env-sync / release pack) carries it across the CI restart. It is intentionally
# NOT under /tmp, which does not survive a run.
#
# Usage: write-rollover-requests.sh [reason]
# Env:   ROLLOVER_REQUEST_DIR     (default $HOME/.config/opencode/rollover-requests)
#        QUOTA_429_EVIDENCE_PATH  (default $HOME/.config/opencode/quota-429-evidence.json)
#        QUOTA_429_STREAKS_PATH   (default $HOME/.config/opencode/quota-429-streaks.json)
#        GITHUB_RUN_ID            current run (evidence freshness)
#        ROLLOVER_429_COUNTER     post-increment 429 counter (single-session gate)
#        ROLLOVER_ON_429=0        disables writing entirely
set +eu

# R2668 follow-up: Actions logs are world-readable. Never echo a complete
# session id; keep the same 8-character prefix used by run-opencode.sh.
redact_sid() {
  printf '%s' "$1" | sed -E 's/^(ses_[A-Za-z0-9_-]{4})[A-Za-z0-9_-]+$/\1…/'
}

REASON="${1:-429-streak-1}"
if [ "${ROLLOVER_ON_429:-1}" = "0" ]; then
  echo "rollover disabled (ROLLOVER_ON_429=0)"
  echo "rollover_triggered=0"
  exit 0
fi

CFG="$HOME/.config/opencode"
DIR="${ROLLOVER_REQUEST_DIR:-$CFG/rollover-requests}"
EVIDENCE="${QUOTA_429_EVIDENCE_PATH:-$CFG/quota-429-evidence.json}"
STREAKS="${QUOTA_429_STREAKS_PATH:-$CFG/quota-429-streaks.json}"
SEED_DIR="${ROLLOVER_SEED_DIR:-$CFG/rollover-seeds}"
# R2814: a seed marker only suppresses a rollover when the 429 is still the
# seed's own first turn. A successor that ran healthily for hours is not DOA.
# The window is generous enough for queue/startup delays but far below the old
# 24h marker lifetime that swallowed the 2026-11-18 20:37 normal quota 429.
SEED_DOA_WINDOW_MS="${ROLLOVER_SEED_DOA_WINDOW_MS:-600000}"
case "$SEED_DOA_WINDOW_MS" in ''|*[!0-9]*) SEED_DOA_WINDOW_MS=600000 ;; esac
[ "$SEED_DOA_WINDOW_MS" -gt 0 ] || SEED_DOA_WINDOW_MS=600000
[ "$SEED_DOA_WINDOW_MS" -le 3600000 ] || SEED_DOA_WINDOW_MS=3600000
# R2780: reuse the exact "can the bridge consume this request now?" gate so a
# stopped/halted/offline Bot cannot monopolize the one request per round.
_RO_PENDING="$(dirname "$0")/rollover-pending.sh"
[ -f "$_RO_PENDING" ] && . "$_RO_PENDING" 2>/dev/null || true
[ -d "$CFG" ] || { echo "rollover: no $CFG; skip"; echo "rollover_triggered=0"; exit 0; }
if ! mkdir -p "$DIR" 2>/dev/null; then
  echo "::warning::rollover: cannot create request dir $DIR"
  echo "rollover_triggered=0"
  exit 0
fi

TS=$(date +%s%3N)
RUN="${GITHUB_RUN_ID:-}"

# Collect only sessions currently bound to a Bot. Sessions that are not bound
# have nothing to switch, and sessions that left the registry (already switched)
# must not keep an old streak alive.
SIDS=$(
  for st in "$CFG"/tg-chats.json "$CFG"/tg-chats-*.json; do
    [ -f "$st" ] || continue
    # R2650: the per-Bot toggle lives in that Bot's state file (missing = on).
    # A Bot turned off via the TG menu must not get a switch request at all.
    # NB: do NOT use jq's `//` here — `false // true` is true in jq.
    if [ "$(jq -r '.rollover429' "$st" 2>/dev/null || true)" = "false" ]; then
      echo "rollover: skip $(basename "$st") (rollover429=false)" >&2
      continue
    fi
    sid=$(jq -r '.front // empty' "$st" 2>/dev/null || true)
    case "$sid" in ses_*) ;; *) sid=$(jq -r '.pinned // empty' "$st" 2>/dev/null || true) ;; esac
    # R2651: only the exact session-id shape may become a filename. A corrupt
    # or forged `front` containing `/` or `..` would otherwise make the write
    # land outside the request directory.
    case "$sid" in
      ses_*) ;;
      *) continue ;;
    esac
    case "$sid" in
      *[!A-Za-z0-9_-]*) echo "rollover: skip unsafe session id $(printf '%s' "$sid" | cut -c1-8)…" >&2 ;;
      *) printf '%s\n' "$sid" ;;
    esac
  done | awk 'NF && !seen[$0]++'
)
if [ -z "$SIDS" ]; then
  echo "rollover: no bound session in $CFG; skip"
  echo "rollover_triggered=0"
  exit 0
fi

# Previous per-session streaks (durable across runs, like the evidence file).
PREV='{}'
if [ -f "$STREAKS" ]; then
  PREV=$(jq -c 'if type == "object" then . else {} end' "$STREAKS" 2>/dev/null || true)
fi
[ -n "$PREV" ] || PREV='{}'

# Rebuild from the current bound set only: a session without 429 evidence in
# THIS run gets no entry (streak broken), regardless of older evidence.
NEW=$(jq -cn --argjson ts "$TS" --arg run "$RUN" '{updatedAt:$ts,run:$run,sessions:{}}')
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  # Evidence is fresh only when it was written by the current workflow run.
  EV=$(jq -c --arg sid "$sid" --arg run "$RUN" \
    '.sessions[$sid]? // empty | select((.run // "") == $run)' "$EVIDENCE" 2>/dev/null || true)
  if [ -n "$EV" ]; then
    EV_FIRST=$(printf '%s' "$EV" | jq -r '.first429At // 0' 2>/dev/null || echo 0)
    EV_LAST=$(printf '%s' "$EV" | jq -r '.last429At // 0' 2>/dev/null || echo 0)
    EV_USER=$(printf '%s' "$EV" | jq -r '.userInitiated == true' 2>/dev/null || echo false)
    # R2797: distinguish "explicitly synthetic" (false) from legacy evidence
    # that predates R2795 and has no userInitiated field at all.
    EV_USER_KNOWN=$(printf '%s' "$EV" | jq -r 'has("userInitiated")' 2>/dev/null || echo false)
    case "$EV_FIRST" in ''|*[!0-9]*) EV_FIRST=0 ;; esac
    case "$EV_LAST" in ''|*[!0-9]*) EV_LAST=0 ;; esac
    UPDATED=$(printf '%s' "$NEW" | jq -c --argjson prev "$PREV" --arg sid "$sid" --argjson first "$EV_FIRST" --argjson last "$EV_LAST" --argjson user "$EV_USER" --argjson known "$EV_USER_KNOWN" '
      (($prev.sessions // {})[$sid] // {}) as $p
      | .sessions[$sid] = {
          streak: (($p.streak // 0) + 1),
          first429At: ([ ($p.first429At // 0), $first ] | map(select(. > 0)) | min // 0),
          last429At: ([ ($p.last429At // 0), $last ] | map(select(. > 0)) | max // 0),
          userInitiated: (($p.userInitiated // false) or $user),
          userInitiatedKnown: (($p.userInitiatedKnown // false) or $known)
        }' 2>/dev/null)
    [ -n "$UPDATED" ] && NEW="$UPDATED"
  else
    UPDATED=$(printf '%s' "$NEW" | jq -c --arg sid "$sid" 'del(.sessions[$sid])' 2>/dev/null)
    [ -n "$UPDATED" ] && NEW="$UPDATED"
  fi
done <<< "$SIDS"

# R2700/R2769: streak >= 1 means the session has fresh 429 evidence. Order by
# the earliest first-429 (sid only as a deterministic tie-break). Exactly one
# request per invocation even when several sessions have 429 evidence.
CANDIDATES=$(printf '%s' "$NEW" | jq -c '
  [ .sessions | to_entries[]
    | select((.value.streak | type) == "number" and .value.streak >= 1)
    | select((.value.first429At | type) == "number" and .value.first429At > 0)
    | {sid: .key, first: .value.first429At, user: (.value.userInitiated == true),
       userKnown: (.value.userInitiatedKnown == true)} ]
  | sort_by([.first, .sid])' 2>/dev/null || true)
[ -n "$CANDIDATES" ] || CANDIDATES='[]'
CANDIDATE_N=$(printf '%s' "$CANDIDATES" | jq -r 'length' 2>/dev/null || echo 0)
case "$CANDIDATE_N" in ''|*[!0-9]*) CANDIDATE_N=0 ;; esac

# R2797: do not chain a rollover from the synthetic 429 produced by the previous
# rollover's seed prompt. Legacy evidence (no explicit userInitiated) keeps the
# old behavior: it may still switch. A real-user 429 (user=true) always may.
if [ -d "$SEED_DIR" ] && [ "$CANDIDATE_N" -gt 0 ]; then
  _NOW_MS=$(date +%s%3N)
  _FILTERED='[]'
  while IFS=$'\t' read -r _sid _first _user _known; do
    [ -n "$_sid" ] || continue
    _skip=0
    case "$_sid" in
      ses_*[!A-Za-z0-9_-]*|ses_) _skip=0 ;;
      ses_*)
        if [ "$_known" = "true" ] && [ "$_user" != "true" ]; then
          _seed="$SEED_DIR/$_sid.json"
          if [ -s "$_seed" ]; then
            _seed_at=$(jq -r '.at // 0' "$_seed" 2>/dev/null || echo 0)
            case "$_seed_at" in ''|*[!0-9]*) _seed_at=0 ;; esac
            _seed_attempts=$(jq -r '.attempts // 0' "$_seed" 2>/dev/null || echo 0)
            case "$_seed_attempts" in ''|*[!0-9]*) _seed_attempts=0 ;; esac
            case "$_first" in ''|*[!0-9]*) _first=0 ;; esac
            # R2814: only an **unconsumed** seed whose first 429 happened in the
            # seed's own turn may suppress the switch. first429At is durable and
            # survives across runs; request time would drift after a pause.
            if [ "$_seed_at" -gt 0 ] \
               && [ $((_NOW_MS - _seed_at)) -le 86400000 ] \
               && [ "$_seed_attempts" -lt 1 ] \
               && [ "$_first" -gt 0 ] \
               && [ "$_first" -ge $((_seed_at - 10000)) ] \
               && [ $((_first - _seed_at)) -le "$SEED_DOA_WINDOW_MS" ]; then
              _skip=1
            fi
          fi
        fi
        ;;
    esac
    if [ "$_skip" = 1 ]; then
      echo "rollover: skip $(redact_sid "$_sid") (synthetic 429 on rollover successor's first turn; resume-once owns the one-shot retry)" >&2
      continue
    fi
    _FILTERED=$(printf '%s' "$_FILTERED" | jq -c \
      --arg sid "$_sid" --argjson first "$_first" --argjson user "$_user" --argjson known "$_known" \
      '. + [{sid:$sid,first:$first,user:$user,userKnown:$known}]' 2>/dev/null) \
      || _FILTERED='[]'
  done <<< "$(printf '%s' "$CANDIDATES" | jq -r '.[] | [.sid, (.first|tostring), (.user|tostring), (.userKnown|tostring)] | @tsv' 2>/dev/null)"
  CANDIDATES="$_FILTERED"
  CANDIDATE_N=$(printf '%s' "$CANDIDATES" | jq -r 'length' 2>/dev/null || echo 0)
  case "$CANDIDATE_N" in ''|*[!0-9]*) CANDIDATE_N=0 ;; esac
fi

# R2780 (2026-11-18): bot6 was stopped with the earliest-429 session, so every
# round wrote a request the bridge could only keep waiting in. The active bot5
# session (later 429) never got its own request and kept hitting quota for
# 1h23m. Prefer the earliest session whose owner can consume the switch NOW;
# if none can, keep the legacy waiting request so it survives until the Bot
# resumes.
CANDIDATES_ACTIONABLE='[]'
if declare -F rollover_sid_actionable >/dev/null 2>&1; then
  while IFS=$'\t' read -r _sid _first _user; do
    [ -n "$_sid" ] || continue
    case "$_first" in ''|*[!0-9]*) _first=0 ;; esac
    [ "$_user" = "true" ] || _user=false
    if rollover_sid_actionable "$_sid" false "$_user"; then
      CANDIDATES_ACTIONABLE=$(printf '%s' "$CANDIDATES_ACTIONABLE" | jq -c \
        --arg sid "$_sid" --argjson first "$_first" --argjson user "$_user" \
        '. + [{sid:$sid,first:$first,user:$user}]' 2>/dev/null) \
        || CANDIDATES_ACTIONABLE='[]'
    fi
  done <<< "$(printf '%s' "$CANDIDATES" | jq -r '.[] | [.sid, (.first|tostring), (.user|tostring)] | @tsv' 2>/dev/null)"
else
  # Older/partial checkout without rollover-pending.sh: preserve the legacy
  # behavior (treat every candidate as actionable) instead of marking all as
  # waiting forever.
  CANDIDATES_ACTIONABLE="$CANDIDATES"
fi
ACTIONABLE_N=$(printf '%s' "$CANDIDATES_ACTIONABLE" | jq -r 'length' 2>/dev/null || echo 0)
case "$ACTIONABLE_N" in ''|*[!0-9]*) ACTIONABLE_N=0 ;; esac

POOL="$CANDIDATES"
POOL_N="$CANDIDATE_N"
CHOSEN_ACTIONABLE=0
if [ "$ACTIONABLE_N" -gt 0 ]; then
  POOL="$CANDIDATES_ACTIONABLE"
  POOL_N="$ACTIONABLE_N"
  CHOSEN_ACTIONABLE=1
  if [ "$CANDIDATE_N" -gt "$ACTIONABLE_N" ]; then
    echo "rollover: skipping $((CANDIDATE_N - ACTIONABLE_N)) waiting session(s) (stopped/halted/offline owner); active 429 session takes the switch"
  fi
fi

COUNTER="${ROLLOVER_429_COUNTER:-0}"
case "$COUNTER" in ''|*[!0-9]*) COUNTER=0 ;; esac

MODE=none
CHOSEN=""
if [ "$POOL_N" -ge 2 ]; then
  # R2769: multiple sessions 429'd — switch the earliest one directly; the
  # request is consumed at the start of the next round.
  MODE=multi
  CHOSEN=$(printf '%s' "$POOL" | jq -r '.[0].sid // empty' 2>/dev/null || true)
  [ -n "$CHOSEN" ] && echo "rollover: ${POOL_N} session(s) with fresh 429 evidence; switching the earliest (next round)"
elif [ "$POOL_N" -eq 1 ]; then
  MODE=single
  # R2769: a lone 429 session waits for the 429 counter to reach 1. The caller
  # passes the post-increment value, so the first counted round qualifies and
  # the request is consumed in the new round.
  if [ "$COUNTER" -ge 1 ]; then
    CHOSEN=$(printf '%s' "$POOL" | jq -r '.[0].sid // empty' 2>/dev/null || true)
    [ -n "$CHOSEN" ] && echo "rollover: single 429 session; counter=$COUNTER/1 reached, switching in the new round"
  else
    echo "rollover: single 429 session; waiting for the counter ($COUNTER/1)"
  fi
fi
echo "rollover_candidates=$CANDIDATE_N"
echo "rollover_actionable=$ACTIONABLE_N"
echo "rollover_mode=$MODE"

TRIGGERED=0
WAITING=0
if [ -n "$CHOSEN" ]; then
  case "$CHOSEN" in
    ses_*) ;;
    *) CHOSEN="" ;;
  esac
fi
if [ -n "$CHOSEN" ]; then
  FILE="$DIR/$CHOSEN.json"
  TMP="$FILE.tmp.$$"
  CHOSEN_USER=$(printf '%s' "$NEW" | jq -r --arg sid "$CHOSEN" '.sessions[$sid].userInitiated == true' 2>/dev/null || echo false)
  [ "$CHOSEN_USER" = "true" ] || CHOSEN_USER=false
  CHOSEN_FIRST=$(printf '%s' "$NEW" | jq -r --arg sid "$CHOSEN" '.sessions[$sid].first429At // 0' 2>/dev/null || echo 0)
  case "$CHOSEN_FIRST" in ''|*[!0-9]*) CHOSEN_FIRST=0 ;; esac
  if jq -n \
      --arg sid "$CHOSEN" \
      --argjson ts "$TS" \
      --argjson first "$CHOSEN_FIRST" \
      --arg reason "$REASON" \
      --arg run "$RUN" \
      --argjson user "$CHOSEN_USER" \
      '{sid:$sid,ts:$ts,first429At:$first,reason:$reason,run:$run,userInitiated:$user}' > "$TMP" 2>/dev/null \
     && mv -f "$TMP" "$FILE" 2>/dev/null; then
    if [ "$CHOSEN_ACTIONABLE" = "1" ]; then
      TRIGGERED=1
      # R2700 (operator: "重置为0"): reset the switched session's counter to 0;
      # the remaining sessions wait for later rounds instead of all switching at once.
      NEW=$(printf '%s' "$NEW" | jq -c --arg sid "$CHOSEN" '.sessions[$sid].streak = 0' 2>/dev/null || printf '%s' "$NEW")
      echo "rollover request written: $(redact_sid "$CHOSEN") (reason=$REASON, dir=$DIR)"
    else
      # R2780: the owner is stopped/halted/offline. Keep the request durable so
      # it switches when the Bot resumes, but do NOT report it as a completed
      # switch or reset the 429 counter.
      WAITING=1
      echo "rollover request kept for waiting session: $(redact_sid "$CHOSEN") (reason=$REASON, dir=$DIR)"
    fi
  else
    rm -f "$TMP" 2>/dev/null || true
    echo "::warning::rollover request write failed: $(redact_sid "$CHOSEN") (dir=$DIR)"
  fi
fi

# Persist the per-session counters even when nothing was selected: the next
# quota round rebuilds from fresh evidence, so a round without 429 clears it.
TMP_S="$STREAKS.tmp.$$"
if printf '%s\n' "$NEW" > "$TMP_S" 2>/dev/null && mv -f "$TMP_S" "$STREAKS" 2>/dev/null; then
  :
else
  rm -f "$TMP_S" 2>/dev/null || true
  echo "::warning::rollover: cannot persist $STREAKS"
fi

if [ "$TRIGGERED" = "1" ]; then
  echo "rollover_triggered=1"
else
  if [ "$WAITING" = "1" ]; then
    echo "rollover: request queued for a waiting session; switch happens after the Bot resumes"
    echo "rollover_waiting=1"
  elif [ "$CANDIDATE_N" -gt 0 ]; then
    echo "rollover: $CANDIDATE_N session(s) with 429 evidence but no switch this round (mode=$MODE)"
  else
    echo "rollover: no session with 429 evidence this round; nothing to switch"
  fi
  echo "rollover_triggered=0"
fi
