#!/usr/bin/env bash
# R2630: send one Telegram notice with retries and a real API response log.
#
# The old workflow ran curl once, sent stdout to /dev/null, and printed only a
# warning on failure. A transient Telegram 5xx/429/network error therefore lost
# the round-end notice silently, and a successful send left no evidence at all.
#
# Usage: tg-notify.sh <tag>   (message text on stdin)
#   tag  short label used in logs, e.g. round-end or loop-stop
# Env:
#   TG_BOT_TOKEN, TG_PUSH_CHAT  primary Bot credentials; missing means "skipped"
#   TG_NOTIFY_CLASS             retained for logs/back-compat ("quota" marks a
#                               provider-429 card). R2732 routes **all** global
#                               notices through the per-Bot switches.
# Exit:
#   0 = sent, or intentionally skipped (no credentials / empty text / all routes
#       disabled by their own switches)
#   1 = all attempted routes failed
#
# R2728/R2729/R2732: the bridge menu writes one **per-Bot** switch to
#   ${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}/card-ops.json
# The same file is read here. "📣 全局通知＋卡片自愈" controls this Bot only:
# ON  = this Bot self-heals its pin card and may send global notices
#       (CI round-end/relay, loop-stop, quota 429, Telegram rate-limit);
# OFF = no self-heal for this Bot and it is never chosen as a sender.
# Other bots keep their own setting. A missing/corrupt file means ON.
set -uo pipefail

tag="${1:-notice}"
text=$(cat)
notify_class="${TG_NOTIFY_CLASS:-}"
CFG="${OPENCODE_CONFIG_DIR:-${HOME:-/root}/.config/opencode}"
OPS="$CFG/card-ops.json"
REG="$CFG/tg-bots.json"
LEDGER="${TG_NOTIFY_PEER_LEDGER:-/tmp/opencode/tg-peer-inbound.json}"
MAX_ATTEMPTS="${TG_NOTIFY_MAX_ATTEMPTS:-3}"
PREFERRED_ATTEMPTS="${TG_NOTIFY_PREFERRED_ATTEMPTS:-2}"

if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_PUSH_CHAT:-}" ]; then
  echo "::warning::TG_BOT_TOKEN/TG_PUSH_CHAT missing; ${tag} notice skipped"
  exit 0
fi
if [ -z "$text" ]; then
  echo "::warning::${tag} notice text is empty; skipped"
  exit 0
fi

