#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
set +e
ENV_SRC="$SESSIONS_DIR/opencode"
mkdir -p "$ENV_SRC"
ENV_TAG="env"
SPLIT_SIZE="${SPLIT_SIZE:-256m}"
if command -v python3 >/dev/null 2>&1 && [ -f "$HOME/.local/share/opencode/opencode.db" ]; then
  python3 -c 'import sqlite3;c=sqlite3.connect("'"$HOME"'/.local/share/opencode/opencode.db");c.execute("PRAGMA wal_checkpoint(TRUNCATE)");c.close()' 2>/dev/null \
    && echo "sqlite WAL checkpointed" || echo "::warning::sqlite WAL checkpoint skipped"
fi
OUT=/tmp/envsnap
rm -rf "$OUT" && mkdir -p "$OUT"
if command -v pigz >/dev/null 2>&1; then
  TAR_COMP=(tar -I 'pigz -1 -p4' -cf -)
else
  TAR_COMP=(tar -czf -)
fi
# R2554: the targets bundle is the bulk of the snapshot (51 MB with
# pigz -1). zstd -10 packs it to ~21 MB in the same ~4s, and the
# restore side already detects the 28b52ffd magic. env/records keep
# pigz because their readers are unchanged and env is mostly carried.
if command -v zstd >/dev/null 2>&1; then
  TGT_TAR_COMP=(tar -I 'zstd -10 -T4 -q' -cf -)
elif command -v pigz >/dev/null 2>&1; then
  TGT_TAR_COMP=(tar -I 'pigz -1 -p4' -cf -)
else
  TGT_TAR_COMP=(tar -czf -)
fi
SNAP_T0=$(date +%s)
SKIP_ENV_PACK=0
if [ -f "$SESSIONS_DIR/opencode/config/scripts/env-sync.sh" ]; then
  SYNC_OK=0
  SYNC_LOG="$RUNNER_TEMP/env-sync-run-end.log"
  : > "$SYNC_LOG"
  for a in 1 2; do
    # R2518: WAIT_LOCK makes run-end wait for the bridge interval sync
    # instead of silently skipping (rc=75 = still locked → retry).
    # R2543: cap each wait at 8s (boot sync can hold the lock for
    # minutes); the release pack below still captures the final state.
    # R2545: keep the per-attempt output. The old `>/dev/null 2>&1`
    # meant a failed lock wait left no evidence in the run log at all.
    sync_t0=$(date +%s)
    ENV_SYNC_WHY=run-end ENV_SYNC_TIMEOUT=180 ENV_SYNC_WAIT_LOCK=1 \
      ENV_SYNC_WAIT_SECONDS=8 \
      timeout 300 bash "$SESSIONS_DIR/opencode/config/scripts/env-sync.sh" >>"$SYNC_LOG" 2>&1
    sync_rc=$?
    sync_took=$(( $(date +%s) - sync_t0 ))
    if [ "$sync_rc" = 0 ]; then
      SYNC_OK=1
      echo "run-end env-sync attempt $a ok in ${sync_took}s"
      break
    fi
    echo "::warning::run-end env-sync attempt $a failed rc=$sync_rc after ${sync_took}s (75=lock busy); retrying"
    # R2545: show why it failed. Without this the operator only saw the
    # final "packing the env release" line and could not tell whether
    # the lock was busy or the push failed.
    tail -6 "$SYNC_LOG" | sed 's/^/  env-sync: /'
    sleep 2
  done
  if [ "$SYNC_OK" = 1 ]; then
    echo "run-end env-sync pushed; the env-sync branch now holds the final state"
    gh release download "$ENV_TAG" --repo "$SESSIONS_REPO" --pattern 'meta.json' --dir "$OUT" --clobber >/dev/null 2>&1 || true
    if [ -s "$OUT/meta.json" ] && jq -e '(.env.bytes // 0) > 0' "$OUT/meta.json" >/dev/null 2>&1; then
      cp -f "$OUT/meta.json" "$OUT/meta.env-carry.json"
      SKIP_ENV_PACK=1
      echo "env pack skipped: carried the release env section; the branch is the primary env source"
    else
      echo "::warning::no usable previous meta.json to carry the env section; packing env anyway"
    fi
  else
    echo "::warning::run-end env-sync failed; packing the env release as before"
  fi
