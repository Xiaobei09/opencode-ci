#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
set +e
SNAP="$SESSIONS_DIR/workspace-snapshots"
mkdir -p "$SNAP"
INDEX="$SNAP/index.json"
[ -f "$INDEX" ] || echo '{"snapshots": []}' > "$INDEX"
# R2752: one worktree fingerprint formula for both the normal index and the
# pre-pack refresh. Keep in lockstep with restore-targets.sh (head+branch+
# worktree, all .git dirs pruned; nested .git is rebuilt on restore).
fp_of() {
  local repo_dir="$1" commit="$2" branch="$3"
  printf 'head=%s\nbranch=%s\nworktree=%s\n' "$commit" "$branch" \
    "$(cd "$repo_dir" && find . -name .git -prune -o -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)" \
    | sha256sum | cut -d' ' -f1
}
# R2752: --refresh-fp only re-hashes existing entries; snapshot-environment.sh
# calls it right before packing so a file appended after the first index
# (env-sync + the records pack can take tens of seconds) is hashed into the
# same state the tar carries. No fetch/stash/mode changes here.
REFRESH_FP=0
[ "${1:-}" = "--refresh-fp" ] && REFRESH_FP=1
echo "target snapshots: index=$INDEX$([ "$REFRESH_FP" = 1 ] && echo ' (refresh-fp)')"
find "$SNAP" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null
shopt -s nullglob
for target_dir in "$TARGETS_DIR"/*/; do
  repo_dir="${target_dir%/}"
  # R2586（D6）：只索引真实的目标目录。会话会在工作区里放指向别处的
  # 符号链接（实测 `pcb -> PCB`，10:29 创建）；旧逻辑的 `[ -d ./.git ]`
  # 会跟随链接，把同一个仓库再索引一次（fp 相同、restore 报 ok=5），
  # 更糟的是链接若指向 $HOME 等大树，指纹会把外部内容也算进来。
  [ -L "$repo_dir" ] && continue
  [ -d "$repo_dir/.git" ] || continue
  name=$(basename "$repo_dir")
  if [ "$REFRESH_FP" = 1 ]; then
    BRANCH=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || true)
    COMMIT=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
    FP=$(fp_of "$repo_dir" "$COMMIT" "$BRANCH")
    tmp=$(mktemp)
    if jq --arg d "$name" --arg fp "$FP" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '(.snapshots[] | select(.dir == $d) | .fp) = $fp
          | (.snapshots[] | select(.dir == $d) | .saved_at) = $at' \
         "$INDEX" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$INDEX"
      echo "target snapshot fp refreshed: dir=$name commit=${COMMIT:0:12} fp=${FP:0:12}"
    else
      rm -f "$tmp"
      echo "::warning::could not refresh the fingerprint for $name"
    fi
    continue
  fi
  snap_dir="$SNAP/$name"
  rm -rf "$snap_dir"

  BRANCH=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || true)
  COMMIT=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
  REMOTE=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
  SAVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  MODE="dirtar"
  PRIOR=$(jq -r --arg d "$name" '.snapshots[] | select(.dir == $d) | [.commit // "", .mode // ""] | @tsv' "$INDEX" 2>/dev/null | head -1)
  PRIOR_COMMIT=${PRIOR%%$'\t'*}
  PRIOR_MODE=${PRIOR##*$'\t'}
  SKIP_FETCH=0
  if [ -n "$COMMIT" ] && [ "$COMMIT" = "$PRIOR_COMMIT" ] && [ "$PRIOR_MODE" = "dirtar-slim" ] \
     && [ ! -f "$repo_dir/.gitmodules" ] \
     && ! git -C "$repo_dir" ls-files -u 2>/dev/null | grep -q .; then
    SKIP_FETCH=1
    MODE="dirtar-slim"
  fi
  if [ "$SKIP_FETCH" != 1 ] && [ -n "$REMOTE" ] && [ -n "$BRANCH" ]; then
    timeout 20 git -C "$repo_dir" fetch --quiet --no-tags origin \
      "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || true
  fi
  if [ "$SKIP_FETCH" != 1 ] && [ -n "$COMMIT" ] && [ -n "$BRANCH" ] && [ ! -f "$repo_dir/.gitmodules" ] \
     && ! git -C "$repo_dir" ls-files -u 2>/dev/null | grep -q . \
     && git -C "$repo_dir" branch -r --contains "$COMMIT" 2>/dev/null | grep -q .; then
    MODE="dirtar-slim"
  fi

  if [ "$MODE" = "dirtar" ]; then
    STASH_HASH=$(git -C "$repo_dir" stash create "snapshot-$(date -u +%s)")
    if [ -n "$STASH_HASH" ]; then
      git -C "$repo_dir" stash store -m "snapshot" "$STASH_HASH" 2>/dev/null || true
    fi
  fi

  # R2736（运营者：「继续」压缩两轮间隔）：slim 目标只存工作树、不存 .git，
  # 但嵌套仓库（实测 proxyip/pcb 的 .git 有 324MB）此前仍被整包上传，是
  # targets 包 376MB 的主要来源。为每个 slim 目标的嵌套仓库记录 remote/
  # branch/commit，打包时排除其 .git，还原时按 top-level 同样的 depth-1
  # fetch 重建（工作树文件不动，未提交修改仍是 unstaged）。
  # 只在该 commit 已存在于远端分支时启用；否则保留 .git 整包，宁慢不丢。
  NESTED='[]'
  if [ "$MODE" = "dirtar-slim" ]; then
    NESTED=$(cd "$repo_dir" && find . -mindepth 2 -maxdepth 3 -type d -name .git -print 2>/dev/null | while IFS= read -r g; do
      nd=${g#./}; nd=${nd%/.git}
      nrepo=$(git -C "$nd" remote get-url origin 2>/dev/null || true)
      nbranch=$(git -C "$nd" symbolic-ref --short HEAD 2>/dev/null || true)
      ncommit=$(git -C "$nd" rev-parse HEAD 2>/dev/null || true)
      [ -n "$nrepo" ] && [ -n "$nbranch" ] && [ -n "$ncommit" ] || continue
      git -C "$nd" branch -r --contains "$ncommit" 2>/dev/null | grep -q . || continue
      jq -n --arg dir "$nd" --arg repo "$nrepo" --arg branch "$nbranch" --arg commit "$ncommit" \
        '{dir:$dir, repo:$repo, branch:$branch, commit:$commit}'
    done | jq -s '.')
    printf '%s' "$NESTED" | jq -e 'type == "array"' >/dev/null 2>&1 || NESTED='[]'
  fi

  # R2736: the fingerprint only covers the working tree; nested .git is not
  # part of the slim package and is rebuilt on restore, so hashing it would
  # make every restore disagree with the index.
  FP=$(fp_of "$repo_dir" "$COMMIT" "$BRANCH")

  ENTRY=$(jq -n \
    --arg repo "$REMOTE" \
    --arg dir "$name" \
    --arg mode "$MODE" \
    --arg fp "$FP" \
    --arg branch "$BRANCH" \
    --arg commit "$COMMIT" \
    --arg saved_at "$SAVED_AT" \
    --argjson nested "$NESTED" \
    '{repo: $repo, dir: $dir, mode: $mode, fp: $fp, bundle: "", worktree: "", branch: $branch, commit: $commit, saved_at: $saved_at, nested: $nested}')

  tmp=$(mktemp)
  jq --arg dir "$name" '.snapshots |= map(select(.dir != $dir))' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
  tmp=$(mktemp)
  jq --argjson e "$ENTRY" '.snapshots += [$e]' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
  echo "target snapshot indexed: dir=$name commit=${COMMIT:0:12} mode=$MODE fp=${FP:0:12}"
done
# R2586（D6）：旧 index 里若已存在符号链接条目（上一代旧代码写入的），
# 必须在本代修剪掉；否则 TGT_FP 永远包含它，包会被判定“未变化”而携带，
# 链接一代代被还原回来。只修剪符号链接，视觉上“消失”的目录保留条目
# （下一轮 restore 会从包里恢复它，宁可复活也不静默丢工作区）。
while IFS= read -r _sd; do
  [ -n "$_sd" ] || continue
  if [ -L "$TARGETS_DIR/$_sd" ]; then
    _tmp=$(mktemp)
    if jq --arg dir "$_sd" '.snapshots |= map(select(.dir != $dir))' "$INDEX" > "$_tmp" 2>/dev/null; then
      mv "$_tmp" "$INDEX"
      echo "target snapshot pruned: dir=$_sd (symlink, not a real workspace)"
    else
      rm -f "$_tmp"
      echo "::warning::could not prune symlink target entry $_sd from the snapshot index"
    fi
  fi
done < <(jq -r '.snapshots[]?.dir // empty' "$INDEX" 2>/dev/null)
echo "target snapshot index: $(jq -r '[.snapshots[]?] | length' "$INDEX" 2>/dev/null || echo 0) entries"
