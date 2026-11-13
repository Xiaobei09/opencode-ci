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
#   TG_BOT_TOKEN, TG_PUSH_CHAT  required; missing means "skipped" (exit 0)
# Exit:
#   0 = sent, or intentionally skipped (no credentials / empty text)
#   1 = all attempts failed
set -uo pipefail

tag="${1:-notice}"
text=$(cat)

if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_PUSH_CHAT:-}" ]; then
  echo "::warning::TG_BOT_TOKEN/TG_PUSH_CHAT missing; ${tag} notice skipped"
  exit 0
fi
if [ -z "$text" ]; then
  echo "::warning::${tag} notice text is empty; skipped"
  exit 0
fi

url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
max=3
attempt=1
while [ "$attempt" -le "$max" ]; do
  errf=$(mktemp)
  resp=$(curl -sS -m 20 -w $'\n%{http_code}' -X POST "$url" \
    --data-urlencode "chat_id=${TG_PUSH_CHAT}" \
    --data-urlencode "text=${text}" 2>"$errf")
  curl_rc=$?
  code=$(printf '%s\n' "$resp" | tail -1)
  body=$(printf '%s\n' "$resp" | sed '$d')
  err=$(tr '\n' ' ' < "$errf" 2>/dev/null | cut -c1-200)
  err="${err//${TG_BOT_TOKEN}/***}"
  rm -f "$errf"

  if [ "$curl_rc" -eq 0 ] && [ "$code" = "200" ] \
     && printf '%s' "$body" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "telegram ${tag} sent (attempt=${attempt}/${max}, http=200, chars=${#text})"
    exit 0
  fi

  desc=$(printf '%s' "$body" | sed -nE 's/.*"description":"([^"]*)".*/\1/p' | head -1)
  echo "::warning::telegram ${tag} attempt ${attempt}/${max} failed (curl=${curl_rc}, http=${code:-?}): ${desc:-${err:-no response}}"

  # Telegram returns parameters.retry_after on 429. Cap the wait so the job
  # cannot stall for minutes; otherwise back off 2s, 4s.
  ra=$(printf '%s' "$body" | sed -nE 's/.*"retry_after":([0-9]+).*/\1/p' | head -1)
  if [ -n "$ra" ] && [ "$ra" -gt 0 ] 2>/dev/null; then
    [ "$ra" -gt 10 ] && ra=10
    sleep "$ra"
  elif [ "$attempt" -lt "$max" ]; then
    sleep $((attempt * 2))
  fi
  attempt=$((attempt + 1))
done

echo "::warning::could not send ${tag} notice to telegram after ${max} attempts"
exit 1