fi
echo "snapshot timing: env-sync $(( $(date +%s) - SNAP_T0 ))s (skip_pack=$SKIP_ENV_PACK)"
if [ "$SKIP_ENV_PACK" != 1 ]; then
find "$HOME/.local/share/opencode/shell" -type f -size +50M -delete 2>/dev/null || true
# R2573（D6）：tar|split 是管线，bash 默认只看最后一个命令的退出码 ——
# tar 中途失败（文件消失/权限/磁盘）会被 split 的成功掩盖，随后 meta 的
# bytes/sha 恰好按“半包”计算，读侧校验全绿却永久少数据。必须在同一
# 子 shell 开 pipefail，失败就退出本步：旧 release 原样保留。
if ! ( set -o pipefail
  "${TAR_COMP[@]}" -C "$HOME" \
  --exclude='./work' \
  --exclude='./.cache' \
  --exclude='./.opencode/bin' \
  --exclude='./.ssh' \
  --exclude='./.config/gh' \
  --exclude='./.gitconfig' \
  --exclude='./.git-credentials' \
  --exclude='./.local/share/opencode/log' \
  --exclude='./.npm/_cacache' \
  --exclude='./.bun' \
  --exclude='./actions-runner' \
  --exclude='./.rustup' \
  --exclude='./.dotnet' \
  --exclude='./.opencode/.v2lib-live' \
  . 2>/dev/null | split -b "$SPLIT_SIZE" - "$OUT/env.tar.gz." ); then
  echo "::error::environment package failed (tar/split returned nonzero); refusing to publish a partial env package (previous generation kept)"
  exit 1
fi
fi
REC_OK=0
REC_T0=$(date +%s)
if ( set -o pipefail; cd "$SESSIONS_DIR" || exit 1; "${TAR_COMP[@]}" state tasks sessions loop-state.md 2>/dev/null | split -b "$SPLIT_SIZE" - "$OUT/records.tar.gz." ) \
   && ls "$OUT"/records.tar.gz.* >/dev/null 2>&1; then
  REC_OK=1
else
  # R2573（D6）：半包不得留在 $OUT 被后续 stage/upload 当成“最新 records”
  # 发出去。删掉它，meta 不写 records，读侧继续用 targets 内嵌副本。
  echo "::warning::records package failed (tar/split nonzero); dropping the partial asset; readers will use the copy embedded in the targets package"
  rm -f "$OUT"/records.tar.gz.* 2>/dev/null || true
fi
echo "snapshot timing: records pack $(( $(date +%s) - REC_T0 ))s, $(cat "$OUT"/records.tar.gz.* 2>/dev/null | wc -c) bytes"
TGT_FP=""; TGT_MODE=""
IDX="$SESSIONS_DIR/workspace-snapshots/index.json"
if [ -s "$IDX" ]; then
  _tn=$(jq -r '[.snapshots[]?] | length' "$IDX" 2>/dev/null || echo 0)
  _bad=$(jq -r '[.snapshots[]? | select((((.mode // "") | test("^dirtar")) | not) or ((.fp // "") | length) == 0)] | length' "$IDX" 2>/dev/null || echo 1)
  if [ "${_tn:-0}" -gt 0 ] 2>/dev/null && [ "${_bad:-1}" = "0" ]; then
    _slim=$(jq -r '[.snapshots[]? | select(.mode == "dirtar-slim")] | length' "$IDX" 2>/dev/null || echo 0)
    _full=$(jq -r '[.snapshots[]? | select(.mode == "dirtar")] | length' "$IDX" 2>/dev/null || echo 0)
    if [ "${_slim:-0}" = "${_tn}" ]; then TGT_MODE="dirtar-slim"
    elif [ "${_full:-0}" = "${_tn}" ]; then TGT_MODE="dirtar"
    else TGT_MODE="mixed"; fi
    TGT_FP=$(jq -r '[.snapshots[] | .dir + "=" + .fp] | sort | join("\n")' "$IDX" | sha256sum | cut -d' ' -f1)
  fi
