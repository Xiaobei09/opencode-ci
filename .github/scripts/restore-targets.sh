#!/usr/bin/env bash
# R573: extracted verbatim from iterate.yml "Restore workspace snapshots" so it can
# run in parallel with the environment restore in a single step.
set +e
# R2589 (D9): one wall-clock measurement for the whole targets restore so the
# run log shows where the non-opencode budget goes.
RT_T0=$(date +%s)
# Target workspace bundles also live in the release now (a whole tar of the
# repo's runtime dirs), not in git, so the repository can stay a clean baseline.
ENV_TAG="env"
# ROUND 35（降级读取策略，与 env 包同口径）：页按 `sort -V` 定序；有 meta.json 时先核对
# 拼接字节数，不一致则拒绝应用（宁可用克隆里的 git 版本，也不铺半套 targets）；
# 压缩格式按魔数判定；manifest 缺失 ⇒ 退回旧的无校验直解。
# ROUND 44：同 env 读侧——主包不可用时改从保险 tag 'env-safe' 还原，避免撕裂包铺半套/空 targets。
FALLBACK_TAG="${SESSIONS_FALLBACK_TAG:-env-safe}"
tgt_try() {
  local tag="$1" dl="/tmp/tgdl-$1" vols pages bytes expect hdr tflag
  rm -rf "$dl" && mkdir -p "$dl"
  # R341: parallel multi-range fetch; the helper itself falls back to
  # plain single-stream `gh release download` on any internal failure.
  bash "$GITHUB_WORKSPACE/.github/scripts/fetch-asset.sh" "$SESSIONS_REPO" "$tag" 'targets.tar.gz*' "$dl" || return 1
  ls "$dl"/targets.tar.gz* >/dev/null 2>&1 || return 1
  gh release download "$tag" --repo "$SESSIONS_REPO" --pattern 'meta.json' --dir "$dl" --clobber >/dev/null 2>&1 || true
  vols=$(ls "$dl"/targets.tar.gz* 2>/dev/null | sort -V)
  pages=$(echo "$vols" | wc -l)
  bytes=$(cat $vols 2>/dev/null | wc -c)
  expect=$(jq -r '.targets.bytes // empty' "$dl/meta.json" 2>/dev/null || true)
  if [ -n "$expect" ] && [ "$bytes" != "$expect" ]; then
    echo "::warning::$tag targets package incomplete ($bytes of $expect bytes, $pages page(s)); refusing to apply a partial restore"
    return 1
  fi
  # R2560（D6）：与 env 读侧同口径，meta 有 sha256 时必须校验拼接包哈希。
  expect_sha=$(jq -r '.targets.sha256 // empty' "$dl/meta.json" 2>/dev/null || true)
  if [ -n "$expect_sha" ]; then
    got_sha=$(cat $vols 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ "$got_sha" != "$expect_sha" ]; then
      echo "::warning::$tag targets package checksum mismatch (got ${got_sha:0:12} expect ${expect_sha:0:12}, $pages page(s)); refusing to apply"
      return 1
    fi
  fi
  hdr=$(head -c 6 "$(echo "$vols" | head -1)" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$hdr" in
    1f8b*)        tflag="-z" ;;
    fd377a585a00) tflag="-J" ;;
    28b52ffd*)    tflag="--zstd" ;;
    425a68*)      tflag="-j" ;;
    *)            tflag="" ;;
  esac
  if cat $vols | tar -xf - -C "$SESSIONS_DIR" $tflag 2>/dev/null; then
    echo "target workspace package restored from '$tag' ($pages page(s), $bytes bytes, tar ${tflag:-plain}${expect:+, size-verified}${expect_sha:+, sha-verified})"
    return 0
  fi
  echo "::warning::$tag target workspace package failed to extract (tar ${tflag:-plain}, $bytes bytes)"
  return 1
}
# ROUND 53：与 env 读侧同口径——换装窗口里 targets 也可能只剩 stage-*；
# 用 stage-targets.tar.gz* + stage-meta.json 严格校验后再应用，否则退回 env-safe。
tgt_try_staged() {
  local tag="$1" dl="/tmp/tgdl-$1-staged" vols pages bytes expect hdr tflag
  rm -rf "$dl" && mkdir -p "$dl"
  bash "$GITHUB_WORKSPACE/.github/scripts/fetch-asset.sh" "$SESSIONS_REPO" "$tag" 'stage-targets.tar.gz*' "$dl" || return 1
  ls "$dl"/stage-targets.tar.gz* >/dev/null 2>&1 || return 1
  gh release download "$tag" --repo "$SESSIONS_REPO" --pattern 'stage-meta.json' --dir "$dl" --clobber >/dev/null 2>&1 || true
  expect=$(jq -r '.targets.bytes // empty' "$dl/stage-meta.json" 2>/dev/null || true)
  if [ -z "$expect" ]; then
    echo "::warning::$tag staged targets have no manifest; refusing an unverifiable staged restore"
    return 1
  fi
  vols=$(ls "$dl"/stage-targets.tar.gz* 2>/dev/null | sort -V)
  pages=$(echo "$vols" | wc -l)
  bytes=$(cat $vols 2>/dev/null | wc -c)
  if [ "$bytes" != "$expect" ]; then
    echo "::warning::$tag staged targets incomplete ($bytes of $expect bytes, $pages page(s)); refusing"
    return 1
  fi
  # R2560（D6）：stage 代同样校验 sha256（meta 缺失时跳过）。
  expect_sha=$(jq -r '.targets.sha256 // empty' "$dl/stage-meta.json" 2>/dev/null || true)
  if [ -n "$expect_sha" ]; then
    got_sha=$(cat $vols 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ "$got_sha" != "$expect_sha" ]; then
      echo "::warning::$tag staged targets checksum mismatch (got ${got_sha:0:12} expect ${expect_sha:0:12}, $pages page(s)); refusing"
      return 1
    fi
  fi
  hdr=$(head -c 6 "$(echo "$vols" | head -1)" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$hdr" in
    1f8b*)        tflag="-z" ;;
    fd377a585a00) tflag="-J" ;;
    28b52ffd*)    tflag="--zstd" ;;
    425a68*)      tflag="-j" ;;
    *)            tflag="" ;;
  esac
  if cat $vols | tar -xf - -C "$SESSIONS_DIR" $tflag 2>/dev/null; then
    echo "target workspace package restored from '$tag' verified staged generation ($pages page(s), $bytes bytes, tar ${tflag:-plain}${expect_sha:+, sha-verified})"
    return 0
  fi
  echo "::warning::$tag staged targets failed to extract ($pages page(s), $bytes bytes)"
  return 1
}
if tgt_try "$ENV_TAG"; then
  :
