#!/usr/bin/env bash
# Select the initial egress for this CI run and write a local-proxy handoff.
#
# Every candidate is tested by zengate: the real OpenCode CLI runs one fresh
# session per candidate through a candidate-specific local CONNECT proxy. This
# avoids treating a synthetic curl 429 as proof that the IP is exhausted.
#
# R2562 (operator): the egress is selected ONCE here for the whole run. The
# watcher no longer rotates. Probe the candidate pool until one answers 200;
# there is no quota-based early stop.
#
# R2582 (operator rollback + root cause): direct is candidate #1 and must stay
# enabled. The free provider returns FreeUsageLimitError (HTTP 429,
# retryAfter≈16h) per EGRESS IP bucket; a fresh runner direct IP is a fresh
# bucket, while shared proxyip relay exits are reused across runs and often
# already exhausted. Forcing relay therefore reproduces "preflight 200, then
# the real request immediately 429". Never disable direct or put relays first.
#
# R2617 (operator: "回退的出口数量不要限制"): fallback exits are unlimited by
# default (EGRESS_RELAY_FALLBACK_MAX=0); -1 disables relay fallback. The
# selection budget (EGRESS_SELECT_BUDGET) is still honored to prevent a
# pathological loop, and the candidate list itself is finite.
#
# R2617 (operator: "200 暂不处理" + rollback of the R2598 design): the
# real-turn-sized inference probe is OFF by default (EGRESS_BIG_PROBE=1 opts
# in). The free tier meters MESSAGES, so every inference probe consumes one of
# the messages the real turn needs — a 200 probe can itself cause the next real
# turn to 429. The small nonce probe verifies that the request really traverses
# the candidate exit (PATH); the first real turn verifies the QUOTA. A
# preflight 200 is therefore logged as "path verified", never as "quota
# proven". If the real turn 429s, the watcher blacklists that exit.
#
# Outputs:
#   $RUNNER_TEMP/egress/upstream        direct | relay:ip:port | http:host:port
#   $RUNNER_TEMP/egress/candidates.tsv  ordered candidates (diagnostics only;
#                                       direct + proxyip relays; public HTTP
#                                       only with EGRESS_ALLOW_PUBLIC_HTTP=1)
#   $RUNNER_TEMP/exit-proxy.env         HTTP_PROXY=http://127.0.0.1:8089
#   $HOME/.config/opencode/exit-proxy.json
#   $HOME/.config/opencode/egress-blacklist.json (persisted, 0600)
#   $HOME/.config/opencode/egress-usage.json     (persisted, 0600; 13h success history)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-$RUNNER_TEMP/egress}"
export EGRESS_STATE_DIR
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

# R2511: probe the same model the agent really uses (see egress_probe_model).
export EGRESS_PROBE_MODEL="${EGRESS_PROBE_MODEL:-$(egress_probe_model)}"

mkdir -p "$EGRESS_STATE_DIR"
: > "$EGRESS_CANDIDATES_FILE"
echo 0 > "$EGRESS_EPOCH_FILE"
egress_bl_init
egress_bl_prune
# R2565: remember recently selected relays/IPs across runs. The free bucket is
# per egress IP; a tiny preflight 200 does not prove enough quota remains for
# the resumed (large-context) session. Prefer a relay not used in the last
# EGRESS_REUSE_WINDOW (13h default); fall back to a used one only if every fresh
# candidate fails.
egress_usage_init
egress_usage_prune
egress_usage_seed_previous

# R2562 (operator): probe until a 200 is found. SELECT_MAX=0 means no cap;
# SELECT_BUDGET=0 means no wall-clock cap. Keep the ordered candidate list and
# stop immediately on the first real preflight success. A 200 from zengate is
# still re-checked for egress stickiness below, because some relays rotate the
# egress IP on every CONNECT (the operator-reported "200 then 429").
SELECT_BUDGET="${EGRESS_SELECT_BUDGET:-0}"
SELECT_MAX="${EGRESS_SELECT_MAX:-0}"
PARALLEL="${EGRESS_PARALLEL:-1}"
PREFLIGHT_TMO="${EGRESS_PREFLIGHT_TIMEOUT:-20}"
# A killed probe must not leave its curl/inference child running for the full
# timeout after we already picked a winner; timeout forwards TERM to the child.
PROBE_TIMEOUT=$((PREFLIGHT_TMO + 2))
[ "$PARALLEL" -ge 1 ] 2>/dev/null || PARALLEL=1
[ "$PARALLEL" -le 8 ] 2>/dev/null || PARALLEL=8
START=$(egress_now)

