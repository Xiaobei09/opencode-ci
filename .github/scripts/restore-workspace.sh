#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
#
# R2773 (operator: "上一轮ci的环境还原耗时特别长"): the three tasks used to write
# only to /tmp/restore-*.log and the job log showed nothing until all of them
# finished. When run 44098155757 hung in restore for 164s there was no way to
# tell whether env-sync clone, the 607MB release fallback, the targets slim
# fetch or npm had stalled. Now every task is streamed live with a `[name]`
# prefix, annotations keep their `::warning::`/`::error::` position, a
# heartbeat is printed while a task is silent, and every task has a hard
# wall-clock ceiling so one dead TCP connection cannot hang the step.
set +e
RESTORE_T0=$(date +%s)

declare -A TASK_PID=()
declare -A TASK_T0=()
declare -A TASK_WATCH=()

stream_filter() {  # $1 = task name; keep ::warning::/::error:: at line start
  local name="$1"
  # GitHub only renders an annotation when `::warning::` starts the line, so
  # prefix the message after the marker instead of before it.
  sed -u -E "s/^(::(warning|error|notice|debug)::)/&[${name}] /; t; s/^/[${name}] /"
}

start_task() {  # start_task <name> <log> <command...>
  local name="$1" log="$2"
  shift 2
  TASK_T0["$name"]=$(date +%s)
  echo "[$name] start ($(date -u +%H:%M:%SZ))"
  # pipefail makes the subshell return the task's status, not sed/tee's.
  ( set -o pipefail; "$@" 2>&1 | stream_filter "$name" | stdbuf -oL tee "$log" ) &
  TASK_PID["$name"]=$!
  (
    while kill -0 "${TASK_PID[$name]}" 2>/dev/null; do
      sleep 15
      kill -0 "${TASK_PID[$name]}" 2>/dev/null || break
      # R2793：只报“still running 75s”无法区分慢速下载与卡死。把该任务日志的
      # 最后一行附上（fetch-asset 每 10s/每个 range 都会更新进度）。
      last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' | cut -c1-180)
      echo "[$name] still running $(( $(date +%s) - ${TASK_T0[$name]} ))s${last:+ · last: $last}"
    done
  ) &
  TASK_WATCH["$name"]=$!
}

finish_task() {  # finish_task <name> -> task rc
  local name="$1" rc
  wait "${TASK_PID[$name]}"
  rc=$?
  if [ -n "${TASK_WATCH[$name]:-}" ]; then
    kill "${TASK_WATCH[$name]}" 2>/dev/null
    wait "${TASK_WATCH[$name]}" 2>/dev/null
  fi
  local elapsed=$(( $(date +%s) - ${TASK_T0[$name]} ))
  # R2802（CI 侧）：失败时把最后一行进度带进注释。此前超时只报“exceeded”，
  # 普通失败只在日志尾部有一行 `done rc=...`，运营者看到的是笼统的“还原失败”。
  local last=""
  last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' | cut -c1-300)
  if [ "$rc" = 124 ]; then
    echo "::error::[$name] exceeded its hard timeout after ${elapsed}s${last:+ · last: $last}; refusing to boot OpenCode with a half-restored environment"
  elif [ "$rc" != 0 ]; then
    echo "::error::[$name] failed rc=$rc after ${elapsed}s${last:+ · last: $last}; refusing to boot OpenCode with a half-restored environment"
  fi
  echo "[$name] done rc=$rc in ${elapsed}s"
  return "$rc"
}