elif tgt_try_staged "$ENV_TAG"; then
  echo "::warning::primary targets were mid-swap; restored the verified staged generation"
elif [ "$FALLBACK_TAG" != "$ENV_TAG" ] && tgt_try "$FALLBACK_TAG"; then
  echo "::warning::primary targets package '$ENV_TAG' unusable; restored the insurance generation '$FALLBACK_TAG'"
fi
# ROUND 34 (D6): the target-workspace package is built at the END of a run, so right
# after an aborted/cancelled run it is OLDER than the fresh clone of the sessions repo.
# Extracting it above would then downgrade the *tracked* knowledge dirs in the working
# tree (state/ tasks/ sessions/), and the next agent could re-commit that as a revert.
# `workspace-snapshots/` is deliberately left as the package provided it: its index.json
# and the target bundles are runtime artifacts that must stay mutually consistent.
#
# ROUND 77: records are no longer tracked in the sessions repo (the operator's model:
# the release targets package is the authority for records, the repo tree is a clean
# reset baseline). Only re-assert from git while those dirs are actually tracked;
# otherwise the package content must stay in place and there is nothing to warn about.
if [ -d "$SESSIONS_DIR/.git" ] \
   && git -C "$SESSIONS_DIR" ls-files --error-unmatch state >/dev/null 2>&1; then
  git -C "$SESSIONS_DIR" checkout -- state tasks sessions 2>/dev/null \
    || echo "::warning::could not re-assert tracked knowledge dirs (state/tasks/sessions) from git"