log() { echo "[egress-select] $*"; }

PROBE_ENGINE=curl
# R2598: a fallback verification sends a real-turn-sized context (~100k
# tokens). The gateway needs more than the 20s small-probe budget for a slow
# relay; the selector's per-request curl timeout still caps a hung small probe
# at PREFLIGHT_TMO. 45s is enough for the measured ~7s big request.
if EGRESS_PROBE_REQUEST_TIMEOUT_MS="${EGRESS_PROBE_REQUEST_TIMEOUT_MS:-45000}" \
   bash "$SCRIPT_DIR/egress-probe-server.sh" start; then
  PROBE_ENGINE=zengate
  PARALLEL=1
  log "preflight engine=zengate model=$EGRESS_PROBE_MODEL (real OpenCode, fresh session per candidate)"
  trap 'bash "$SCRIPT_DIR/egress-probe-server.sh" stop' EXIT
else
  log "warning: zengate probe unavailable; falling back to curl preflight"
fi

DIRECT_IP=$(egress_trace_direct)
DIRECT_COLO=$(curl -sS -m 10 --noproxy '*' "$EGRESS_TRACE_URL" 2>/dev/null | awk -F= '/^colo=/{print $2}')
log "direct egress=${DIRECT_IP:-unknown} colo=${DIRECT_COLO:-?}"

# ---- candidate list -------------------------------------------------------
# 1) direct (a fresh runner IP is often the best bucket)
printf 'direct\t-\tdirect\n' >> "$EGRESS_CANDIDATES_FILE"

# 2) proxyip relay entries (non-CF ASN + CF edge ports; --connect-to relays TCP)
RELAY_SOURCE="${EGRESS_RELAY_SOURCE:-all_rep_verified.txt}"
RELAY_URL="https://raw.githubusercontent.com/Xiaobei09/proxyip/main/data/valid/$RELAY_SOURCE"
if curl -fsSL --retry 3 --retry-delay 2 --max-time 90 "$RELAY_URL" -o "$EGRESS_STATE_DIR/relays.txt"; then
  # all_rep_verified is reputation-ordered. Keep the head; dedupe entries.
  head -n 220 "$EGRESS_STATE_DIR/relays.txt" \
    | tr -d '\r' \
    | sed 's/#.*//' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' \
    | awk '!seen[$0]++' \
    | while IFS= read -r hp; do printf 'relay\t%s\tproxyip\n' "$hp"; done \
    >> "$EGRESS_CANDIDATES_FILE"
  log "relay candidates: $(grep -c '^relay' "$EGRESS_CANDIDATES_FILE" || true) from $RELAY_SOURCE"
else
  log "relay source unavailable: $RELAY_URL"
fi

# 3) public HTTP CONNECT proxies are DISABLED by default. They are untrusted,
#    unstable, and can observe SNI metadata. Keep the code behind an explicit
#    opt-in for experiments; production uses direct + proxyip relays only.
if [ "${EGRESS_ALLOW_PUBLIC_HTTP:-0}" = "1" ]; then
  HTTP_SOURCES=(
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt"
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"
    "https://raw.githubusercontent.com/jetkai/proxy-list/main/online-proxies/txt/proxies-http.txt"
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt"
  )
  i=0
  for url in "${HTTP_SOURCES[@]}"; do
    f="$EGRESS_STATE_DIR/http_$i.txt"
    i=$((i + 1))
    if curl -fsSL -m 25 "$url" -o "$f.raw" 2>/dev/null; then
      tr -d '\r' < "$f.raw" | sed 's/#.*//' \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' | sort -u > "$f"
      head -n 80 "$f" | awk '!seen[$0]++' \
        | while IFS= read -r hp; do printf 'http\t%s\thttp-pool\n' "$hp"; done \
        >> "$EGRESS_CANDIDATES_FILE"
      log "http source $(wc -l < "$f") entries ${url}"
    else
      log "http source unavailable: ${url}"
    fi
  done
else
  log "public HTTP proxy pool disabled (set EGRESS_ALLOW_PUBLIC_HTTP=1 to enable)"
fi

# Deduplicate while preserving order.
awk -F'\t' '!seen[$1 FS $2]++' "$EGRESS_CANDIDATES_FILE" > "$EGRESS_CANDIDATES_FILE.tmp" \
  && mv "$EGRESS_CANDIDATES_FILE.tmp" "$EGRESS_CANDIDATES_FILE"
