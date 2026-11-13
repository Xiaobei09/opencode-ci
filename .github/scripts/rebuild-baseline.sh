#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
set +e
cd "$SESSIONS_DIR"
git checkout --detach HEAD >/dev/null 2>&1 || true
git branch -D baseline-reset >/dev/null 2>&1 || true
git checkout --orphan baseline-reset >/dev/null 2>&1
rm -rf opencode/data
mkdir -p opencode/data
touch opencode/data/.gitkeep
rm -rf sessions state tasks workspace-snapshots loop-state.md
rm -f opencode/config/tg-chats.json opencode/config/tg-chats-bot*.json \
      opencode/config/loop-ctl.json opencode/config/loop-marker.json \
      opencode/config/tg-bots.json opencode/config/loop-guard.json \
      opencode/config/loop-sessions.json opencode/config/model-windows.json \
      opencode/config/abort-events.json opencode/config/inject-card-*.json \
      opencode/config/botname-*.json opencode/config/egress-blacklist.json \
      opencode/config/egress-usage.json \
      opencode/config/exit-proxy.json
{
  echo '# Runtime state lives in the env release, not in git.'
  echo 'opencode/data/*'
  echo '!opencode/data/.gitkeep'
  echo 'sessions/'
  echo 'state/'
  echo 'tasks/'
  echo 'workspace-snapshots/'
  echo 'loop-state.md'
  echo 'opencode/config/tg-chats*.json'
  echo 'opencode/config/tg-bots.json'
  echo 'opencode/config/loop-ctl.json'
  echo 'opencode/config/loop-marker.json'
  echo 'opencode/config/loop-guard.json'
  echo 'opencode/config/loop-sessions.json'
  echo 'opencode/config/model-windows.json'
  echo 'opencode/config/abort-events.json'
  echo 'opencode/config/inject-card-*.json'
  echo 'opencode/config/halt-release.json*'
  echo 'opencode/config/botname-*.json*'
  echo 'opencode/config/egress-blacklist.json*'
  echo 'opencode/config/egress-usage.json*'
  echo 'opencode/config/exit-proxy.json*'
  echo 'opencode/config/service.json*'
  echo 'opencode/config/tg-bot*.env'
  echo 'opencode/config/tg.env'
  echo 'opencode/home.tar.gz*'
} > .gitignore
git add -A
git -c user.name="opencode-ci" -c user.email="opencode-ci@users.noreply.github.com" \
  commit -q -m "baseline: clean initial state ($(date -u +%Y-%m-%dT%H:%M:%SZ))" \
  || echo "::warning::nothing to commit"
git branch -M baseline-reset main
for attempt in 1 2 3 4 5; do
  if git push --force origin main; then
    echo "baseline pushed (single commit)"
    break
  fi
  echo "::warning::baseline push attempt $attempt failed; retrying"
  sleep 4
done
git tag -f baseline >/dev/null 2>&1
for attempt in 1 2 3 4 5; do
  if git push --force origin refs/tags/baseline; then
    echo "baseline tag pushed"
    break
  fi
  echo "::warning::baseline tag push attempt $attempt failed; retrying"
  sleep 4
done