fi
INDEX="$SESSIONS_DIR/workspace-snapshots/index.json"
[ -f "$INDEX" ] || exit 0
# R342（Stage C：目录直存快照）：targets 包现在直接携带目标工作区**整目录**
# （tar 根下 <name>，含 .git），解包后落在 $SESSIONS_DIR/<name>；同文件系统
# mv 瞬时完成。旧格式（bundle 克隆）实测 1.4GB 包 CPU 密集约 72s，是本步最大
# 单项；目录直存恢复实测约 11s，且还原度更高（含未跟踪/被忽略文件、stash ref）。
while IFS= read -r snap_name; do
  [ -n "$snap_name" ] || continue
  if [ -d "$SESSIONS_DIR/$snap_name" ] && [ ! -e "$TARGETS_DIR/$snap_name" ]; then
    # R2586（D6）：符号链接不是独立工作区；照旧还原链接以保持会话现场，
    # 但不让它进入指纹计数（旧代码会把它索引成第二个目标，restore 报 ok=5）。
    [ -L "$SESSIONS_DIR/$snap_name" ] \
      && echo "::warning::target snapshot $snap_name is a symlink; restored as a link but excluded from the fingerprint count"
    mv "$SESSIONS_DIR/$snap_name" "$TARGETS_DIR/$snap_name" \
      && echo "target workspace $snap_name restored from its directory snapshot"
  fi
done < <(jq -r '.snapshots[]? | select(((.mode // "") | startswith("dirtar"))) | .dir // empty' "$INDEX" 2>/dev/null)
# R573（slim targets 恢复）：包内只有工作树、没有 .git。按 index 的 repo/commit
# 做 depth-1 fetch（实测 proxyip 7.2s / PCB 1.3s，替代 1.58GB 历史包下载），
# 再 update-ref + reset --mixed：索引指向快照 commit，工作树文件保持原样
# （未提交修改直接是 unstaged），并创建 origin/<branch> 供下一代 slim 判定。
# R2589（D9）：四个目标互不相干，fetch 串行曾是 restore 的长尾（proxyip 单仓
# ~7s）。这里并行启动、统一 wait；日志顺序可能交错，但每行仍带目标名。
SLIM_T0=$(date +%s)
SLIM_PIDS=()
while IFS=$'\t' read -r snap_name snap_repo snap_branch snap_commit; do
  [ -n "$snap_name" ] || continue
  target_dir="$TARGETS_DIR/$snap_name"
  [ -d "$target_dir" ] || continue
  # R2586：符号链接不是独立工作区，跳过 slim 重建。
  [ -L "$target_dir" ] && continue
  [ -e "$target_dir/.git" ] && continue
  (
    set +e
    cd "$target_dir" || exit 0
    git init -q 2>/dev/null || exit 0
    git remote add origin "$snap_repo" 2>/dev/null \
      || git remote set-url origin "$snap_repo" 2>/dev/null
    ok=0
    if [ -n "$snap_commit" ]; then
      git fetch -q --depth=1 origin "$snap_commit" 2>/dev/null && ok=1
    fi
    if [ "$ok" != 1 ] && [ -n "$snap_branch" ]; then
      git fetch -q --depth=1 origin "$snap_branch" 2>/dev/null \
        && git cat-file -e "$snap_commit^{commit}" 2>/dev/null && ok=1
    fi
    if [ "$ok" = 1 ]; then
      if [ -n "$snap_branch" ]; then
        git update-ref "refs/heads/$snap_branch" "$snap_commit" 2>/dev/null
        git symbolic-ref HEAD "refs/heads/$snap_branch" 2>/dev/null
        git update-ref "refs/remotes/origin/$snap_branch" "$snap_commit" 2>/dev/null
      else
        git update-ref --no-deref HEAD "$snap_commit" 2>/dev/null
      fi
      git reset -q --mixed 2>/dev/null
      echo "target workspace $snap_name restored (slim worktree + depth-1 git at ${snap_commit:0:12})"
    else
      # 远端不可达时不能把工作区留成「无 .git」——下一代 Save 会因缺少
      # TGT_DIRS 条目而把它漏出包。本地提交一次保住工作树，并让下一代
      # 自动回退全量模式（HEAD 不在远端 ⇒ MODE=dirtar）。
      git add -A 2>/dev/null
      git -c user.name=opencode-ci -c user.email=opencode-ci@users.noreply.github.com \
        commit -q -m "slim restore fallback: remote fetch failed" 2>/dev/null
      echo "::warning::slim target $snap_name remote fetch failed; kept worktree as a local commit (next snapshots use full mode)"
    fi
  ) &
  SLIM_PIDS+=("$!")
