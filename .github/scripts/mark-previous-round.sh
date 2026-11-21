#!/usr/bin/env bash
# R2861 (operator: "ci结束时发ci结束提示，重启后改为
# 🌐 relay.....
# 🔄 CI 上一轮结束 ..."):
#
# The round-end card is sent by the finishing run as "🔄 CI 本轮结束 · 接力中".
# Once the relayed successor actually starts, that title is stale: the round is
# no longer "relaying", it is the previous round, and the successor is the one
# now running. This step edits the previous card in place (no new Telegram
# notification) to:
#
#   🌐 <selected egress>
#   🔄 CI 上一轮结束 · <reason>
#   <the rest of the original card>
#
# R2895 (operator: "CI 开始编辑为 🌐 …出口… / 🔄 CI 上一轮结束 …"): the egress
# line the finishing run appends to the card is moved to the top, so the
# successor card starts with the exit that is actually in use. The old
# "🌐 relay · run X → Y" line is only a fallback for cards without an egress
# tail (older workflow / failed selection); its duplicate is removed from the
# body either way.
#
# The finishing run persists the card target + full text in the repository
# variable CI_LAST_ROUND_CARD (JSON: bot/msg/run/text). A successor reads it,
# edits the message with the same Bot, then writes the new text back so a
# second relay of the same card is a no-op.
#
# This is cosmetic: any failure is a warning and exit 0. It must never stop the
# loop or fail an otherwise healthy round.
set -uo pipefail

repo="${GITHUB_REPOSITORY:-}"
run_id="${GITHUB_RUN_ID:-?}"
TG_NOTIFY_BIN="${TG_NOTIFY_BIN:-${GITHUB_WORKSPACE:-.}/.github/scripts/tg-notify.sh}"

if [ -z "$repo" ]; then
  echo "::warning::GITHUB_REPOSITORY missing; previous round card not marked"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "::warning::jq missing; previous round card not marked"
  exit 0
fi

card=$(gh variable get CI_LAST_ROUND_CARD --repo "$repo" 2>/dev/null || true)
if [ -z "$card" ]; then
  echo "no previous round card; nothing to mark"
  exit 0
fi

bot=$(printf '%s' "$card" | jq -r '.bot // empty' 2>/dev/null || true)
msg=$(printf '%s' "$card" | jq -r '.msg // empty' 2>/dev/null || true)
prev_run=$(printf '%s' "$card" | jq -r '.run // empty' 2>/dev/null || true)
b64=$(printf '%s' "$card" | jq -r '.text // empty' 2>/dev/null || true)
case "$bot" in ''|*[!A-Za-z0-9_-]*) echo "previous round card has no usable Bot; skipped"; exit 0 ;; esac
case "$msg" in ''|*[!0-9]*) echo "previous round card has no usable message id; skipped"; exit 0 ;; esac
[ -n "$b64" ] || { echo "previous round card has no text; skipped"; exit 0; }

body=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || {
  echo "::warning::previous round card text is not valid base64; skipped"
  exit 0
}
# R2895: the title is the stable idempotence marker; the first line is now an
# egress line, so the old "🌐 relay …" first-line check would re-edit it.
if printf '%s\n' "$body" | grep -q '^🔄 CI 上一轮结束'; then
  echo "previous round card is already marked as relayed; skipped"
  exit 0
fi

# Move the original 原因： line into the title so it is not repeated.
reason=$(printf '%s\n' "$body" | sed -n 's/^原因：//p' | head -1)
rest=$(printf '%s\n' "$body" | grep -v '^原因：' || true)
# Drop the old "🔄 CI 本轮结束 · 接力中" first line; the new title replaces it.
rest=$(printf '%s\n' "$rest" | tail -n +2)
# R2895: the egress tail is appended last by the finishing run. Promote it to
# the top and remove the duplicate from the rest; keep the relay line only as a
# fallback when the card has no egress tail.
egress=$(printf '%s\n' "$body" | grep '^🌐 ' | tail -1 || true)
if [ -n "$egress" ]; then
  rest=$(printf '%s\n' "$rest" | grep -vxF -- "$egress" || true)
  headline="$egress"
else
  headline="🌐 relay · run ${prev_run:-?} → $run_id"
fi
title="🔄 CI 上一轮结束${reason:+ · $reason}"
new=$(printf '%s\n%s\n%s' "$headline" "$title" "$rest")

out=$(printf '%s' "$new" \
  | TG_NOTIFY_MODE=edit TG_NOTIFY_EDIT_BOT="$bot" TG_NOTIFY_EDIT_MSG="$msg" \
    TG_NOTIFY_CLASS="${TG_NOTIFY_CLASS:-}" \
    bash "$TG_NOTIFY_BIN" round-end 2>&1)
rc=$?
printf '%s\n' "$out"

if [ "$rc" = 0 ]; then
  new_b64=$(printf '%s' "$new" | base64 | tr -d '\n')
  updated=$(printf '%s' "$card" | jq -c --arg text "$new_b64" --arg run "$run_id" \
    '.text = $text | .relayed_by = $run' 2>/dev/null || true)
  if [ -n "$updated" ]; then
    gh variable set CI_LAST_ROUND_CARD --body "$updated" --repo "$repo" >/dev/null 2>&1 \
      || echo "::warning::could not persist the marked previous round card"
  fi
  exit 0
fi

if [ "$rc" = 2 ]; then
  # Message deleted or its Bot switched off: clearing avoids retrying forever.
  echo "::warning::previous round card is no longer editable; clearing it"
  gh variable delete CI_LAST_ROUND_CARD --repo "$repo" >/dev/null 2>&1 || true
  exit 0
fi

echo "::warning::could not mark previous round card (rc=$rc); leaving it for the next run"
exit 0