log "candidates: $(wc -l < "$EGRESS_CANDIDATES_FILE")"

# ---- order fresh candidates before recently used ones ---------------------
# R2565 (operator priority): the old code promoted the previous run's relay to
# slot #2. Because the candidate list is otherwise static, every run selected
# the same egress until its free bucket was partially consumed; the tiny
# preflight still answered 200, then the resumed session's large request hit
# the remaining quota (observed 429 retry-after ~12.9h). Never promote the
# previous relay. The recently-used history below moves it to the back.
# (The ranking is applied after the candidate arrays are built.)

# ---- pick the first candidate that passes the real preflight --------------
SELECTED_KIND=""; SELECTED_TARGET=""; SELECTED_SOURCE=""; SELECTED_UP=""; SELECTED_EGRESS=""
# R2566: a direct 429 with a short Retry-After is usually a burst window, not an
# exhausted quota bucket. Retry direct exactly once instead of blacklisting the
# runner IP for 6h (which forces the run onto shared relays and is suspected in
# the "200 then 429" cluster).
DIRECT_SHORT_RETRY_DONE=0
EGRESS_SHORT_RETRY_MAX="${EGRESS_SHORT_RETRY_MAX:-300}"
# Snapshot the ordered list, then probe small batches in parallel. We still pick
# the earliest candidate in list order that succeeds, so priority is unchanged.
mapfile -t CAND_LINES < "$EGRESS_CANDIDATES_FILE"
KIND=(); TARGET=(); SOURCE=(); PREUSED=()
for line in "${CAND_LINES[@]}"; do
  IFS=$'\t' read -r k t s <<< "$line"
  [ -n "${k:-}" ] || continue
  case "$k" in direct|relay|http) ;; *) continue ;; esac
  [ "$SELECT_MAX" -gt 0 ] && [ ${#KIND[@]} -ge "$SELECT_MAX" ] && break
  case "$k" in
    direct) ukey="direct:${DIRECT_IP:-unknown}" ;;
    *)      ukey="$k:${t:-}" ;;
  esac
  used=0
  egress_usage_has_key "$ukey" && used=1
  KIND+=("$k"); TARGET+=("${t:-}"); SOURCE+=("${s:-}"); PREUSED+=("$used")
done
# Stable partition: fresh candidates first, recently used candidates last.
nK=(); nT=(); nS=(); nU=()
for want in 0 1; do
  for j in "${!KIND[@]}"; do
    [ "${PREUSED[$j]}" = "$want" ] || continue
    nK+=("${KIND[$j]}"); nT+=("${TARGET[$j]}"); nS+=("${SOURCE[$j]}"); nU+=("${PREUSED[$j]}")
  done