done < <(jq -r '.snapshots[]? | select(((.mode // "") | startswith("dirtar"))) | [.dir, .repo, .branch, .commit] | @tsv' "$INDEX" 2>/dev/null)
if [ ${#SLIM_PIDS[@]} -gt 0 ]; then
  wait "${SLIM_PIDS[@]}" 2>/dev/null || true
fi
echo "target slim restore timing: ${#SLIM_PIDS[@]} target(s) in $(( $(date +%s) - SLIM_T0 ))s (parallel)"
# R2580（D2 环境完美还原）：Save 步骤为每个 target 记录了 fp（head + branch +
# 工作树文件路径/内容的 sha256）。解包/重置漏文件时 HEAD 仍可能匹配，
# restore-monitor 的 HEAD 检查发现不了；这里在 OpenCode 启动前重算并比对，
# 不匹配就 fail closed。Save 门控在 restore 成功上，因此坏工作树不会覆盖好快照。
FP_OK=0
FP_BAD=0
while IFS=$'\t' read -r snap_name snap_fp snap_commit; do
  [ -n "$snap_name" ] || continue
  [ -n "$snap_fp" ] || continue
  target_dir="$TARGETS_DIR/$snap_name"
  # R2586：符号链接不是工作区，不参与指纹校验（旧 index 可能仍含这类条目）。
  if [ -L "$target_dir" ]; then
    echo "target restore fingerprint skipped: dir=$snap_name is a symlink (not a target workspace)"
    continue
  fi
  if [ ! -d "$target_dir" ]; then
    FP_BAD=$((FP_BAD + 1))
    echo "::error::target restore fingerprint mismatch: dir=$snap_name is missing (want=${snap_fp:0:12})"
    continue
  fi
  head=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || true)
  branch=$(git -C "$target_dir" symbolic-ref --short HEAD 2>/dev/null || true)
  wt=$( (cd "$target_dir" && find . -path ./.git -prune -o -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1) )
  got=$(printf 'head=%s\nbranch=%s\nworktree=%s\n' "$head" "$branch" "$wt" | sha256sum | cut -d' ' -f1)
  if [ "$got" = "$snap_fp" ]; then
    FP_OK=$((FP_OK + 1))
    echo "target restore fingerprint ok: dir=$snap_name commit=${snap_commit:0:12} fp=${got:0:12}"
  else
    FP_BAD=$((FP_BAD + 1))
    echo "::error::target restore fingerprint mismatch: dir=$snap_name want=${snap_fp:0:12} got=${got:0:12} (worktree incomplete or changed; refusing to run)"
  fi
done < <(jq -r '.snapshots[]? | select(((.mode // "") | startswith("dirtar"))) | [.dir, .fp // "", .commit // ""] | @tsv' "$INDEX" 2>/dev/null)
echo "target restore fingerprint summary: ok=$FP_OK mismatch=$FP_BAD"
if [ "$FP_BAD" -gt 0 ]; then
  exit 1
fi
# R342（records 独立资产，每轮刷新）：targets 包内嵌一份 records（兼容旧读侧），
# 另有独立 records 资产——targets 内容未变时会被原样沿用，records 却必须每轮
# 更新。这里优先覆盖为独立资产的最新副本：先解到临时目录并验证完整，再替换；
# 任何失败都保留包内嵌副本，绝不半途清空记录。
RDL=/tmp/rec-dl; rm -rf "$RDL"; mkdir -p "$RDL"
if bash "$GITHUB_WORKSPACE/.github/scripts/fetch-asset.sh" "$SESSIONS_REPO" "$ENV_TAG" 'records.tar.gz*' "$RDL" 2>/dev/null \
   && ls "$RDL"/records.tar.gz* >/dev/null 2>&1; then
  gh release download "$ENV_TAG" --repo "$SESSIONS_REPO" --pattern 'meta.json' --dir "$RDL" --clobber >/dev/null 2>&1 || true
  REXP=$(jq -r '.records.bytes // empty' "$RDL/meta.json" 2>/dev/null || true)
  RVOLS=$(ls "$RDL"/records.tar.gz* 2>/dev/null | sort -V)
  RBYTES=$(cat $RVOLS 2>/dev/null | wc -c)
  # R2560（D6）：records 同样按 meta sha256 校验；缺失时保持旧包兼容。
  REXP_SHA=$(jq -r '.records.sha256 // empty' "$RDL/meta.json" 2>/dev/null || true)
  RSHA_OK=1
  if [ -n "$REXP_SHA" ]; then
    RGOT_SHA=$(cat $RVOLS 2>/dev/null | sha256sum | cut -d' ' -f1)
    [ "$RGOT_SHA" = "$REXP_SHA" ] || RSHA_OK=0
  fi
  if [ -n "$REXP" ] && [ "$RBYTES" = "$REXP" ] && [ "$RSHA_OK" = "1" ]; then
    RX=/tmp/rec-x; rm -rf "$RX"; mkdir -p "$RX"
    if cat $RVOLS | tar -xzf - -C "$RX" 2>/dev/null \
       && [ -d "$RX/state" ] && [ -d "$RX/tasks" ] && [ -d "$RX/sessions" ]; then
      rm -rf "$SESSIONS_DIR/state" "$SESSIONS_DIR/tasks" "$SESSIONS_DIR/sessions" "$SESSIONS_DIR/loop-state.md"
      cp -a "$RX"/. "$SESSIONS_DIR"/ 2>/dev/null
      echo "records overlaid from the standalone records asset ($RBYTES bytes${REXP_SHA:+, sha-verified})"
    else
      echo "::warning::records asset incomplete (state/tasks/sessions missing); keeping the embedded copy"
    fi
  else
    echo "::warning::records asset unverified (bytes=$RBYTES expect=${REXP:-none}); keeping the embedded copy"
  fi
fi
COUNT=$(jq '.snapshots | length' "$INDEX")
for i in $(seq 0 $((COUNT - 1))); do
  dir=$(jq -r ".snapshots[$i].dir // empty" "$INDEX")
  bundle=$(jq -r ".snapshots[$i].bundle // empty" "$INDEX")
  worktree=$(jq -r ".snapshots[$i].worktree // empty" "$INDEX")
  branch=$(jq -r ".snapshots[$i].branch // empty" "$INDEX")
  commit=$(jq -r ".snapshots[$i].commit // empty" "$INDEX")
  repo=$(jq -r ".snapshots[$i].repo // empty" "$INDEX")
  [ -n "$dir" ] || continue
  target_dir="$TARGETS_DIR/$dir"
  [ -e "$target_dir" ] && continue
  # R203（D6 还原链缺口）：快照 bundle 克隆失败时**退回远端**再试一次。
  # 背景：`git bundle create` 对 **shallow 仓**（`git clone --depth N`）会造出无法
  # 独立克隆的包（实测 proxyip：`Could not read <oid>` / `remote did not send all
  # necessary objects`），而这里原先只打一句 warning 就 skip ⇒ 换 runner 时该目标
  # 工作区**整个缺失**（R202 实测：那一代靠代理自己从 GitHub clone 才补回）。
  # 只影响失败路径：bundle 正常时行为与本补丁前完全一致。
  if ! git clone "$SESSIONS_DIR/$bundle" "$target_dir"; then
    rm -rf "$target_dir"
    if [ -z "$repo" ] || ! git clone "$repo" "$target_dir"; then
      echo "::warning::clone failed for $dir (bundle and remote), skipping"
      continue
    fi
    echo "::warning::bundle clone failed for $dir; recovered from remote $repo (shallow snapshot)"
  fi
  (
    set +e
    cd "$target_dir" || exit 0
    if [ -n "$branch" ]; then
      git checkout "$branch" 2>/dev/null \
        || git checkout -b "$branch" "origin/$branch" 2>/dev/null \
        || echo "::warning::branch $branch missing for $dir, staying on default"
    fi
    if [ -n "$commit" ]; then
      git rev-parse --verify HEAD >/dev/null 2>&1 || git checkout "$commit" 2>/dev/null || true
    fi
    git fetch origin '+refs/stash:refs/stash' 2>/dev/null || true
    # R203：`worktree.tar.gz` 缺失是**良性**的（`workferry pack` 对干净仓不产出
    # 文件）⇒ 路径为空/文件不存在时静默跳过，不再每轮打一条误导告警。
    if [ -n "$worktree" ] && [ -f "$SESSIONS_DIR/$worktree" ] \
      && ! workferry apply --dir "$target_dir" "$SESSIONS_DIR/$worktree"; then
      echo "::warning::workferry apply failed for $dir, untracked files may be lost"
    fi
    if git rev-parse --verify refs/stash >/dev/null 2>&1; then
      STASH_SHA=$(git rev-parse refs/stash)
      git stash apply --index "$STASH_SHA" 2>/dev/null \
        || echo "::warning::stash apply failed for $dir, staged state may be incomplete"
    fi
    if [ -n "$repo" ]; then
      git remote set-url origin "$repo"
    fi
  )
done
echo "targets restore timing: total $(( $(date +%s) - RT_T0 ))s"

