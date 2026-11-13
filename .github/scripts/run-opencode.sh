#!/usr/bin/env bash
# R2631 (operator: "ci日志的格式很混乱"): moved out of iterate.yml.
# GitHub Actions echoes every inline `run:` block into the job log; these six
# blocks alone were most of a round's log. Keeping the logic in a file makes the
# log show only real output. Behavior is unchanged: the step invokes
# `bash -e <file>`, matching the previous default shell.
set +e
# R2631 (operator: "ci日志的格式很混乱"): shared formatting helpers for
# the post-run diagnostics. Sections keep the evidence scannable;
# clip bounds TUI/stack-trace lines that would otherwise wrap.
section() { printf '\n== %s ==\n' "$*"; }
clip() { cut -c1-240; }
# R2576 (D9): stamp the OpenCode phase so the snapshot step can report
# the real non-opencode wall time (setup + post-run) instead of only
# the setup half. OPENCODE_START_T0 is the boundary between the two.
echo "OPENCODE_START_T0=$(date +%s)" >> "$GITHUB_ENV"
RUN_LOG="$RUNNER_TEMP/opencode-run.log"
EGRESS_DIR="${EGRESS_STATE_DIR:-$RUNNER_TEMP/egress}"
export EGRESS_STATE_DIR="$EGRESS_DIR"
export EGRESS_LOCAL_PORT="${EGRESS_LOCAL_PORT:-8089}"
mkdir -p "$EGRESS_DIR"
PROXY_PID=""
WATCH_PID=""
PROXY_READY=0
cleanup_egress() {
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null
    wait "$WATCH_PID" 2>/dev/null
  fi
  if [ -n "$PROXY_PID" ]; then
    kill "$PROXY_PID" 2>/dev/null
    wait "$PROXY_PID" 2>/dev/null
  fi
}
trap cleanup_egress EXIT
# R2575 (D8): the old `else` branch treated a missing handoff as
# "direct connection" and started OpenCode with no proxy at all. Since
# selection always writes the handoff before this step, absence means
# selection/handoff failed: end the round instead of silently burning
# the runner IP's quota.
if [ ! -s "$RUNNER_TEMP/exit-proxy.env" ]; then
  echo "::error::egress handoff $RUNNER_TEMP/exit-proxy.env is missing; refusing to start OpenCode without a verified egress (no direct fallback)"
  exit 1
fi
# R2575 (D8): the watcher proves provider=selected using this state
# file; if it is missing the startup path check is skipped entirely.
if [ ! -s "$HOME/.config/opencode/exit-proxy.json" ]; then
  echo "::error::egress state $HOME/.config/opencode/exit-proxy.json is missing; refusing to start OpenCode without a verifiable egress (no direct fallback)"
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "$RUNNER_TEMP/exit-proxy.env"
set +a
if [ -z "${HTTPS_PROXY:-}" ] || [ -z "${HTTP_PROXY:-}" ]; then
  echo "::error::egress handoff $RUNNER_TEMP/exit-proxy.env is incomplete (HTTP(S)_PROXY unset); refusing to start OpenCode without a verified egress (no direct fallback)"
  exit 1
fi
if [ ! -s "$EGRESS_DIR/upstream" ]; then
  echo "::error::egress upstream $EGRESS_DIR/upstream is missing; refusing to start OpenCode without a verified egress (no direct fallback)"
  exit 1
fi
python3 "$GITHUB_WORKSPACE/.github/scripts/egress-proxy.py" \
  > "$EGRESS_DIR/proxy.log" 2>&1 &
PROXY_PID=$!
for _ in $(seq 1 12); do
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then break; fi
  if curl -sS -m 4 -x "http://127.0.0.1:${EGRESS_LOCAL_PORT}" \
       -o /dev/null https://opencode.ai/cdn-cgi/trace 2>/dev/null; then
    PROXY_READY=1
    break
  fi
  sleep 0.25