# R2729: per-Bot switch. A malformed/missing file means ON (same default as the
# bridge): a bad file must not silently disable the operator's 429 visibility.
# Precedence: bots[<id>].enabled -> legacy global enabled -> ON.
ops_bot_on() {
  local bot="$1" v
  [ -s "$OPS" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    v=$(jq -r --arg b "$bot" '
      if (.bots[$b].enabled? | type) == "boolean" then (.bots[$b].enabled | tostring)
      elif (.enabled? | type) == "boolean" then (.enabled | tostring)
      else "true" end' "$OPS" 2>/dev/null || echo true)
    [ "$v" = "false" ] && return 1
    return 0
  fi
  # jq-less fallback: per-Bot JSON cannot be parsed safely with grep, and a
  # coarse "any enabled:false" test would let one Bot's OFF suppress every
  # route. Treat such a file as ON; only the legacy single-switch shape is
  # read coarsely.
  if grep -qE '"bots"[[:space:]]*:' "$OPS" 2>/dev/null; then
    return 0
  fi
  if grep -qE '"enabled"[[:space:]]*:[[:space:]]*false' "$OPS" 2>/dev/null; then
    return 1
  fi
  return 0
}

env_field() {
  # $1=env file, $2=field. Never logs the value.
  sed -n "s/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}${2}=//p" "$1" 2>/dev/null \
    | head -1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']$//"
}

load_candidate() {
  local bot="$1" envf="" token="" chat=""
  TOKEN=""
  CHAT=""
  LABEL="$bot"
  if [ "$bot" = "primary" ]; then
    TOKEN="${TG_BOT_TOKEN:-}"
    CHAT="${TG_PUSH_CHAT:-}"
  else
    if command -v jq >/dev/null 2>&1 && [ -s "$REG" ]; then
      envf=$(jq -r --arg id "$bot" '.bots[]? | select(.id == $id) | .envFile // empty' "$REG" 2>/dev/null | head -1)
    fi
    [ -n "$envf" ] || envf="$CFG/tg-bot${bot}.env"
    case "$envf" in "~/"*) envf="${HOME:-/root}/${envf#\~/}" ;; esac
    [ -f "$envf" ] || return 1
    token=$(env_field "$envf" TG_BOT_TOKEN)
    chat=$(env_field "$envf" TG_PUSH_CHAT)
    [ -n "$token" ] || return 1
    [ -n "$chat" ] || chat="${TG_PUSH_CHAT:-}"
    [ -n "$chat" ] || return 1
    TOKEN="$token"
    CHAT="$chat"
  fi
  [ -n "$TOKEN" ] && [ -n "$CHAT" ]
}

# Send with retries through one token. Returns 0 only on Telegram ok=true.
send_via() {
  local token="$1" chat="$2" max="$3" label="$4"
  local url="https://api.telegram.org/bot${token}/sendMessage"
  local attempt=1
  while [ "$attempt" -le "$max" ]; do
    local errf resp curl_rc code body err desc ra
    errf=$(mktemp)
    resp=$(curl -sS -m 20 -w $'\n%{http_code}' -X POST "$url" \
      --data-urlencode "chat_id=${chat}" \
      --data-urlencode "text=${text}" 2>"$errf")
    curl_rc=$?
    code=$(printf '%s\n' "$resp" | tail -1)
    body=$(printf '%s\n' "$resp" | sed '$d')
    err=$(tr '\n' ' ' < "$errf" 2>/dev/null | cut -c1-200)
    # Redact both the exact token and any bot-token-shaped fragment.
    err="${err//${token}/***}"
    err=$(printf '%s' "$err" | sed -E 's/[0-9]{8,10}:[A-Za-z0-9_-]{30,}/<telegram-token>/g')
    rm -f "$errf"

    if [ "$curl_rc" -eq 0 ] && [ "$code" = "200" ] \
       && printf '%s' "$body" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
      echo "telegram ${tag} sent (attempt=${attempt}/${max}, http=200, chars=${#text}, via=${label})"
      return 0
    fi

    desc=$(printf '%s' "$body" | sed -nE 's/.*"description":"([^"]*)".*/\1/p' | head -1)
    echo "::warning::telegram ${tag} via ${label} attempt ${attempt}/${max} failed (curl=${curl_rc}, http=${code:-?}): ${desc:-${err:-no response}}"

    # Telegram returns parameters.retry_after on 429. Cap the wait so the job
    # cannot stall for minutes; otherwise back off 2s, 4s.
    ra=$(printf '%s' "$body" | sed -nE 's/.*"retry_after":([0-9]+).*/\1/p' | head -1)
    if [ "${TG_NOTIFY_NO_SLEEP:-0}" = "1" ]; then
      :
    elif [ -n "$ra" ] && [ "$ra" -gt 0 ] 2>/dev/null; then
      [ "$ra" -gt 10 ] && ra=10
      sleep "$ra"
    elif [ "$attempt" -lt "$max" ]; then
      sleep $((attempt * 2))
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# Candidate order: only quota 429 notices are rerouted. Each candidate is then
# checked against its own per-Bot switch in the send loop, so turning one Bot
# off does not affect the others. Everything else keeps the primary Bot.
# Bot ids end up in a file path (`tg-bot<id>.env`) and a jq argument, so reject
# anything outside the registry's id alphabet before using it as a route.
valid_bot() {
  local bot="$1"
  case "$bot" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#bot}" -le 32 ]
}
CANDIDATES=()
add_candidate() {
  local bot="$1" c
  valid_bot "$bot" || return 0
  for c in "${CANDIDATES[@]}"; do
    [ "$c" = "$bot" ] && return 0
  done
  CANDIDATES+=("$bot")
}
# R2732: every global notice follows the same per-Bot switch, not only quota.
# Order: most recently used Bot -> configured notifyBot -> primary -> every
# other registered Bot. The registry tail matters when the last-used Bot is
# OFF: an enabled bot5 must still be reachable even if bot6/primary are OFF.
latest=""
if command -v jq >/dev/null 2>&1 && [ -s "$LEDGER" ]; then
  latest=$(jq -r 'to_entries | map(select((.value.in // 0) > 0)) | sort_by(.value.in) | last | .key // empty' "$LEDGER" 2>/dev/null || true)
fi
add_candidate "$latest"
configured="bot6"
if command -v jq >/dev/null 2>&1 && [ -s "$OPS" ]; then
  configured=$(jq -r '.notifyBot // "bot6"' "$OPS" 2>/dev/null | head -1 || true)
fi
# A hand-edited/invalid notifyBot falls back to the documented default rather
# than silently degrading to primary.
valid_bot "$configured" || configured="bot6"
add_candidate "$configured"
add_candidate "primary"
if [ -s "$REG" ]; then
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r id; do add_candidate "$id"; done \
      < <(jq -r '.bots[]?.id // empty' "$REG" 2>/dev/null || true)
  else
    # jq-less fallback for candidate discovery only; switch parsing is still
    # conservative (per-Bot files are treated as ON when they cannot be read).
    while IFS= read -r id; do add_candidate "$id"; done \
      < <(sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)".*/\1/p' "$REG" 2>/dev/null || true)
  fi
fi

echo "telegram ${tag} routing (class=${notify_class:-global}): ${CANDIDATES[*]}"
used_tokens=""
attempted=0
disabled=0
for bot in "${CANDIDATES[@]}"; do
  if ! ops_bot_on "$bot"; then
    echo "::notice::telegram ${tag} route ${bot} disabled by its own card-ops switch; skipping"
    disabled=$((disabled + 1))
    continue
  fi
  attempted=$((attempted + 1))
  if ! load_candidate "$bot"; then
    echo "::warning::telegram ${tag} route ${bot} unavailable (missing token/chat); trying next"
    continue
  fi
  # A restored registry may point two ids at the same Bot; do not send twice.
  key="${TOKEN}|${CHAT}"
  case " ${used_tokens} " in
    *" ${key} "*) continue ;;
  esac
  used_tokens="${used_tokens} ${key}"
  if [ "$bot" = "primary" ]; then
    if send_via "$TOKEN" "$CHAT" "$MAX_ATTEMPTS" "$bot"; then
      exit 0
    fi
  else
    if send_via "$TOKEN" "$CHAT" "$PREFERRED_ATTEMPTS" "$bot"; then
      exit 0
    fi
    echo "::warning::telegram ${tag} preferred route ${bot} failed; falling back"
  fi
done

if [ "$attempted" -eq 0 ] && [ "$disabled" -gt 0 ]; then
  echo "telegram ${tag} skipped (class=${notify_class:-global}; all notice routes disabled by their own card-ops switch)"
  exit 0
fi

echo "::warning::could not send ${tag} notice to telegram after all routes"
exit 1
