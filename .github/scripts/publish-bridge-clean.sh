#!/usr/bin/env bash
# R2670 (operator: "增加一个ci,用来构建新的干净副本"): build a NEW clean copy of
# the public bridge repository from the private sessions source.
#
# "Clean copy" = one root commit containing the whole sanitized tree, force-pushed
# to the public repo. The public bridge repo is a distribution artifact; its
# history must never accumulate old fixtures, runtime state or leaked ids. This is
# the same shape as the 2026-11-16 manual orphan rebuild and the sessions
# `baseline-clean` rule, but automated and verified every time.
#
# The sanitized source sync itself stays in the sessions repo
# (opencode/config/scripts/publish-bridge.sh); this script only adds the clean-copy
# build, the install smoke test and the publish/verify steps.
#
# Usage: publish-bridge-clean.sh
#
# Env:
#   SESSIONS_DIR   private sessions checkout (required)
#   BRIDGE_DIR     public bridge checkout (required; its origin must match BRIDGE_REPO)
#   BRIDGE_REPO    owner/name of the public repo (default Xiaobei09/opencode-bridge-plugin)
#   DRY_RUN        true = build + verify only, never commit/push (default false)
#   FORCE          true = rebuild even when the sanitized tree is unchanged (default false)
#   TAG            tag to publish; "-" skips tagging (default v<date>-<round>)
#   ALLOW_ANY_ORIGIN  true = skip the origin-match guard (local tests only)
#   SKIP_REMOTE_VERIFY true = skip gh/curl checks after push (local tests only)
set -euo pipefail

BRIDGE_REPO="${BRIDGE_REPO:-Xiaobei09/opencode-bridge-plugin}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
TAG="${TAG:-}"
ALLOW_ANY_ORIGIN="${ALLOW_ANY_ORIGIN:-false}"
SKIP_REMOTE_VERIFY="${SKIP_REMOTE_VERIFY:-false}"

log() { printf '%s\n' "$*"; }
die() { printf '::error::publish-bridge-clean: %s\n' "$*" >&2; exit 1; }
is_true() { [ "$1" = "true" ] || [ "$1" = "1" ]; }

summary() { # $1=version $2=changed $3=pushed $4=commit $5=tag
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "### publish-bridge clean copy"
    echo
    echo "| item | value |"
    echo "|---|---|"
    echo "| repo | \`$BRIDGE_REPO\` |"
    echo "| version | \`$1\` |"
    echo "| changed files | $2 |"
    echo "| pushed | $3 |"
    echo "| commit | \`${4:-none}\` |"
    echo "| tag | \`${5:-none}\` |"
    echo "| dry run | $DRY_RUN |"
  } >>"$GITHUB_STEP_SUMMARY"
}

