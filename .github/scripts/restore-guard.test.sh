#!/usr/bin/env bash
# R2773: offline regression for the restore freshness guard and the network
# bounds added after run 44098155757 hung in "Restore workspace ..." for 164s
# with no intermediate log output.
#
# Runs before GitHub CLI is installed in iterate.yml on purpose: every gh call
# is faked, and no network is used.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/restore-env.sh"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/bin" "$TD/home" "$TD/sessions"
mkdir -p "$TD/home/.config/opencode" "$TD/home/.local/share" "$TD/home/.opencode"

cat > "$TD/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  api)
    [ -n "${FAKE_API_DATE:-}" ] || exit 1
    printf '%s\n' "$FAKE_API_DATE"
    exit 0
    ;;
  release)
    dir=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dir) dir="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$dir" ] && [ -n "${FAKE_META_JSON:-}" ] || exit 1
    mkdir -p "$dir"
    printf '%s\n' "$FAKE_META_JSON" > "$dir/meta.json"
    exit 0
    ;;
esac
exit 1
FAKE
chmod +x "$TD/bin/gh"

checks=0
fail=0
ck() {
  local name="$1" cond="$2"
  checks=$((checks + 1))
  if [ "$cond" = 1 ]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    fail=1
  fi
}

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now=$(date +%s)
old_meta=$(printf '{"version":2,"env":{"carried":true,"packed_at":"%s"}}' "$(iso $((now - 172800)))")
recent_meta=$(printf '{"version":2,"env":{"carried":true,"packed_at":"%s"}}' "$(iso $((now - 300)))")
mid_meta=$(printf '{"version":2,"env":{"carried":true,"packed_at":"%s"}}' "$(iso $((now - 7200)))")

# Run the guard from a real source of restore-env.sh with RESTORE_ENV_LIB_ONLY=1.
run_guard() {
  local out="$TD/out"
  ( env PATH="$TD/bin:$PATH" HOME="$TD/home" SESSIONS_DIR="$TD/sessions" \
        SESSIONS_REPO="fake/repo" ENV_TAG="env" RESTORE_ENV_LIB_ONLY=1 \
        ENV_SYNC_MAX_AGE_MIN=1440 GH_META_TIMEOUT=5 \
        "$@" \
        bash -c 'source "$1" >/dev/null 2>&1 || exit 90; rc=0; stale_release_guard || rc=$?; echo "__RC=$rc"' \
        _ "$SCRIPT" ) > "$out" 2>&1
  GUARD_OUT=$(cat "$out")
  GUARD_RC=$(sed -n 's/^__RC=//p' "$out" | tail -1)
  [ -n "$GUARD_RC" ] || GUARD_RC=90
}

run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_COMMIT=abc123 ENV_SYNC_EPOCH=$((now - 120)) \
  FAKE_META_JSON="$old_meta" FAKE_API_DATE=""
ck "fresh env-sync + 2-day-old release => refuse stale fallback" \
  "$([ "$GUARD_RC" = 1 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'Refusing the older release env' && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_COMMIT=abc123 ENV_SYNC_EPOCH=$((now - 120)) \
  ENV_ALLOW_STALE_RELEASE=1 FAKE_META_JSON="$old_meta" FAKE_API_DATE=""
ck "ENV_ALLOW_STALE_RELEASE=1 is a working break-glass" \
  "$([ "$GUARD_RC" = 0 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'ENV_ALLOW_STALE_RELEASE=1' && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_EPOCH=$((now - 120)) \
  FAKE_META_JSON="$recent_meta" FAKE_API_DATE=""
ck "even a 5-minute-old release is refused when env-sync is newer" \
  "$([ "$GUARD_RC" = 1 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'Refusing the older release env' && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=too-old ENV_SYNC_EPOCH=$((now - 120)) \
  FAKE_META_JSON="$old_meta" FAKE_API_DATE=""
