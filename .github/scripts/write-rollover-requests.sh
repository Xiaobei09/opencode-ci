#!/usr/bin/env bash
# R2649 (operator: "在连续两次429后自动创建新会话，切换并且注入：
# 阅读（原会话id）对话历史，继续任务 的提示词").
#
# The workflow counts consecutive 429-only rounds in CI_429_STREAK. When that
# counter reaches 2, the round is about to be torn down, so the bridge cannot be
# asked to create a session right now. Write one durable request per bound bot
# session instead; the next run's bridge (which owns the session) claims it with
# an atomic rename, creates a fresh session, switches the bot mapping to it and
# injects the "read the old history and continue" prompt.
#
# The request lives under $HOME/.config/opencode so the environment snapshot
# (env-sync / release pack) carries it across the CI restart. It is intentionally
# NOT under /tmp, which does not survive a run.
#
# Usage: write-rollover-requests.sh [reason]
# Env:   ROLLOVER_REQUEST_DIR  (default $HOME/.config/opencode/rollover-requests)
#        ROLLOVER_ON_429=0     disables writing entirely
set +eu

REASON="${1:-429-streak-2}"
if [ "${ROLLOVER_ON_429:-1}" = "0" ]; then
  echo "rollover disabled (ROLLOVER_ON_429=0)"
  exit 0
fi

CFG="$HOME/.config/opencode"
DIR="${ROLLOVER_REQUEST_DIR:-$CFG/rollover-requests}"
[ -d "$CFG" ] || { echo "rollover: no $CFG; skip"; exit 0; }
if ! mkdir -p "$DIR" 2>/dev/null; then
  echo "::warning::rollover: cannot create request dir $DIR"
  exit 0
fi

TS=$(date +%s%3N)
RUN="${GITHUB_RUN_ID:-}"

# Collect every registered bot's persisted front/pinned session. This mirrors
# run-opencode.sh / auto-continue discovery: the first registry entry owns
# tg-chats.json, the rest own tg-chats-<id>.json; globbing also covers a missing
# registry. Multiple bots sharing one session are deduplicated so the owning
# bridge creates exactly one new session.
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
      *[!A-Za-z0-9_-]*) echo "rollover: skip unsafe session id $(printf '%s' "$sid" | cut -c1-40)" >&2 ;;
      *) printf '%s\n' "$sid" ;;
    esac
  done | awk 'NF && !seen[$0]++'
)
if [ -z "$SIDS" ]; then
  echo "rollover: no bound session in $CFG; skip"
  exit 0
fi

n=0
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  file="$DIR/$sid.json"
  tmp="$file.tmp.$$"
  if jq -n \
      --arg sid "$sid" \
      --argjson ts "$TS" \
      --arg reason "$REASON" \
      --arg run "$RUN" \
      '{sid:$sid,ts:$ts,reason:$reason,run:$run}' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$file" 2>/dev/null; then
    n=$((n + 1))
    echo "rollover request written: $sid (reason=$REASON, dir=$DIR)"
  else
    rm -f "$tmp" 2>/dev/null || true
    echo "::warning::rollover request write failed: $sid (dir=$DIR)"
  fi
done <<< "$SIDS"

echo "rollover: $n request(s) queued under $DIR"
