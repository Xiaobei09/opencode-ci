#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
set +e
bash "$GITHUB_WORKSPACE/.github/scripts/restore-targets.sh" > /tmp/restore-targets.log 2>&1 &
p_t=$!
bash "$GITHUB_WORKSPACE/.github/scripts/restore-env.sh" > /tmp/restore-env.log 2>&1 &
p_e=$!
# R2554: the toolchain install used to be a separate 12s step after the
# restore finished. It only writes $HOME/.opencode/bin (excluded from
# the env snapshot) and the node prefix, so it is safe to run beside
# the two restores; this removes 12s from the pre-opencode budget.
install_toolchain() {
  set -euo pipefail
  # R2520: the opencode.ai installer can transiently 404 while the latest
  # release asset is propagating (run 41143504097 died here and the
  # skipped prerequisite counted toward the 3-strike pause). Retry the
  # whole installer before burning a loop slot.
  installed=0
  for attempt in 1 2 3; do
    if curl -fsSL --retry 2 --retry-delay 2 https://opencode.ai/v2/install | bash; then
      installed=1
      break
    fi
    echo "::warning::opencode install attempt ${attempt}/3 failed"
    if [ "$attempt" -lt 3 ]; then sleep $((attempt * 10)); fi
  done
  if [ "$installed" -ne 1 ]; then
    echo "::error::opencode install failed after 3 attempts (upstream 404?)"
    return 1
  fi
  echo "$HOME/.opencode/bin" >> "$GITHUB_PATH"
  npm install -g workferry zengate@1.3.1
}
install_toolchain > /tmp/install-toolchain.log 2>&1 &
p_i=$!
wait "$p_t"; rc_t=$?
wait "$p_e"; rc_e=$?
wait "$p_i"; rc_i=$?
echo "== restore-targets.log =="
cat /tmp/restore-targets.log 2>/dev/null
echo "== restore-env.log =="
cat /tmp/restore-env.log 2>/dev/null
echo "== install-toolchain.log =="
cat /tmp/install-toolchain.log 2>/dev/null
if [ "$rc_t" != 0 ] || [ "$rc_e" != 0 ] || [ "$rc_i" != 0 ]; then
  echo "::error::parallel setup failed (targets rc=$rc_t env rc=$rc_e toolchain rc=$rc_i)"
  exit 1
fi
for p in "$HOME/.config/opencode"/*.json \
         "$HOME/.config/opencode"/*.env \
         "$HOME/.local/state/opencode/service.json" \
         "$HOME/.opencode"/*.env; do
  [ -f "$p" ] && chmod 600 "$p" 2>/dev/null || true
done
echo "targets, environment and toolchain restored in parallel"