# ---------------------------------------------------------------- guards
[ -n "${SESSIONS_DIR:-}" ] || die "SESSIONS_DIR is empty"
[ -n "${BRIDGE_DIR:-}" ] || die "BRIDGE_DIR is empty"
case "$SESSIONS_DIR" in /*) ;; *) die "SESSIONS_DIR is not absolute: $SESSIONS_DIR" ;; esac
case "$BRIDGE_DIR" in /*) ;; *) die "BRIDGE_DIR is not absolute: $BRIDGE_DIR" ;; esac
[ "$SESSIONS_DIR" != "$BRIDGE_DIR" ] || die "SESSIONS_DIR and BRIDGE_DIR are the same directory"
printf '%s' "$BRIDGE_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
  || die "BRIDGE_REPO is not owner/name: $BRIDGE_REPO"

[ -d "$SESSIONS_DIR/.git" ] || die "no git checkout at SESSIONS_DIR=$SESSIONS_DIR"
[ -d "$BRIDGE_DIR/.git" ] || die "no git checkout at BRIDGE_DIR=$BRIDGE_DIR"
[ -d "$BRIDGE_DIR/src" ] || die "BRIDGE_DIR does not look like the bridge repo (missing src/)"
git -C "$SESSIONS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "SESSIONS_DIR is not a git work tree"
git -C "$BRIDGE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "BRIDGE_DIR is not a git work tree"

sessions_origin=$(git -C "$SESSIONS_DIR" remote get-url origin 2>/dev/null || true)
case "$sessions_origin" in
  *opencode-sessions*) ;;
  *) die "SESSIONS_DIR origin is '$sessions_origin', not the sessions repo; refusing to publish" ;;
esac

bridge_origin=$(git -C "$BRIDGE_DIR" remote get-url origin 2>/dev/null || true)
if ! is_true "$ALLOW_ANY_ORIGIN"; then
  case "$bridge_origin" in
    *"$BRIDGE_REPO"*) ;;
    *) die "BRIDGE_DIR origin is '$bridge_origin', not $BRIDGE_REPO; refusing to force-push" ;;
  esac
fi

# Never publish a dirty sessions checkout: the copy would not match any commit.
if [ -n "$(git -C "$SESSIONS_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  die "SESSIONS_DIR has uncommitted changes; commit them before building the clean copy"
fi

log "clean-copy build: repo=$BRIDGE_REPO dry_run=$DRY_RUN force=$FORCE"
log "sessions HEAD: $(git -C "$SESSIONS_DIR" rev-parse --short HEAD)"
log "bridge HEAD:   $(git -C "$BRIDGE_DIR" rev-parse --short HEAD 2>/dev/null || echo '(empty)')"

# ---------------------------------------------------- sanitized source sync
# publish-bridge.sh asserts token shapes, real ids and /home/runner are absent.
log "syncing sanitized source (publish-bridge.sh)"
bash "$SESSIONS_DIR/opencode/config/scripts/publish-bridge.sh" "$BRIDGE_DIR"

# ------------------------------------------------------- extra leak checks
# Counts only: never echo matching content into the public CI log.
leak_files() { # $1=label $2=ERE
  local files
  files=$(grep -rEl --exclude-dir=.git -- "$2" "$BRIDGE_DIR" 2>/dev/null || true)
  if [ -n "$files" ]; then
    printf '::error::%s leaked in:\n%s\n' "$1" "$files" >&2
    return 1
  fi
  return 0
}

leak_files "full session id" 'ses_[0-9a-fA-F]{16,}' || die "full session id found"
leak_files "full message id" 'msg_[0-9a-fA-F]{16,}' || die "full message id found"
leak_files "telegram bot token" '"[0-9]{8,12}:[A-Za-z0-9_-]{30,}"' || die "telegram token shape found"
leak_files "github token" 'ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}' || die "github token shape found"
leak_files "provider key" 'sk-[A-Za-z0-9]{20,}' || die "provider key shape found"
leak_files "aws key" 'AKIA[0-9A-Z]{16}' || die "aws key shape found"
leak_files "slack token" 'xox[baprs]-[A-Za-z0-9-]{10,}' || die "slack token shape found"
leak_files "bearer token" 'Bearer [A-Za-z0-9._-]{20,}' || die "bearer value found"
leak_files "private key" '-----BEGIN [A-Z ]*PRIVATE KEY-----' || die "private key block found"
leak_files "host path" '/home/runner' || die "/home/runner path found"

# ------------------------------------------------------- expected contents
for f in README.md install.sh add-bots.sh \
         src/_v2compat.ts src/auto-continue.ts src/auto-continue-v2.ts \
         src/tg-bridge.ts src/tg-bridge-v2.ts src/compaction-card.ts src/version.ts; do
  [ -s "$BRIDGE_DIR/$f" ] || die "clean copy is missing $f"
done

VERSION=$(sed -n 's/^export const BRIDGE_VERSION = "\([^"]*\)"/\1/p' "$BRIDGE_DIR/src/version.ts" | head -1)
[ -n "$VERSION" ] || die "cannot read BRIDGE_VERSION from src/version.ts"
ROUND=${VERSION%%-*}
case "$ROUND" in r[0-9]*) ;; *) die "unexpected VERSION '$VERSION'" ;; esac
log "bridge version: $VERSION ($ROUND)"

# --------------------------------------------------- install smoke test
# The whole point of the public repo is "clone and install"; prove it before push.
TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT
( cd "$BRIDGE_DIR" && HOME="$TMPHOME" bash ./install.sh >/dev/null )
for f in "$TMPHOME/.opencode/v2lib/tg-bridge.ts" \
         "$TMPHOME/.opencode/v2lib/version.ts" \
         "$TMPHOME/.config/opencode/v2lib/tg-bridge.ts" \
         "$TMPHOME/.config/opencode/v2lib/version.ts" \
         "$TMPHOME/.config/opencode/plugins/tg-bridge-v2.ts"; do
  [ -s "$f" ] || die "install smoke test did not produce $f"
done
if grep -rEl 'REDACTED_ROOT' "$TMPHOME" >/dev/null 2>&1; then
  die "install smoke test left REDACTED_ROOT behind"
fi
installed=$(find "$TMPHOME/.opencode/v2lib" -maxdepth 1 -name '*.ts' | wc -l | tr -d ' ')
log "install smoke test: ok ($installed modules; both lib dirs + plugin entry)"

# ----------------------------------------------------------- change check
changed=$(git -C "$BRIDGE_DIR" status --porcelain | wc -l | tr -d ' ')
dirty=$([ "$changed" -gt 0 ] && echo true || echo false)
log "sanitized tree changes: $changed file(s)"

if is_true "$DRY_RUN"; then
  log "dry run: built and verified a clean copy; nothing pushed"
  log "dry-run summary: version=$VERSION changed=$changed"
  summary "$VERSION" "$changed" false none none
  exit 0
fi

if [ "$changed" -eq 0 ] && ! is_true "$FORCE"; then
  log "no source changes; keeping the existing clean copy (use force=true to rebuild)"
  log "clean-copy summary: version=$VERSION changed=0 pushed=false"
  summary "$VERSION" 0 false none none
  exit 0
fi

# ------------------------------------------------------- orphan clean copy
cd "$BRIDGE_DIR"
git checkout --orphan clean-copy >/dev/null 2>&1 || die "cannot create orphan branch"
[ "$(git symbolic-ref --short HEAD 2>/dev/null || true)" = "clean-copy" ] \
  || die "orphan checkout did not stick"
git rm -r --cached . >/dev/null 2>&1 || true
git add -A
git -c user.name="opencode-ci" -c user.email="opencode-ci@users.noreply.github.com" \
  commit -q -m "clean copy: ${VERSION} ($(date -u +%Y-%m-%dT%H:%M:%SZ))" \
  || die "clean-copy commit failed"
git branch -M clean-copy main
commits=$(git rev-list --count HEAD)
[ "$commits" = "1" ] || die "clean copy is not a single root commit (count=$commits)"
new_sha=$(git rev-parse HEAD)
log "clean-copy commit: $new_sha (1 root commit)"

# --------------------------------------------------------------- publish
pushed=0
for attempt in 1 2 3 4 5; do
  if git push --force origin main; then
    pushed=1
    break
  fi
  echo "::warning::clean-copy push attempt $attempt failed; retrying"
  sleep 4
done
[ "$pushed" = "1" ] || die "git push --force origin main failed after 5 attempts"
log "pushed main -> $new_sha"

tag_pushed="skip"
if [ "$TAG" != "-" ]; then
  [ -n "$TAG" ] || TAG="v$(date -u +%Y%m%d)-${ROUND}"
  git tag -f "$TAG" >/dev/null 2>&1 || die "cannot create tag $TAG"
  for attempt in 1 2 3 4 5; do
    if git push --force origin "refs/tags/$TAG"; then
      tag_pushed=$TAG
      break
    fi
    echo "::warning::tag push attempt $attempt failed; retrying"
    sleep 4
  done
  [ "$tag_pushed" != "skip" ] || die "git push --force origin refs/tags/$TAG failed after 5 attempts"
  log "pushed tag -> $TAG"
fi

# ------------------------------------------------------- remote verify
if is_true "$SKIP_REMOTE_VERIFY"; then
  log "remote verify skipped (local test)"
else
  command -v gh >/dev/null 2>&1 || die "gh is required for remote verification"
  remote_sha=$(gh api "repos/$BRIDGE_REPO/git/ref/heads/main" --jq .object.sha 2>/dev/null || true)
  [ "$remote_sha" = "$new_sha" ] || die "remote main is '$remote_sha', expected '$new_sha'"
  remote_commits=$(gh api "repos/$BRIDGE_REPO/commits?per_page=2" --jq 'length' 2>/dev/null || true)
  [ "$remote_commits" = "1" ] || die "remote history is not a single commit (count=$remote_commits)"
  private=$(gh api "repos/$BRIDGE_REPO" --jq .private 2>/dev/null || true)
  [ "$private" = "false" ] || die "remote repo is not public (private=$private)"
  fetched=$(mktemp)
  trap 'rm -rf "$TMPHOME" "$fetched"' EXIT
  curl -fsS "https://raw.githubusercontent.com/$BRIDGE_REPO/main/src/version.ts" >"$fetched" \
    || die "anonymous raw fetch failed"
  grep -q "export const BRIDGE_VERSION = \"$VERSION\"" "$fetched" || die "raw fetch does not contain BRIDGE_VERSION=$VERSION"
  if grep -qE 'ses_[0-9a-fA-F]{16,}|msg_[0-9a-fA-F]{16,}|ghp_[A-Za-z0-9]{30,}|github_pat_|/home/runner' "$fetched"; then
    die "raw fetch failed the leak scan"
  fi
  log "remote verify: main=$remote_sha commits=1 private=false raw=200 clean=yes"
fi

log "clean-copy summary: version=$VERSION changed=$changed pushed=true commit=$new_sha tag=$tag_pushed"
summary "$VERSION" "$changed" true "$new_sha" "$tag_pushed"
