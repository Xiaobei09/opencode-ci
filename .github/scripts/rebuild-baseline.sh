#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
set +e

# R2651: this script deletes most of the working tree and force-pushes `main`.
# It runs under `if: always()`, so it is reached even when the sessions clone
# failed. Without the guards below, a failed `cd` would make every `rm -rf`
# and `git push --force` operate on the *CI* checkout instead - destroying or
# force-pushing the wrong repository. Refuse to touch anything unless the
# target is provably the sessions repo.
die() { echo "::error::rebuild-baseline: $*" >&2; exit 1; }
[ -n "${SESSIONS_DIR:-}" ] || die "SESSIONS_DIR is empty; refusing destructive reset"
case "$SESSIONS_DIR" in /*) ;; *) die "SESSIONS_DIR is not absolute: $SESSIONS_DIR" ;; esac
[ -d "$SESSIONS_DIR/.git" ] || die "no git checkout at $SESSIONS_DIR (clone failed?); refusing destructive reset"
cd "$SESSIONS_DIR" || die "cannot cd to $SESSIONS_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$SESSIONS_DIR is not a git work tree"
origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  *opencode-sessions*) ;;
  *) die "origin is '$origin_url', not the sessions repo; refusing destructive reset" ;;
esac
git checkout --detach HEAD >/dev/null 2>&1 || die "cannot detach HEAD"
git branch -D baseline-reset >/dev/null 2>&1 || true
git checkout --orphan baseline-reset >/dev/null 2>&1 || die "cannot create orphan baseline branch"
[ "$(git symbolic-ref --short HEAD 2>/dev/null || true)" = "baseline-reset" ] || die "orphan checkout did not stick"
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
pushed=0
for attempt in 1 2 3 4 5; do
  if git push --force origin main; then
    echo "baseline pushed (single commit)"
    pushed=1
    break
  fi
  echo "::warning::baseline push attempt $attempt failed; retrying"
  sleep 4
done
# R2651: a failed push means the repository still holds the old baseline.
# Reporting success would leave the operator believing the reset took effect.
[ "$pushed" = "1" ] || die "git push --force origin main failed after 5 attempts"
git tag -f baseline >/dev/null 2>&1 || echo "::warning::could not move the local baseline tag"
tag_pushed=0
for attempt in 1 2 3 4 5; do
  if git push --force origin refs/tags/baseline; then
    echo "baseline tag pushed"
    tag_pushed=1
    break
  fi
  echo "::warning::baseline tag push attempt $attempt failed; retrying"
  sleep 4
done
[ "$tag_pushed" = "1" ] || die "git push --force origin refs/tags/baseline failed after 5 attempts"
exit 0