ck "stale env-sync branch does not block the release fallback" \
  "$([ "$GUARD_RC" = 0 ] && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_EPOCH=$((now - 172800)) \
  FAKE_META_JSON="$old_meta" FAKE_API_DATE=""
ck "env-sync branch older than the 24h cap does not block fallback" \
  "$([ "$GUARD_RC" = 0 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'branch is stale' && echo 1 || echo 0)"

# Clone failed before env-sync.json was readable: freshness must come from the API.
run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_EPOCH= \
  FAKE_META_JSON="$old_meta" FAKE_API_DATE="$(iso $((now - 120)))"
ck "clone failure uses the branch commit date from the API" \
  "$([ "$GUARD_RC" = 1 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'Refusing the older release env' && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_EPOCH= \
  FAKE_META_JSON="" FAKE_API_DATE=""
ck "unknown release metadata warns instead of pretending to be safe" \
  "$([ "$GUARD_RC" = 0 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'metadata is unavailable' && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=release-newer ENV_SYNC_EPOCH=$((now - 120)) \
  FAKE_META_JSON="$old_meta" FAKE_API_DATE=""
ck "release-newer decision is not second-guessed" \
  "$([ "$GUARD_RC" = 0 ] && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_EPOCH=$((now - 10800)) \
  FAKE_META_JSON="$mid_meta" FAKE_API_DATE=""
ck "release newer than env-sync is allowed even when >1h old" \
  "$([ "$GUARD_RC" = 0 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'not older' && echo 1 || echo 0)"

run_guard ENV_SYNC_FAIL_REASON=clone ENV_SYNC_EPOCH= \
  FAKE_META_JSON="$recent_meta" FAKE_API_DATE=""
ck "unknown branch freshness warns instead of pretending to be safe" \
  "$([ "$GUARD_RC" = 0 ] && printf '%s' "$GUARD_OUT" | grep -Fq 'could not be verified' && echo 1 || echo 0)"

# Static safety checks: every previously unbounded network leg must stay bounded.
ck "restore-workspace streams live task output" \
  "$(grep -Fq 'stream_filter' "$HERE/restore-workspace.sh" && echo 1 || echo 0)"
ck "restore-workspace has a hard ceiling per restore" \
  "$(grep -Fq 'RESTORE_ENV_DEADLINE' "$HERE/restore-workspace.sh" && grep -Fq 'RESTORE_TARGETS_DEADLINE' "$HERE/restore-workspace.sh" && echo 1 || echo 0)"
ck "env-sync clone has a timeout and a retry" \
  "$(grep -Fq 'ENV_SYNC_CLONE_TIMEOUT' "$SCRIPT" && grep -Fq 'ENV_SYNC_CLONE_ATTEMPTS' "$SCRIPT" && echo 1 || echo 0)"
ck "fetch-asset bounds each range request" \
  "$(grep -Fq 'FETCH_ASSET_MAX_TIME' "$HERE/fetch-asset.sh" && grep -Fq 'timeout --signal=TERM --kill-after=5' "$HERE/fetch-asset.sh" && echo 1 || echo 0)"
ck "fetch-asset has an overall deadline" \
  "$(grep -Fq 'FETCH_ASSET_DEADLINE' "$HERE/fetch-asset.sh" && echo 1 || echo 0)"
ck "targets slim fetch has a timeout" \
  "$(grep -Fq 'TGT_SLIM_FETCH_TIMEOUT' "$HERE/restore-targets.sh" && echo 1 || echo 0)"
ck "restore step has a workflow-level timeout" \
  "$(grep -Fq 'timeout-minutes: 15' "$HERE/../workflows/iterate.yml" && echo 1 || echo 0)"

for s in restore-workspace.sh restore-env.sh restore-targets.sh fetch-asset.sh restore-guard.test.sh; do
  ck "bash -n $s" "$(bash -n "$HERE/$s" >/dev/null 2>&1 && echo 1 || echo 0)"
done

echo "restore-guard: ${checks} checks, $([ "$fail" = 0 ] && echo PASS || echo FAIL)"
exit "$fail"