done
if [ "$PROXY_READY" = 1 ]; then
  echo "egress proxy: ${HTTPS_PROXY:-none} kind=$(jq -r '.kind // "?"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null) upstream=$(cat "$EGRESS_DIR/upstream" 2>/dev/null || echo '?') egress=$(jq -r '.egress_ip // "?"' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null)"
  bash "$GITHUB_WORKSPACE/.github/scripts/egress-watch.sh" "$RUN_LOG" \
    >> "$EGRESS_DIR/watch.log" 2>&1 &
  WATCH_PID=$!
  # R2575 (D8): a watcher that dies at startup leaves the round with
  # no quota/failure monitoring. Its own pre-start rejection is
  # handled by the stop marker below; any other early exit is fatal.
  sleep 1
  if ! kill -0 "$WATCH_PID" 2>/dev/null && [ ! -f "$EGRESS_DIR/stop" ]; then
    echo "::error::egress watcher exited during startup without a stop marker; refusing to run OpenCode unmonitored"
    tail -20 "$EGRESS_DIR/watch.log" 2>/dev/null || true
    exit 1
  fi
else
  # R2567 (operator): a failed local proxy must not silently fall
  # back to direct; otherwise the run burns the runner IP's quota
  # while the logs still claim a relay was selected.
  echo "::error::local egress proxy is not ready (no provider trace through it); refusing direct fallback and ending this run"
  tail -20 "$EGRESS_DIR/proxy.log" 2>/dev/null || true
  exit 1
fi
# R2618: no default per-round timeout. The old 600s budget killed a
# healthy, still-working turn every 10 minutes and relayed a new run.
# 0 = run until OpenCode exits or the egress watcher sees a verified
# quota 429 (R2620: the first one ends the round); the job-level
# timeout-minutes: 360 remains the hard safety cap.
BUDGET="${BUDGET_SECONDS:-0}"
SID=""
# Option C receives the exact session this run opens, so it never
# guesses a different front/pinned target from restored state.
RESUME_SID=""
if [ -f "$HOME/.config/opencode/tg-chats.json" ]; then
  SID=$(jq -r '.front // empty' "$HOME/.config/opencode/tg-chats.json" 2>/dev/null || true)