fi
CARRY=0
if [ "$SKIP_ENV_PACK" = 1 ] && [ "$REC_OK" = 1 ] && [ -n "$TGT_FP" ] && [ -f "$OUT/meta.env-carry.json" ] \
  && jq -e '(.targets.mode // "") | test("^(dirtar|mixed)")' "$OUT/meta.env-carry.json" >/dev/null 2>&1 \
  && [ "$(jq -r '.targets.fp // empty' "$OUT/meta.env-carry.json" 2>/dev/null)" = "$TGT_FP" ]; then
  _prev_n=$(jq -r '.targets.volumes // 0' "$OUT/meta.env-carry.json" 2>/dev/null || echo 0)
  _have_n=$(gh release view "$ENV_TAG" --repo "$SESSIONS_REPO" --json assets --jq '[.assets[].name | select(test("^targets\\.tar\\.gz"))] | length' 2>/dev/null || echo 0)
  if [ "${_prev_n:-0}" -gt 0 ] 2>/dev/null && [ "${_prev_n:-0}" = "${_have_n:-0}" ]; then
    CARRY=1
    echo "targets unchanged (fingerprint match, $_have_n page(s)); carrying the previous targets package (the embedded index saved_at stays at the last repack; this run is recorded as meta.targets.carried_at)"
  else
    echo "::warning::targets fingerprint matches but the release has ${_have_n:-0} of ${_prev_n:-0} page(s); re-uploading targets"
  fi