done
if [ ${#KIND[@]} -gt 0 ]; then
  KIND=("${nK[@]}"); TARGET=("${nT[@]}"); SOURCE=("${nS[@]}"); PREUSED=("${nU[@]}")
fi
fresh_count=$(printf '%s\n' "${PREUSED[@]}" | grep -c '^0$' || true)
used_count=$(printf '%s\n' "${PREUSED[@]}" | grep -c '^1$' || true)
log "selection plan: ${#KIND[@]} candidate(s), fresh=$fresh_count recently-used=$used_count reuse-window=${EGRESS_REUSE_WINDOW}s, parallel=$PARALLEL, timeout=${PREFLIGHT_TMO}s"
# R2584: make the probe-vs-real-token mismatch explicit. The operator saw
# "preflight 200 then the real request 429" and asked whether every relay exit
# happens to have exactly one response left. It does not: one real turn is
# ~27x larger than the probe, so a nearly-empty shared bucket can pass the
# probe and serve one (or zero) real turns.
log "real turn prompt (24h non-error): $(egress_real_prompt_stats) tokens; zengate probe is one small request (~4k tokens), so a probe 200 only proves probe-sized headroom"

i=0
# R2582 (operator: "直连 429 时代理也会 429"): direct stays candidate #1. The
# old policy then stopped on a direct quota 429 because shared relay buckets
# were believed to be exhausted. R2598 revisited that with live evidence:
# 11/14 shared relays served a real zengate probe, and two of them served two
# consecutive ~100k-token (real-turn-sized) requests. The false "200 then 429"
# was the 4k probe failing to prove real headroom, not the relay path itself.
#
# R2617: direct stays candidate #1. If it fails, fallback exits are unlimited
# by default (EGRESS_RELAY_FALLBACK_MAX=0). Each relay must pass the small
# nonce probe and a sticky-egress check; the real-size inference probe is
# opt-in only (EGRESS_BIG_PROBE=1) because it consumes a free message.
DIRECT_QUOTA_EXHAUSTED=0
DIRECT_FAILED=0
# R2617 (operator: "回退的出口数量不要限制"): 0 = unlimited fallback exits;
# a positive value keeps an explicit budget; -1 disables relay fallback.
RELAY_FALLBACK_MAX="${EGRESS_RELAY_FALLBACK_MAX:-0}"
case "$RELAY_FALLBACK_MAX" in ''|*[!0-9-]*) RELAY_FALLBACK_MAX=0 ;; esac
[ "$RELAY_FALLBACK_MAX" -lt -1 ] && RELAY_FALLBACK_MAX=-1
RELAY_FALLBACK_TRIES=0
BIG_PROBE_TIMEOUT="${EGRESS_BIG_PROBE_TIMEOUT:-60}"
while [ "$i" -lt "${#KIND[@]}" ] && [ -z "$SELECTED_KIND" ]; do
  now=$(egress_now)
  if [ "$SELECT_BUDGET" -gt 0 ] && [ $((now - START)) -ge "$SELECT_BUDGET" ]; then
    log "selection budget exhausted (${SELECT_BUDGET}s); no 200 found"
    break
  fi
  B_REC=(); B_KEYS=()
  batch_start=$i
  while [ "$i" -lt "${#KIND[@]}" ] && [ ${#B_REC[@]} -lt "$PARALLEL" ]; do
    kind="${KIND[$i]}"; target="${TARGET[$i]}"; source="${SOURCE[$i]}"
    idx=$i; i=$((i + 1))
    case "$kind" in
      direct) key="direct:${DIRECT_IP:-unknown}"; up="direct"; target="-" ;;
      relay)  key="relay:$target"; up="relay:$target" ;;
      http)   key="http:$target"; up="http:$target" ;;
    esac
    if egress_bl_has "$key"; then
      log "skip blacklisted $key"
      continue
    fi
    pf="$EGRESS_STATE_DIR/preflight.$$.$idx"
    meta="$pf.meta"
    rm -f "$pf" "$meta"
    if [ "$PROBE_ENGINE" = "zengate" ]; then
      EGRESS_PREFLIGHT_META="$meta" \
      timeout --signal=TERM --kill-after=2s "$PROBE_TIMEOUT" \
        bash "$SCRIPT_DIR/egress-preflight-zengate.sh" "$kind" "$([ "$kind" = direct ] && echo "" || echo "$target")" "$PREFLIGHT_TMO" > "$pf" 2>/dev/null &
    elif [ "$kind" = "direct" ]; then
      EGRESS_PREFLIGHT_META="$meta" \
      timeout --signal=TERM --kill-after=2s "$PROBE_TIMEOUT" \
        bash "$SCRIPT_DIR/egress-preflight.sh" direct "" "$PREFLIGHT_TMO" > "$pf" 2>/dev/null &
    else
      EGRESS_PREFLIGHT_META="$meta" \
      timeout --signal=TERM --kill-after=2s "$PROBE_TIMEOUT" \
        bash "$SCRIPT_DIR/egress-preflight.sh" "$kind" "$target" "$PREFLIGHT_TMO" > "$pf" 2>/dev/null &
    fi
    B_REC+=("$idx|$kind|$target|$source|$key|$up|$pf|$!|${PREUSED[$idx]}")
    B_KEYS+=("$key")
  done
  # Process the batch in list order, but do not wait for lower-priority probes
  # once the earliest success is known. The old `wait` made a healthy direct
  # candidate sit through the full 8s timeout of three dead relays; with 4-way
  # parallelism that wait was pure latency. We still wait for every candidate
  # *before* the winner, so priority is unchanged. Failures that were still
  # running at fast-exit are not blacklisted this round (they are retried next
  # run) — correctness of the chosen egress is unaffected.
  pos=0
  for rec in "${B_REC[@]+"${B_REC[@]}"}"; do
    IFS='|' read -r idx kind target source key up pf pid used <<< "$rec"
    pos=$((pos + 1))
    if [ "$DIRECT_QUOTA_EXHAUSTED" = "1" ] && [ "$RELAY_FALLBACK_MAX" -lt 0 ]; then
      # Direct's bucket is gone and relay fallback is disabled; do not let a
      # same-batch relay win the selection.
      if [ -n "${pid:-}" ]; then kill "$pid" 2>/dev/null || true; fi
      rm -f "$pf"
      continue
    fi
    if [ -n "${pid:-}" ]; then wait "$pid" 2>/dev/null || true; fi
    out=$(cat "$pf" 2>/dev/null || true); rm -f "$pf"
    ra=""
    tokens=""
    if [ -f "$pf.meta" ]; then
      ra=$(sed -n 's/^retry_after=//p' "$pf.meta" 2>/dev/null | head -1)
      tokens=$(sed -n 's/^tokens=//p' "$pf.meta" 2>/dev/null | head -1)
      rm -f "$pf.meta"
    fi
    code=${out%%$'\t'*}
    why=${out##*$'\t'}
    [ -n "$code" ] || code=000
    [ -n "$why" ] || why=transport
    if [ "$code" = "200" ] && [ "$why" = "ok" ]; then
      if [ -z "$SELECTED_KIND" ]; then
        # R2551: preflight 200 只证明“那一次连接”的出口 IP 有额度。relay 若
        # 每次 CONNECT 轮换出口 IP，真实会话可能落到另一个已 quota 的 IP
        # （实测 58.27.117.24: 210.19.219.99 ↔ 入口 IP），于是 200 后仍 429。
        stable_egress=""
        if [ "$kind" = "relay" ] || [ "$kind" = "http" ]; then
          if ! egress_trace_stable "$kind" "$target" 8 > "$EGRESS_STATE_DIR/stable-select.$$"; then
            log "candidate $kind $target passed preflight but egress rotates (saw ${EGRESS_TRACE_SEEN:-?}); skipping: preflight cannot validate the IP the real session will use"
            egress_bl_add "$key" "" "unstable-egress" 21600 || true
            continue
          fi
          stable_egress=$(cat "$EGRESS_STATE_DIR/stable-select.$$")
          rm -f "$EGRESS_STATE_DIR/stable-select.$$"
        fi
        # R2565: a different relay can share the same exhausted egress IP. Only
        # a fresh candidate is rejected here; after all fresh candidates fail,
        # the used group is allowed as a deliberate fallback.
        if [ "$used" = "0" ] && [ -n "$stable_egress" ] && egress_usage_has_ip "$stable_egress"; then
          log "candidate $kind $target preflight 200 but egress=$stable_egress was used recently (reuse-window=${EGRESS_REUSE_WINDOW}s); skipping to keep a fresh quota bucket"
          continue
        fi
        # R2598/R2617: the real-turn-sized probe is now OPT-IN
        # (EGRESS_BIG_PROBE=1) and OFF by default. The free tier counts
        # MESSAGES, so every inference probe steals a message from the real
        # turn; a 4k probe returning 200 can itself consume the last message
        # and make the next real turn 429. Default path: the small nonce probe
        # proves the PATH really traverses this exit; the first real turn is the
        # quota test. Fallback exits are unlimited (RELAY_FALLBACK_MAX=0).
        if [ "$DIRECT_FAILED" = "1" ] && [ "$kind" != "direct" ] && [ "$RELAY_FALLBACK_MAX" -ge 0 ]; then
          if [ "${EGRESS_BIG_PROBE:-0}" != "1" ]; then
            log "relay fallback: $kind $target passed the path probe; selecting it (quota is tested by the first real turn)"
          else
          fallback_label="$RELAY_FALLBACK_MAX"; [ "$fallback_label" -eq 0 ] && fallback_label="unlimited"
          if [ "$RELAY_FALLBACK_MAX" -gt 0 ] && [ "$RELAY_FALLBACK_TRIES" -ge "$RELAY_FALLBACK_MAX" ]; then
            log "relay fallback budget exhausted (${RELAY_FALLBACK_MAX}); no relay verified with a real-size probe"
            i=${#KIND[@]}
            break
          fi
          RELAY_FALLBACK_TRIES=$((RELAY_FALLBACK_TRIES + 1))
          bigpf="$EGRESS_STATE_DIR/bigprobe.$$.$RELAY_FALLBACK_TRIES"
          bigmeta="$bigpf.meta"
          rm -f "$bigpf" "$bigmeta"
          log "relay fallback #${RELAY_FALLBACK_TRIES}/${fallback_label}: $kind $target passed the 4k probe; verifying with a real-size context probe"
          EGRESS_PROBE_BIG=1 EGRESS_PREFLIGHT_META="$bigmeta" \
            timeout --signal=TERM --kill-after=5s "$BIG_PROBE_TIMEOUT" \
            bash "$SCRIPT_DIR/egress-preflight-zengate.sh" "$kind" "$target" "$BIG_PROBE_TIMEOUT" > "$bigpf" 2>/dev/null || true
          bigout=$(cat "$bigpf" 2>/dev/null || true); rm -f "$bigpf"
          bigcode=${bigout%%$'\t'*}
          bigwhy=${bigout##*$'\t'}
          [ -n "$bigcode" ] || bigcode=000
          [ -n "$bigwhy" ] || bigwhy=transport
          bigtokens=""
          if [ -f "$bigmeta" ]; then
            bigtokens=$(sed -n 's/^tokens=//p' "$bigmeta" 2>/dev/null | head -1)
            rm -f "$bigmeta"
          fi
          if [ "$bigcode" != "200" ] || [ "$bigwhy" != "ok" ]; then
            log "relay fallback #${RELAY_FALLBACK_TRIES} failed the real-size probe code=$bigcode reason=$bigwhy${bigtokens:+ tokens=$bigtokens}; continuing"
            [ "$bigwhy" = "probe_setup" ] || egress_bl_add "$key" "$stable_egress" "big-probe-${bigwhy}" 21600 || true
            if [ "$RELAY_FALLBACK_MAX" -gt 0 ] && [ "$RELAY_FALLBACK_TRIES" -ge "$RELAY_FALLBACK_MAX" ]; then
              log "relay fallback budget exhausted after #${RELAY_FALLBACK_TRIES} failed real-size probe(s)"
              i=${#KIND[@]}
              break
            fi
            continue
          fi
          log "relay fallback #${RELAY_FALLBACK_TRIES} passed the real-size probe (tokens=${bigtokens:-?}); selecting it"
          # R2551/R2598: the big probe is another CONNECT and can land on a
          # different exit than the 8-trace sticky check. Re-check after it so
          # the real turn is not validated on IP A and run on IP B.
          postpf="$EGRESS_STATE_DIR/stable-big.$$"
          if ! egress_trace_stable "$kind" "$target" 4 > "$postpf"; then
            log "relay fallback #${RELAY_FALLBACK_TRIES} passed the real-size probe but egress rotates after it (saw ${EGRESS_TRACE_SEEN:-?}); skipping to avoid validating one IP and running on another"
            rm -f "$postpf"
            egress_bl_add "$key" "" "big-probe-unstable" 21600 || true
            if [ "$RELAY_FALLBACK_MAX" -gt 0 ] && [ "$RELAY_FALLBACK_TRIES" -ge "$RELAY_FALLBACK_MAX" ]; then
              i=${#KIND[@]}
              break
            fi
            continue
          fi
          post_egress=$(cat "$postpf" 2>/dev/null || true); rm -f "$postpf"
          if [ -n "$stable_egress" ] && [ -n "$post_egress" ] && [ "$post_egress" != "$stable_egress" ]; then
            log "relay fallback #${RELAY_FALLBACK_TRIES} big-probe egress changed ($stable_egress -> $post_egress); skipping because the real turn could land on an unverified bucket"
            egress_bl_add "$key" "$post_egress" "big-probe-rotated" 21600 || true
            if [ "$RELAY_FALLBACK_MAX" -gt 0 ] && [ "$RELAY_FALLBACK_TRIES" -ge "$RELAY_FALLBACK_MAX" ]; then
              i=${#KIND[@]}
              break
            fi
            continue
          fi
          tokens="$bigtokens"
          fi
        fi
        SELECTED_KIND="$kind"; SELECTED_TARGET="$target"; SELECTED_SOURCE="$source"; SELECTED_UP="$up"
        [ "$used" = "1" ] && SELECTED_SOURCE="${source}-reused"
        case "$kind" in
          direct) SELECTED_EGRESS="${DIRECT_IP:-unknown}" ;;
          relay|http) SELECTED_EGRESS="$stable_egress" ;;
        esac
        [ -n "$SELECTED_EGRESS" ] || SELECTED_EGRESS="unknown"
        egress_bl_del "$key"
        egress_usage_add "$key" "$SELECTED_EGRESS" "$SELECTED_SOURCE" \
          || log "warning: failed to record usage for $key"
        why_note=""
        [ "$kind" = "direct" ] && why_note=" (direct-first: candidate #1 passed)"
        [ -n "$stable_egress" ] && why_note="$why_note (egress sticky over 8 parallel traces)"
        [ "$PROBE_ENGINE" = "zengate" ] && why_note="$why_note (nonce-verified)"
        [ "$used" = "1" ] && why_note="$why_note (reused after all fresh candidates failed)"
        log "selected $kind $target egress=$SELECTED_EGRESS source=$SELECTED_SOURCE code=200${why_note} (batch=$batch_start${tokens:+, probe_tokens=$tokens})"
      fi
      # Stop paying for lower-priority probes as soon as the winner is known.
      killed=0
      for rec2 in "${B_REC[@]:$pos}"; do
        IFS='|' read -r _i2 _k2 _t2 _s2 _key2 _up2 pf2 pid2 <<< "$rec2"
        if [ -n "${pid2:-}" ]; then
          if kill "$pid2" 2>/dev/null; then killed=$((killed + 1)); fi
          rm -f "$pf2"
        fi
      done
      log "fast-exit after success (killed=$killed lower-priority probe(s))"
      break
    fi
    ttl=21600
    # R2565: honor the provider's Retry-After. A free-tier 429 was observed with
    # retry-after ~12.9h; a fixed 6h blacklist would retry that exhausted egress
    # too early. Use the longer of the operator's 6h floor and the provider hint.
    if [ -n "$ra" ] && [ "$ra" -gt "$ttl" ] 2>/dev/null; then ttl="$ra"; fi
    # R2566: direct short-window 429. Do not treat `retry_after=30s` as a
    # 6h-exhausted bucket; wait out (a capped part of) the hint and re-probe the
    # same runner IP once. Only a second failure is blacklisted.
    if [ "$kind" = "direct" ] && [ "$why" = "quota" ] && [ -n "$ra" ] \
       && [ "$ra" -gt 0 ] 2>/dev/null && [ "$ra" -le "$EGRESS_SHORT_RETRY_MAX" ] 2>/dev/null \
       && [ "$DIRECT_SHORT_RETRY_DONE" = "0" ]; then
      DIRECT_SHORT_RETRY_DONE=1
      # Keep the whole non-OpenCode phase under the operator's 1-minute target:
      # honor at most 20s of the hint, then re-probe once.
      wait_s="$ra"; [ "$wait_s" -gt 20 ] && wait_s=20
      log "candidate direct short quota code=$code retry_after=${ra}s (<= ${EGRESS_SHORT_RETRY_MAX}s); retrying once in ${wait_s}s instead of blacklisting for ${ttl}s"
      sleep "$wait_s"
      # Put the retry immediately next in line; the rest of the ordered list is
      # untouched.
      KIND=("${KIND[@]:0:i}" "$kind" "${KIND[@]:i}")
      TARGET=("${TARGET[@]:0:i}" "$target" "${TARGET[@]:i}")
      SOURCE=("${SOURCE[@]:0:i}" "$source" "${SOURCE[@]:i}")
      PREUSED=("${PREUSED[@]:0:i}" "0" "${PREUSED[@]:i}")
      continue
    fi
    if [ "$kind" = "direct" ] && [ "$why" = "quota" ]; then
      DIRECT_QUOTA_EXHAUSTED=1
      if [ "$RELAY_FALLBACK_MAX" -ge 0 ]; then
        log "direct free-quota exhausted (code=$code retry_after=${ra:-?}s); direct stays failed, trying relay fallback exits (max=${RELAY_FALLBACK_MAX:-0}; 0=unlimited)"
      else
        log "direct free-quota exhausted (code=$code retry_after=${ra:-?}s); relay fallback disabled — stopping candidate probing"
        i=${#KIND[@]}
      fi
    fi
    if [ "$kind" = "direct" ]; then
      DIRECT_FAILED=1
      failed_egress="${DIRECT_IP:-}"
    elif [ "$why" = "quota" ] || [ "$why" = "body_error" ]; then
      # Only trace quota failures: a dead relay would burn the trace timeout for
      # no diagnostic value, and the entry address is enough to blacklist it.
      failed_egress=$(egress_candidate_ip "$kind" "$target" 2>/dev/null || true)
    else
      failed_egress=""
    fi
    # R2562 (operator): blacklist every failed candidate for at least 6h. Direct
    # keys are runner-IP scoped, so they naturally never match a future runner;
    # they are written for diagnostics and to keep one code path.
    egress_bl_add "$key" "$failed_egress" "$why" "$ttl" || true
    if [ "$EGRESS_BLACKLIST_ENABLED" = "1" ]; then
      log "candidate $kind $target failed code=$code reason=$why egress=${failed_egress:-?} (blacklist ${ttl}s${ra:+ retry_after=${ra}s}${tokens:+ probe_tokens=$tokens})"
    else
      log "candidate $kind $target failed code=$code reason=$why egress=${failed_egress:-?} (blacklist disabled${tokens:+ probe_tokens=$tokens})"
    fi
  done
done

if [ -z "$SELECTED_KIND" ]; then
  if [ "$DIRECT_QUOTA_EXHAUSTED" = "1" ]; then
    if [ "$RELAY_FALLBACK_MAX" -ge 0 ]; then
      log "ERROR: direct free-quota exhausted and no relay passed the path probe; ending this run so the next fresh runner IP gets a new direct bucket (no pause; relay will retry)"
      echo "::error::egress selection failed: direct quota exhausted; no relay passed the path probe"
    else
      log "ERROR: direct free-quota exhausted; relay fallback disabled — refusing to switch to shared relay egress. Ending this run so the next fresh runner IP gets a new direct bucket."
      echo "::error::egress selection failed: direct quota exhausted; relay fallback disabled"
    fi
  else
    log "ERROR: no candidate passed the real preflight (no 200), including direct; refusing to run without a verified egress"
    echo "::error::egress selection failed: no candidate answered 200 (direct + relays); no unverified egress will be used"
  fi
  exit 1
fi

# R2575 (D8): the handoff files are the only proof the Run OpenCode step has
# that an egress was selected. A write failure here used to leave selection
# "green" while the next step found no exit-proxy.env and silently used the
# runner's direct connection. Every write is checked and any failure ends
# selection (fail closed: every candidate, direct included, failed).
egress_write_upstream "$SELECTED_UP" || {
  echo "::error::failed to write egress upstream ($EGRESS_UPSTREAM_FILE); refusing to run without a verified egress"
  exit 1
}
egress_write_state "$SELECTED_KIND" "$SELECTED_UP" "$SELECTED_EGRESS" "$SELECTED_SOURCE" "${DIRECT_IP:-unknown}" || {
  echo "::error::failed to write egress state ($EGRESS_STATE_FILE); refusing to run without a verified egress"
  exit 1
}

# ---- handoff to the Run OpenCode step ------------------------------------
NO_PROXY_LIST="localhost,127.0.0.1,::1,api.telegram.org,github.com,api.github.com,objects.githubusercontent.com,release-assets.githubusercontent.com,raw.githubusercontent.com,codeload.github.com,registry.npmjs.org"
HANDOFF_TMP="$RUNNER_TEMP/exit-proxy.env.tmp.$$"
{
  echo "HTTP_PROXY=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "HTTPS_PROXY=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "http_proxy=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "https_proxy=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "NO_PROXY=${NO_PROXY_LIST}"
  echo "no_proxy=${NO_PROXY_LIST}"
} > "$HANDOFF_TMP" || {
  rm -f "$HANDOFF_TMP"
  echo "::error::failed to write egress handoff ($RUNNER_TEMP/exit-proxy.env); refusing to run without a verified egress"
  exit 1
}
mv -f "$HANDOFF_TMP" "$RUNNER_TEMP/exit-proxy.env" || {
  rm -f "$HANDOFF_TMP"
  echo "::error::failed to install egress handoff ($RUNNER_TEMP/exit-proxy.env); refusing to run without a verified egress"
  exit 1
}
chmod 600 "$RUNNER_TEMP/exit-proxy.env" 2>/dev/null || true
if ! grep -q '^HTTPS_PROXY=http://127\.0\.0\.1:' "$RUNNER_TEMP/exit-proxy.env"; then
  echo "::error::egress handoff env is incomplete ($RUNNER_TEMP/exit-proxy.env); refusing to run without a verified egress"
  exit 1
fi

echo "[egress-select] upstream=$SELECTED_UP kind=$SELECTED_KIND egress=$SELECTED_EGRESS source=$SELECTED_SOURCE direct=${DIRECT_IP:-unknown}"
exit 0