fi
# R2513: session presence probe. Uses the sqlite3 CLI (present on
# ubuntu-latest) instead of an inline Python heredoc — a heredoc whose
# contents are column-0 inside `run: |` breaks YAML parsing.
SID_PRESENT="n/a"
DB="$HOME/.local/share/opencode/opencode.db"
if [ -n "$SID" ] && [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  TABLES=$(sqlite3 "$DB" ".tables" 2>/dev/null || echo "")
  if echo " $TABLES " | grep -qw session_v2; then
    HIT=$(sqlite3 "$DB" "SELECT 1 FROM session_v2 WHERE id = '$SID' LIMIT 1" 2>/dev/null || true)
    [ "$HIT" = "1" ] && SID_PRESENT="yes" || SID_PRESENT="no"
  elif echo " $TABLES " | grep -qw session; then
    HIT=$(sqlite3 "$DB" "SELECT 1 FROM session WHERE id = '$SID' LIMIT 1" 2>/dev/null || true)
    [ "$HIT" = "1" ] && SID_PRESENT="yes" || SID_PRESENT="no"
  else
    SID_PRESENT="no-table"
  fi
fi
echo "bound session probe: present=$SID_PRESENT"
RECOVER_LINE=""
if { [ "$SID_PRESENT" = "no" ] || [ "$SID_PRESENT" = "no-table" ] || [ -z "$SID" ]; } \
   && [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  TABLES=$(sqlite3 "$DB" ".tables" 2>/dev/null || echo "")
  for tbl in session_message message_v2 message; do
    if echo " $TABLES " | grep -qw "$tbl"; then
      RECOVER_LINE=$(sqlite3 "$DB" "SELECT session_id || ' ' || COUNT(*) FROM $tbl GROUP BY session_id ORDER BY COUNT(*) DESC LIMIT 1" 2>/dev/null || true)
      [ -n "$RECOVER_LINE" ] && break
    fi
  done
fi
RECOVER="${RECOVER_LINE%% *}"
RECOVER_MSGS="${RECOVER_LINE##* }"
[ -z "$RECOVER_MSGS" ] && RECOVER_MSGS="0"
echo "recovery probe: recover=$([ -n "$RECOVER" ] && echo yes || echo no) msgs=$RECOVER_MSGS"
if [ -n "$SID" ] && [ "$SID_PRESENT" = "yes" ]; then
  ARGS=(--standalone --session "$SID")
  RESUME_SID="$SID"
  echo "resuming bound session present_in_db=$SID_PRESENT"
elif [ -n "$SID" ] && [ "$SID_PRESENT" != "no" ] && [ "$SID_PRESENT" != "no-table" ]; then
  ARGS=(--standalone --session "$SID")
  RESUME_SID="$SID"
  echo "resuming pinned session (db unreadable, present_in_db=$SID_PRESENT)"
elif [ -n "$RECOVER" ]; then
  ARGS=(--standalone --session "$RECOVER")
  RESUME_SID="$RECOVER"
  echo "recovery: bound absent (present_in_db=$SID_PRESENT); pinned the richest restored session (msgs=$RECOVER_MSGS)"
else
  ARGS=(--standalone --continue)
  RESUME_SID=""
  if [ -n "$SID" ]; then
    echo "bound session absent (present_in_db=$SID_PRESENT); no richer session to recover; falling back to --continue"
  else
    echo "no bound session found; continuing the last session"
  fi
fi
# Option C (resume-once-v2 plugin): arm one post-restart continuation
# per interrupted session. R2624 (operator: "ses_e2d48872怎么没有跨ci接力"):
# the old block armed only RESUME_SID (the single session this run
# opens), so another bot's interrupted turn was never even evaluated.
# Arm every registered bot's persisted front/pinned target; the plugin
# still applies its per-session gates (halted / loop-off / active loop /
# quota tail) independently, so this widens coverage without forcing a
# resume. Default on.
RESUME_ONCE_ENABLED=1
if printf '%s' "${CI_RESUME_ONCE:-1}" | grep -qiE '^(0|false|no|off)$'; then
  RESUME_ONCE_ENABLED=0
fi
resume_front_of() {
  local st="$1" sid=""
  sid=$(jq -r '.front // empty' "$st" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid"; return 0 ;; esac
  sid=$(jq -r '.pinned // empty' "$st" 2>/dev/null || true)
  case "$sid" in ses_*) printf '%s' "$sid" ;; esac
}
RESUME_ONCE_LIST="$RESUME_SID"
RESUME_ONCE_SIDS=""
if [ "$RESUME_ONCE_ENABLED" = "1" ]; then
  # Keep the bot registry's order (first entry = tg-chats.json, the
  # rest = tg-chats-<id>.json), matching auto-continue's discovery.
  _bots_json="$HOME/.config/opencode/tg-bots.json"
  if [ -f "$_bots_json" ] && command -v jq >/dev/null 2>&1; then
    _first_bot=1
    while IFS= read -r _botid; do
      [ -n "$_botid" ] || continue
      # Same convention as auto-continue.resolveExtraTargetPaths:
      # the first registry entry owns tg-chats.json, the rest own
      # tg-chats-<id>.json.
      if [ "$_first_bot" = "1" ]; then
        _state="$HOME/.config/opencode/tg-chats.json"
        _first_bot=0
      else
        _state="$HOME/.config/opencode/tg-chats-${_botid}.json"
      fi
      [ -f "$_state" ] || continue
      _sid=$(resume_front_of "$_state")
      if [ -n "$_sid" ]; then
        RESUME_ONCE_LIST="${RESUME_ONCE_LIST:+$RESUME_ONCE_LIST,}$_sid"
      fi
    done < <(jq -r '.bots[]?.id // empty' "$_bots_json" 2>/dev/null || true)
  else
    # Registry missing/unreadable: fall back to every persisted bot
    # state file. Globbing tg-chats*.json also covers the primary.
    for _state in "$HOME"/.config/opencode/tg-chats.json "$HOME"/.config/opencode/tg-chats-*.json; do
      [ -f "$_state" ] || continue
      _sid=$(resume_front_of "$_state")
      if [ -n "$_sid" ]; then
        RESUME_ONCE_LIST="${RESUME_ONCE_LIST:+$RESUME_ONCE_LIST,}$_sid"
      fi
    done
  fi
  # Deduplicate (bots may share a front), preserving first-seen order.
  RESUME_ONCE_SIDS=$(printf '%s\n' "$RESUME_ONCE_LIST" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)
fi
if [ "$RESUME_ONCE_ENABLED" = "1" ] && [ -n "$RESUME_ONCE_SIDS" ]; then
  export RESUME_ONCE_SIDS
  echo "option C resume-once armed: $RESUME_ONCE_SIDS"
else
  export RESUME_ONCE_SIDS=""
  if [ "$RESUME_ONCE_ENABLED" = "1" ]; then
    echo "option C resume-once skipped: no explicit session (--continue path)"
  else
    echo "option C resume-once disabled by CI_RESUME_ONCE=${CI_RESUME_ONCE:-}"
  fi
fi
# R2622 (operator: "200-429测试有没有进一步优化"): zero-message gateway
# preflight. The local proxy is already pointed at the selected
# upstream. Send a deliberately malformed JSON body to the exact
# completion endpoint: the gateway rejects it with 400 before any
# model call, so this spends NO free message. It proves the selected
# path reaches the real inference gateway. R2625 live finding: the
# gateway validates the body BEFORE quota, so this probe returned 400
# at 05:54:44 while the real turn 429'd at 05:55:08 (24s later). The
# 429 branch below is a safety net, not a quota oracle. The first real
# turn remains the authoritative quota test; a round-end R2625
# zengate probe answers whether the quota is path-specific.
if [ ! -f "$EGRESS_DIR/stop" ] && [ "${EGRESS_GATEWAY_PREFLIGHT:-1}" != "0" ]; then
  GWMETA="$EGRESS_DIR/gateway-preflight.meta"
  GWERR="$EGRESS_DIR/gateway-preflight.err"
  rm -f "$GWMETA" "$GWERR"
  GWOUT=$(EGRESS_GATEWAY_META="$GWMETA" \
    bash "$GITHUB_WORKSPACE/.github/scripts/egress-preflight-gateway.sh" 8 2>"$GWERR" || true)
  GWCODE=${GWOUT%%$'\t'*}
  GWWHY=${GWOUT##*$'\t'}
  [ -n "$GWCODE" ] || GWCODE=000
  [ -n "$GWWHY" ] || GWWHY=transport
  GWRA=$(sed -n 's/^retry_after=//p' "$GWMETA" 2>/dev/null | head -1)
  echo "gateway preflight (0 messages): code=$GWCODE reason=$GWWHY${GWRA:+ retry_after=${GWRA}s}"
  if [ "$GWWHY" = "quota" ]; then
    GWUP=$(cat "$EGRESS_DIR/upstream" 2>/dev/null || echo '?')
    printf '%s\n' "quota 429 on the selected egress during zero-message gateway preflight (upstream=$GWUP, retry_after=${GWRA:-?}s); ending this round before OpenCode spends a real message" > "$EGRESS_DIR/stop"
    # Keep the candidate out of the next selection for the provider's
    # reset window. This mirrors egress-watch.sh blacklist_selected;
    # direct keys are runner-IP scoped, relay/http keys are the
    # upstream entry.
    if [ -s "$HOME/.config/opencode/exit-proxy.json" ]; then
      # egress-lib.sh sets -u; keep that from leaking into the rest
      # of this step (which relies on set +e and optional vars).
      (
        set -uo pipefail
        # shellcheck source=egress-lib.sh
        . "$GITHUB_WORKSPACE/.github/scripts/egress-lib.sh"
        egress_bl_init
        _kind=$(jq -r '.kind // ""' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null || true)
        _dip=$(jq -r '.direct_ip // ""' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null || true)
        _eg=$(jq -r '.egress_ip // ""' "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null || true)
        case "$_kind" in
          direct) _key="direct:${_dip:-unknown}" ;;
          relay|http) _key="$GWUP" ;;
          *) _key="" ;;
        esac
        if [ -n "$_key" ]; then
          _ttl=21600
          if [ -n "$GWRA" ] && [ "$GWRA" -gt "$_ttl" ] 2>/dev/null; then _ttl="$GWRA"; fi
          egress_bl_add "$_key" "$_eg" "quota-after-gateway-preflight" "$_ttl" || true
          echo "gateway preflight blacklisted $_key for ${_ttl}s (retry_after=${GWRA:-?}s)"
        fi
      )
    fi
  elif [ "$GWWHY" != "ok" ]; then
    echo "::warning::zero-message gateway preflight code=$GWCODE reason=$GWWHY; continuing to the real turn (the watcher handles transport/quota)"
  fi
fi
if [ -f "$EGRESS_DIR/stop" ]; then
  # R2567: the watcher can reject the selected path before OpenCode is
  # even started (provider traffic bypassed the relay / relay rotated).
  # pkill cannot catch a not-yet-started process, so honor the marker
  # here and never start an unmonitored round.
  echo "::error::egress watcher rejected the selected path before the round started: $(tr '\n' ' ' < "$EGRESS_DIR/stop" 2>/dev/null | cut -c1-300)"
  RC=0
else
  if [ "${BUDGET:-0}" -gt 0 ] 2>/dev/null; then
    # Explicit operator budget only; the default is 0 (no timeout).
    TERM=xterm-256color timeout --signal=TERM --kill-after=30s "$BUDGET" \
      opencode "${ARGS[@]}" --print-logs </dev/null >"$RUN_LOG" 2>&1
  else
    TERM=xterm-256color opencode "${ARGS[@]}" --print-logs </dev/null >"$RUN_LOG" 2>&1
  fi
  RC=$?
fi
if [ -f "$EGRESS_DIR/stop" ]; then
  STOP_REASON=$(tr '\n' ' ' < "$EGRESS_DIR/stop" 2>/dev/null | cut -c1-300)
  echo "watcher_stop=true" >> "$GITHUB_OUTPUT"
  echo "watcher_reason=${STOP_REASON:-unknown}" >> "$GITHUB_OUTPUT"
  # R2596/R2620: an egress quota stop is external (free-tier usage
  # limit), not a content/code failure. It must not count toward the
  # content-failure pause: failure_guard treats it as an egress-only
  # round and relays immediately. The general no-healthy-turn guard
  # still pauses after 3 such rounds.
  if printf '%s' "$STOP_REASON" | grep -qiE 'quota|free[- ]limit|FreeUsageLimitError|provider\.free-limit'; then
    echo "egress_quota_stop=true" >> "$GITHUB_OUTPUT"
  fi
  # R2620 (operator: "改为出现一个429就重启吧"): a single verified
  # quota 429 is an egress-only round and must relay immediately. Do
  # not pause the loop here; the general 3-rounds-without-a-healthy-turn
  # guard still applies. Do not match the watcher's old 3-429 wording.
  # R2535：watcher 是进程外停止，不能一律按失败计。auto-continue 在首个
  # 正常 assistant 回合写该标记；有 200 的轮次必须清零 streak（运营者规则：
  # 只有连续 3 轮没有任何 200 才停循环）。
  if [ -f "$RUNNER_TEMP/round-had-success" ]; then
    echo "round_success=true" >> "$GITHUB_OUTPUT"
    echo "::notice::egress watcher ended this round after a healthy turn; CI_FAIL_STREAK will reset"
  else
    echo "round_success=false" >> "$GITHUB_OUTPUT"
  fi
  echo "::warning::egress watcher ended this round: ${STOP_REASON:-unknown}; relay policy decides whether to pause"
  RC=0
elif [ -f "$RUNNER_TEMP/round-end.json" ]; then
  # R2521: auto-continue END-ROUND-CI writes this marker. It used to exit 0
  # silently, so failure_guard treated the round as a success and reset
  # CI_FAIL_STREAK forever. The marker carries whether any healthy turn ran.
  STOP_REASON=$(jq -r '.reason // "auto-continue ended the round"' "$RUNNER_TEMP/round-end.json" 2>/dev/null || echo "auto-continue ended the round")
  ROUND_SUCCESS=$(jq -r '.success // false' "$RUNNER_TEMP/round-end.json" 2>/dev/null || echo false)
  echo "watcher_stop=true" >> "$GITHUB_OUTPUT"
  echo "watcher_reason=auto-continue: ${STOP_REASON}" >> "$GITHUB_OUTPUT"
  echo "round_success=${ROUND_SUCCESS}" >> "$GITHUB_OUTPUT"
  if printf '%s' "$STOP_REASON" | grep -qiE 'quota|free[- ]limit|FreeUsageLimitError|provider\.free-limit'; then
    echo "egress_quota_stop=true" >> "$GITHUB_OUTPUT"
  fi
  # R2620 (operator: "改为出现一个429就重启吧"): a single verified
  # quota 429 is an egress-only round and must relay immediately. Do
  # not pause the loop here; the general 3-rounds-without-a-healthy-turn
  # guard still applies. Do not match the watcher's old 3-429 wording.
  echo "::warning::auto-continue ended this round: ${STOP_REASON} (round_success=${ROUND_SUCCESS}); relay policy decides whether to pause"
  RC=0
fi
# R2628 (operator: "改为探测当前出口，因为探测新出口没有意义"): a
# fresh alternate always has quota, so R2625's direct->relay probe
# returned 200 on every round and carried no signal. Re-probe the
# SAME egress the round used (direct -> the same runner IP, relay ->
# the same relay entry). Diagnostic only: it never changes selection,
# the stop reason, or the relay policy.
# R2629 (operator: "如果探测为200就不停止本轮"): egress-watch.sh runs
# this probe BEFORE stopping and keeps the round on 200. Skip this
# post-stop fallback when the live probe already wrote its meta.
if [ "${EGRESS_QUOTA_PROBE:-1}" != "0" ] \
   && ! grep -qx 'probe_target=current' "$EGRESS_DIR/quota-probe.meta" 2>/dev/null \
   && printf '%s' "${STOP_REASON:-}" | grep -qiE 'quota 429|FreeUsageLimit|provider\.free-limit'; then
  section "quota probe"
  echo "post-stop fallback (live probe did not run)"
  EGRESS_QUOTA_PROBE=1 bash "$GITHUB_WORKSPACE/.github/scripts/egress-quota-probe.sh" \
    2>&1 | tee "$EGRESS_DIR/quota-probe.log" || true
fi
section "opencode result"
echo "exit=$RC lines=$(wc -l < "$RUN_LOG" 2>/dev/null || echo 0)"
# R2587（D7）：插件错误只写 /tmp/opencode/v2plugin.log，run 结束随
# runner 一起消失；旧诊断只 grep OpenCode 主日志，插件注入/桥失败在
# Actions 日志里看不到。这里把插件 error/warn 尾部打印出来。
section "plugin errors/warnings"
if [ -s /tmp/opencode/v2plugin.log ]; then
  PLUGIN_ERR=$(grep -aE '\] (error|warn): ' /tmp/opencode/v2plugin.log 2>/dev/null | tail -10)
  PLUGIN_N=$(printf '%s\n' "$PLUGIN_ERR" | grep -c . 2>/dev/null || true)
  echo "count=${PLUGIN_N:-0} (last 10)"
  [ -n "$PLUGIN_ERR" ] && printf '%s\n' "$PLUGIN_ERR" | clip | sed 's/^/  /'
else
  echo "no plugin log"
fi
ERR_TXT="$RUNNER_TEMP/opencode-errors.txt"
section "opencode errors"
if [ -s "$RUN_LOG" ]; then
  # R2630 (operator: "最后错误显示不对"): the old filter took the first
  # match from a CR-split TUI line. A spinner frame ("测试机器人连通性…")
  # can contain a stray keyword later in the same physical line, so the
  # card showed a truncated progress animation instead of the provider
  # error. It also kept tg-bridge Telegram API 429s and this_run=false
  # entries from old sessions. Keep only lines that describe THIS run's
  # OpenCode/provider failure; tg-bridge errors are printed separately.
  tr '\r' '\n' < "$RUN_LOG" 2>/dev/null \
    | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | grep -aE 'FreeUsageLimit|free usage limit|provider\.free-limit|provider\.transport|level=ERROR|error target=|idle_timeout|"type":"error"|HTTP 429|rate.?limit' \
    | grep -avE 'grep -aE|grep -aoE|grep -aP|ERR_TXT=|opencode-errors\.txt|=== |^[[:space:]]*diag |quota-like' \
    | grep -avP '[\x{2800}-\x{28FF}]' \
    | grep -avE '\[tg-bridge/|\[primary\]|\[bot[0-9]+\]' \
    | grep -av 'this_run=false' \
    > "$ERR_TXT" 2>/dev/null || true
  # R2631: one bounded view instead of printing every line twice.
  echo "total=$(wc -l < "$ERR_TXT" 2>/dev/null || echo 0)"
  if [ -s "$ERR_TXT" ]; then
    echo "top repeated:"
    sed -E 's/\\n.*$//' "$ERR_TXT" | sort | uniq -c | sort -rn | head -10 | clip | sed 's/^/  /'
    echo "last 5:"
    tail -5 "$ERR_TXT" | sed -E 's/\\n.*$//; s/^.*cause="//' | clip | sed 's/^/  /'
  fi
else
  echo "no run log"
fi
section "egress connections"
if [ -s "$EGRESS_DIR/proxy.log" ]; then
  grep -aE 'target=opencode\.ai|epoch [0-9]+:' "$EGRESS_DIR/proxy.log" 2>/dev/null | tail -6 | clip | sed 's/^/  /'
else
  echo "no proxy log"
fi
section "egress watch"
if [ -s "$EGRESS_DIR/watch.log" ]; then
  # R2562：watcher 不再轮换；诊断单轮内的连续失败与停止原因。
  # R2588（D8）：last-40 里常混着“quota-like line ignoring”噪声，先给
  # 一行计数汇总，让 200→429 / 轮换 / 停轮一眼可判。
  # R2631: collapse the repetitive tunnel-open/close lines; keep the
  # failure/stop evidence and a short tunnel tail with byte counts.
  cnt() { local n; n=$(grep -acE "$1" "$EGRESS_DIR/watch.log" 2>/dev/null || true); echo "${n:-0}"; }
  echo "summary: upstream=$(cat "$EGRESS_DIR/upstream" 2>/dev/null || echo '?') path_checks=$(cnt 'egress path check') rechecks=$(cnt 'egress path recheck ok') quota=$(cnt 'quota error detected') failures=$(cnt 'egress failure') blacklisted=$(cnt 'blacklisted') stops=$(cnt 'STOP:') ignored_quota=$(cnt 'ignoring')"
  echo "failures/stops (last 10):"
  grep -aE 'egress failure|STOP:|blacklisted|selected egress answered 200' "$EGRESS_DIR/watch.log" 2>/dev/null | tail -10 | clip | sed 's/^/  /'
  echo "recent signals (last 12, tunnel lines collapsed):"
  grep -avE 'provider connection established \(diagnostic|provider tunnel closed \(close' "$EGRESS_DIR/watch.log" 2>/dev/null | tail -12 | clip | sed 's/^/  /'
  echo "recent tunnels (last 4):"
  grep -aE 'provider (connection established|tunnel (closed|idle))' "$EGRESS_DIR/watch.log" 2>/dev/null | tail -4 | clip | sed 's/^/  /'
else
  echo "no watch log"
fi
section "telegram bridge state"
if [ -s "$HOME/.config/opencode/tg-chats.json" ]; then
  jq -c '{iocount, paused, selfmute, halted:(.halted|length), qlen:((.queue//[])|length), pqlen:((.pinqueue//[])|length)}' "$HOME/.config/opencode/tg-chats.json" 2>/dev/null || echo "unreadable"
else
  echo "no tg-chats.json"
fi
# R2631: `grep -c` prints 0 and exits 1, so the old
# `$(grep -c ... || echo 0)` emitted "0\n0" and every count was
# followed by a bare 0 line. Print one aligned row per pattern.
section "plugin diag counts"
for pat in "pinject delivered" "pinject failed" "inject failed" "getUpdates failed" "loop stopped" "sendMessage chunked ok" "free tier" "FreeUsageLimitError" "provider.free-limit" "instance registered" "turnActuallyIdle" "loop skip" "loopskip"; do
  n=$(grep -c -- "$pat" "$RUN_LOG" 2>/dev/null || true)
  printf '  %-24s %s\n' "$pat" "${n:-0}"
done
echo "exit_code=$RC" >> "$GITHUB_OUTPUT"
if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ] || [ "$RC" -eq 143 ]; then
  # R2618: only an explicitly requested budget can time out. That is a
  # deliberate round boundary, not a failed 429 round: end normally and
  # let the relay policy start the next round.
  echo "opencode hit the explicit budget; ending this round normally."
  echo "budget_timeout=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
if [ "$RC" -ne 0 ]; then
  echo "opencode exited with $RC; this run will not relay."
fi
exit "$RC"