fi
if [ "$CARRY" != 1 ]; then
  TGT_PACK_T0=$(date +%s)
  TGT_DIRS=()
  SLIM_EXCLUDES=()
  for d in "$TARGETS_DIR"/*/; do
    # R2586：符号链接不是独立目标，不打包（避免重复条目/外部树）。
    [ -L "${d%/}" ] && continue
    [ -d "${d%/}/.git" ] && TGT_DIRS+=("$(basename "$d")")
  done
  if [ -s "$IDX" ]; then
    while IFS= read -r sd; do
      [ -n "$sd" ] && SLIM_EXCLUDES+=("--exclude=$sd/.git" "--exclude=$sd/.git/*")
    done < <(jq -r '.snapshots[]? | select(.mode == "dirtar-slim") | .dir // empty' "$IDX" 2>/dev/null)
  fi
  # R2573（D6）：与 env 同因 —— tar|split 默认只看 split 的退出码。
  # 半包一旦发布，meta 的 bytes/sha 与半包一致，读侧“校验通过”；
  # 缺失的目标目录会在下一代 save 时被移出 index，等于静默丢工作区。
  # 失败即退出本步，保留上一代完整包。
  if ! ( set -o pipefail
    cd "$SESSIONS_DIR" || exit 1
    "${TGT_TAR_COMP[@]}" "${SLIM_EXCLUDES[@]}" --exclude='*/.git/*.lock' workspace-snapshots state tasks sessions loop-state.md -C "$TARGETS_DIR" ${TGT_DIRS[@]+"${TGT_DIRS[@]}"} 2>/dev/null | split -b "$SPLIT_SIZE" - "$OUT/targets.tar.gz." ); then
    echo "::error::target workspace package failed (tar/split returned nonzero); refusing to publish a partial targets package (previous generation kept)"
    exit 1
  fi
  if ! ls "$OUT"/targets.tar.gz.* >/dev/null 2>&1; then
    echo "::error::target workspace package produced no volumes; refusing to publish (previous generation kept)"
    exit 1
  fi
  echo "snapshot timing: targets pack $(( $(date +%s) - TGT_PACK_T0 ))s, $(cat "$OUT"/targets.tar.gz.* 2>/dev/null | wc -c) bytes"
fi
UP_T0=$(date +%s)
SZ=$(cat "$OUT"/env.tar.gz.* 2>/dev/null | wc -c)
TZ=$(cat "$OUT"/targets.tar.gz.* 2>/dev/null | wc -c)
ENV_N=$(ls "$OUT"/env.tar.gz.* 2>/dev/null | wc -l)
TGT_N=$(ls "$OUT"/targets.tar.gz.* 2>/dev/null | wc -l)
ENV_SHA=$(cat "$OUT"/env.tar.gz.* 2>/dev/null | sha256sum | cut -d' ' -f1)
TGT_SHA=$(cat "$OUT"/targets.tar.gz.* 2>/dev/null | sha256sum | cut -d' ' -f1)
REC_SZ=$(cat "$OUT"/records.tar.gz.* 2>/dev/null | wc -c)
REC_N=$(ls "$OUT"/records.tar.gz.* 2>/dev/null | wc -l)
REC_SHA=$(cat "$OUT"/records.tar.gz.* 2>/dev/null | sha256sum | cut -d' ' -f1)
SNAP_UP_PAR="${SNAP_UP_PAR:-8}"
upload_par() {
  local fail=0
  [ "$#" -gt 0 ] || return 1
  printf '%s\0' "$@" | \
    TAG="$ENV_TAG" REPO="$SESSIONS_REPO" \
    xargs -0 -n1 -P"$SNAP_UP_PAR" \
      bash -c 'gh release upload "$TAG" "$1" --repo "$REPO" --clobber >/dev/null 2>&1' _ \
    || fail=1
  return "$fail"
}
if ls "$OUT"/env.tar.gz.* >/dev/null 2>&1; then
  gh release view "$ENV_TAG" --repo "$SESSIONS_REPO" >/dev/null 2>&1 \
    || gh release create "$ENV_TAG" --repo "$SESSIONS_REPO" --title "environment snapshot" \
         --notes "Whole-\$HOME environment + target workspace packages; replaced every run." >/dev/null 2>&1
  jq -n --arg tag "$ENV_TAG" --arg run "${GITHUB_RUN_ID:-}" --arg commit "${GITHUB_SHA:-}" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg split "$SPLIT_SIZE" \
        --argjson env_bytes "${SZ:-0}" --argjson targets_bytes "${TZ:-0}" \
        --argjson env_volumes "${ENV_N:-0}" --argjson targets_volumes "${TGT_N:-0}" \
        --arg env_sha "$ENV_SHA" --arg targets_sha "$TGT_SHA" \
        --argjson records_bytes "${REC_SZ:-0}" --argjson records_volumes "${REC_N:-0}" \
        --arg records_sha "$REC_SHA" --argjson rec_ok "${REC_OK:-0}" \
        --arg tgt_mode "$TGT_MODE" --arg tgt_fp "$TGT_FP" \
        '{version:2, tag:$tag, run_id:$run, commit:$commit, created_at:$at, split_size:$split,
          env:{volumes:$env_volumes, bytes:$env_bytes, sha256:$env_sha},
          targets:{volumes:$targets_volumes, bytes:$targets_bytes, sha256:$targets_sha, mode:$tgt_mode, fp:$tgt_fp}}
         | (if $rec_ok==1 then .records={volumes:$records_volumes, bytes:$records_bytes, sha256:$records_sha} else . end)' \
        > "$OUT/meta.json" 2>/dev/null
  mkdir -p "$OUT/stage"
  for f in "$OUT"/env.tar.gz.* "$OUT"/targets.tar.gz.* "$OUT"/records.tar.gz.* "$OUT/meta.json"; do
    [ -f "$f" ] || continue
    cp -f "$f" "$OUT/stage/stage-$(basename "$f")"
  done
  stage_ok=0
  if upload_par "$OUT"/stage/* || gh release upload "$ENV_TAG" "$OUT"/stage/* --repo "$SESSIONS_REPO" --clobber >/dev/null 2>&1; then
    stage_ok=1
    for f in "$OUT"/stage/stage-*; do
      n=$(basename "$f"); l=$(stat -c%s "$f")
      r=$(gh release view "$ENV_TAG" --repo "$SESSIONS_REPO" --json assets --jq ".assets[] | select(.name==\"$n\") | .size")
      if [ "$l" = "$r" ]; then
        echo "staged ok $n = $l bytes"
      else
        stage_ok=0
        echo "::warning::staged size mismatch $n ($l vs $r)"
      fi
    done
  else
    echo "::warning::staged upload failed; the previous package is left untouched"
  fi
  if [ "$stage_ok" -eq 1 ]; then
    mapfile -t DELOLD < <(gh release view "$ENV_TAG" --repo "$SESSIONS_REPO" --json assets --jq '.assets[].name' 2>/dev/null \
      | grep -E '^(env|home|targets|records)\.tar\.gz(\.|$)|^meta\.json$' || true)
    for a in ${DELOLD[@]+"${DELOLD[@]}"}; do
      gh release delete-asset "$ENV_TAG" "$a" --repo "$SESSIONS_REPO" -y >/dev/null 2>&1 &
    done
    wait
    UPF=()
    for f in "$OUT"/env.tar.gz.* "$OUT"/targets.tar.gz.* "$OUT"/records.tar.gz.*; do
      [ -f "$f" ] && UPF+=("$f")
    done
    if upload_par "${UPF[@]}" || gh release upload "$ENV_TAG" "${UPF[@]}" --repo "$SESSIONS_REPO" --clobber >/dev/null 2>&1; then
      if [ -s "$OUT/meta.json" ]; then
        gh release upload "$ENV_TAG" "$OUT/meta.json" --repo "$SESSIONS_REPO" --clobber >/dev/null 2>&1 \
          || echo "::warning::failed to upload meta.json (readers will fall back to unverified extract)"
      else
        echo "::warning::failed to build meta.json (readers will fall back to unverified extract)"
      fi
      echo "environment package uploaded: $ENV_N volume(s), $SZ bytes"
      echo "target workspace package uploaded: $TGT_N volume(s), $TZ bytes"
      echo "package manifest: split=$SPLIT_SIZE env=$ENV_N vol targets=$TGT_N vol"
    else
      echo "::warning::failed to upload packages to release"
    fi
    for f in "$OUT"/stage/stage-*; do
      gh release delete-asset "$ENV_TAG" "$(basename "$f")" --repo "$SESSIONS_REPO" -y >/dev/null 2>&1 \
        && echo "staged copy removed: $(basename "$f")" &
    done
    wait
  fi
elif [ "$SKIP_ENV_PACK" = 1 ] \
  && { [ "${CARRY:-0}" = 1 ] || ls "$OUT"/targets.tar.gz.* >/dev/null 2>&1; }; then
  if [ -f "$OUT/meta.env-carry.json" ] \
    && jq --arg run "${GITHUB_RUN_ID:-}" --arg commit "${GITHUB_SHA:-}" \
       --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg split "$SPLIT_SIZE" \
       --argjson targets_bytes "${TZ:-0}" --argjson targets_volumes "${TGT_N:-0}" \
       --arg targets_sha "$TGT_SHA" \
       --argjson carry "${CARRY:-0}" --arg tgt_mode "$TGT_MODE" --arg tgt_fp "$TGT_FP" \
       --argjson rec_ok "${REC_OK:-0}" --argjson records_bytes "${REC_SZ:-0}" \
       --argjson records_volumes "${REC_N:-0}" --arg records_sha "$REC_SHA" \
       '.env.packed_at=(.env.packed_at // .env.carried_at // .created_at) |
        .env.carried_at=$at |
        .env.carried=true |
        .created_at=$at | .run_id=$run | .commit=$commit | .split_size=$split |
        .targets=(if $carry==1 then (.targets + {carried_at:$at, carried:true}) else {volumes:$targets_volumes, bytes:$targets_bytes, sha256:$targets_sha, mode:$tgt_mode, fp:$tgt_fp} end) |
        (if $rec_ok==1 then .records={volumes:$records_volumes, bytes:$records_bytes, sha256:$records_sha} else del(.records) end)' \
       "$OUT/meta.env-carry.json" > "$OUT/meta.json" 2>/dev/null \
    && [ -s "$OUT/meta.json" ] && jq -e '(.env.bytes // 0) > 0' "$OUT/meta.json" >/dev/null 2>&1; then
    mkdir -p "$OUT/stage"
    for f in "$OUT"/records.tar.gz.* "$OUT/meta.json"; do
      [ -f "$f" ] || continue
      cp -f "$f" "$OUT/stage/stage-$(basename "$f")"
    done
    if [ "${CARRY:-0}" != 1 ]; then
      for f in "$OUT"/targets.tar.gz.*; do
        [ -f "$f" ] || continue
        cp -f "$f" "$OUT/stage/stage-$(basename "$f")"
      done
    fi
    stage_ok=0
    if upload_par "$OUT"/stage/* || gh release upload "$ENV_TAG" "$OUT"/stage/* --repo "$SESSIONS_REPO" --clobber >/dev/null 2>&1; then
      stage_ok=1
      for f in "$OUT"/stage/stage-*; do
        n=$(basename "$f"); l=$(stat -c%s "$f")
        r=$(gh release view "$ENV_TAG" --repo "$SESSIONS_REPO" --json assets --jq ".assets[] | select(.name==\"$n\") | .size")
        if [ "$l" = "$r" ]; then
          echo "staged ok $n = $l bytes"
        else
          stage_ok=0
          echo "::warning::staged size mismatch $n ($l vs $r)"
        fi
      done
    else
      echo "::warning::staged upload failed; the previous packages are left untouched"
    fi
    if [ "$stage_ok" -eq 1 ]; then
      if [ "${CARRY:-0}" = 1 ]; then
        DELPAT='^records\.tar\.gz(\.|$)|^meta\.json$'
      else
        DELPAT='^records\.tar\.gz(\.|$)|^targets\.tar\.gz(\.|$)|^meta\.json$'
      fi
      mapfile -t DELOLD < <(gh release view "$ENV_TAG" --repo "$SESSIONS_REPO" --json assets --jq '.assets[].name' 2>/dev/null \
        | grep -E "$DELPAT" || true)
      for a in ${DELOLD[@]+"${DELOLD[@]}"}; do
        gh release delete-asset "$ENV_TAG" "$a" --repo "$SESSIONS_REPO" -y >/dev/null 2>&1 &
      done
      wait
      UPF=()
      for f in "$OUT"/records.tar.gz.*; do [ -f "$f" ] && UPF+=("$f"); done
      if [ "${CARRY:-0}" != 1 ]; then
        for f in "$OUT"/targets.tar.gz.*; do [ -f "$f" ] && UPF+=("$f"); done
      fi
      up_ok=1
      if [ "${#UPF[@]}" -gt 0 ]; then
        upload_par "${UPF[@]}" || gh release upload "$ENV_TAG" "${UPF[@]}" --repo "$SESSIONS_REPO" --clobber >/dev/null 2>&1 || up_ok=0
      else
        up_ok=0
      fi
      if [ "$up_ok" = 1 ]; then
        if [ -s "$OUT/meta.json" ]; then
          gh release upload "$ENV_TAG" "$OUT/meta.json" --repo "$SESSIONS_REPO" --clobber >/dev/null 2>&1 \
            || echo "::warning::failed to upload meta.json (readers will fall back to unverified extract)"
        fi
        if [ "${CARRY:-0}" = 1 ]; then
          echo "target workspace package carried (unchanged); records refreshed"
        else
          echo "target workspace package updated (env from env-sync branch; retained release env kept as fallback)"
        fi
        echo "package manifest: split=$SPLIT_SIZE env=carried targets=$TGT_N vol carry=${CARRY:-0} records=$REC_N vol"
      else
        echo "::warning::failed to upload targets/records packages to release"
      fi
      for f in "$OUT"/stage/stage-*; do
        gh release delete-asset "$ENV_TAG" "$(basename "$f")" --repo "$SESSIONS_REPO" -y >/dev/null 2>&1 \
          && echo "staged copy removed: $(basename "$f")" &
      done
      wait
    fi
  else
    echo "::warning::meta rewrite failed; leaving the release untouched (targets stay previous generation)"
  fi
else
  echo "::warning::environment package is empty"
fi
echo "snapshot timing: publish $(( $(date +%s) - UP_T0 ))s, total $(( $(date +%s) - SNAP_T0 ))s"
# R2576 (D9): report the complete non-opencode wall time for this run:
# setup (job start → OpenCode start) + post-run (failure policy +
# relay + notify + snapshot). Target <60s.
POST_T0="${POST_OPENCODE_T0:-0}"
OPEN_START_T0="${OPENCODE_START_T0:-0}"
if [ "$POST_T0" -gt 0 ] 2>/dev/null && [ "$OPEN_START_T0" -gt 0 ] 2>/dev/null \
   && [ -n "${PRE_OPENCODE_T0:-}" ]; then
  PRE_S=$(( OPEN_START_T0 - PRE_OPENCODE_T0 ))
  POST_S=$(( $(date +%s) - POST_T0 ))
  TOTAL_S=$(( PRE_S + POST_S ))
  echo "non-opencode timing: total ${TOTAL_S}s (setup ${PRE_S}s + post-run ${POST_S}s; target <60s)"
  if [ "$TOTAL_S" -gt 60 ]; then
    echo "::warning::non-opencode CI time ${TOTAL_S}s exceeds the 60s target (setup ${PRE_S}s + post-run ${POST_S}s)"
  fi
else
  echo "::warning::non-opencode timing unavailable (missing PRE_OPENCODE_T0/OPENCODE_START_T0/POST_OPENCODE_T0)"
fi
rm -rf "$OUT"