# R2554: the toolchain install used to be a separate 12s step after the
# restore finished. It only writes $HOME/.opencode/bin (excluded from
# the env snapshot) and the node prefix, so it is safe to run beside
# the two restores; this removes 12s from the pre-opencode budget.
install_toolchain() {
  set -euo pipefail
  local t_all t_step
  t_all=$(date +%s)
  # R2520: the opencode.ai installer can transiently 404 while the latest
  # release asset is propagating (run 41143504097 died here and the
  # skipped prerequisite counted toward the 3-strike pause). Retry the
  # whole installer before burning a loop slot.
  #
  # R2773: curl used to have no connect/max time, so a stalled TLS handshake
  # held the whole parallel restore open forever. Bound each attempt.
  installed=0
  for attempt in 1 2 3; do
    t_step=$(date +%s)
    if timeout --signal=TERM --kill-after=15 "${TOOLCHAIN_INSTALL_TIMEOUT:-150}" \
         bash -c 'set -o pipefail; curl -fsSL --connect-timeout 15 --max-time 120 \
                    --retry 2 --retry-delay 2 https://opencode.ai/v2/install | bash'; then
      installed=1
      echo "opencode installer ok in $(( $(date +%s) - t_step ))s (attempt ${attempt}/3)"
      break
    fi
    echo "::warning::opencode install attempt ${attempt}/3 failed/timed out after $(( $(date +%s) - t_step ))s"
    if [ "$attempt" -lt 3 ]; then sleep $((attempt * 10)); fi
  done
  if [ "$installed" -ne 1 ]; then
    echo "::warning::opencode install failed after 3 attempts (upstream 404/network stall?)"
    return 1
  fi
  echo "$HOME/.opencode/bin" >> "$GITHUB_PATH"
  t_step=$(date +%s)
  # npm can also sit on a dead socket; give it a bounded window and surface a
  # real warning instead of letting the parallel `wait` hang.
  if ! timeout --signal=TERM --kill-after=15 "${NPM_INSTALL_TIMEOUT:-300}" \
       npm install -g workferry zengate@1.3.1; then
    echo "::warning::npm install failed/timed out after $(( $(date +%s) - t_step ))s"
    return 1
  fi
  echo "toolchain ready in $(( $(date +%s) - t_all ))s"
}

# Hard ceilings are the safety net behind the per-operation timeouts inside
# restore-env/restore-targets. A timeout returns 124 and the step fails closed
# (OpenCode is skipped, so a partial environment cannot be saved back).
start_task targets /tmp/restore-targets.log \
  timeout --signal=TERM --kill-after=15 "${RESTORE_TARGETS_DEADLINE:-480}" \
  bash "$GITHUB_WORKSPACE/.github/scripts/restore-targets.sh"
start_task env /tmp/restore-env.log \
  timeout --signal=TERM --kill-after=15 "${RESTORE_ENV_DEADLINE:-600}" \
  bash "$GITHUB_WORKSPACE/.github/scripts/restore-env.sh"
start_task toolchain /tmp/install-toolchain.log install_toolchain

rc_t=0; finish_task targets || rc_t=$?
rc_e=0; finish_task env || rc_e=$?
rc_i=0; finish_task toolchain || rc_i=$?
if [ "$rc_t" != 0 ] || [ "$rc_e" != 0 ] || [ "$rc_i" != 0 ]; then
  # R2752: restore-targets.sh now tolerates a stale index fingerprint only
  # after verifying the extracted tree against the sha-verified package, so a
  # nonzero rc here is a real failure. Exiting 0 would mark the step success
  # and let the save gate overwrite good snapshots with a partial tree.
  echo "::warning::parallel setup failed (targets rc=$rc_t env rc=$rc_e toolchain rc=$rc_i)"
  exit 1
fi
# R2766: a previous round can be killed between the bridge claiming a rollover
# request (rename to `ses_*.json.claimed-*`) and failure_guard recovering it, so
# the snapshot may contain only the claimed name. The bridge scans base names
# only; put the request back before OpenCode starts instead of waiting a full
# extra round. No bridge is running yet, so the claim is definitely orphaned.
bash "$GITHUB_WORKSPACE/.github/scripts/recover-rollover-claims.sh" || true
for p in "$HOME/.config/opencode"/*.json \
         "$HOME/.config/opencode"/*.env \
         "$HOME/.local/state/opencode/service.json" \
         "$HOME/.opencode"/*.env; do
  [ -f "$p" ] && chmod 600 "$p" 2>/dev/null || true
done
echo "targets, environment and toolchain restored in parallel in $(( $(date +%s) - RESTORE_T0 ))s"
