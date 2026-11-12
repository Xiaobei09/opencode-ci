#!/usr/bin/env bash
# Shared state for the egress switcher.
#
# The blacklist is intentionally under $HOME/.config/opencode so the whole-$HOME
# snapshot carries it across runs. It is keyed by the candidate (entry ip:port),
# because that is what the preflight can address; the observed egress IP is
# stored alongside for diagnostics.
set -uo pipefail

EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-${RUNNER_TEMP:-/tmp}/egress}"
EGRESS_BLACKLIST="${EGRESS_BLACKLIST:-$HOME/.config/opencode/egress-blacklist.json}"
# R2562 (operator): enable the persistent blacklist by default. Failed
# candidates are skipped for 6h so a new run does not immediately re-probe the
# same exhausted egress. Set EGRESS_BLACKLIST_ENABLED=0 only for diagnostics.
EGRESS_BLACKLIST_ENABLED="${EGRESS_BLACKLIST_ENABLED:-1}"
EGRESS_UPSTREAM_FILE="$EGRESS_STATE_DIR/upstream"
EGRESS_EPOCH_FILE="$EGRESS_STATE_DIR/epoch"
EGRESS_CANDIDATES_FILE="$EGRESS_STATE_DIR/candidates.tsv"
EGRESS_STATE_FILE="${EGRESS_STATE_FILE:-$HOME/.config/opencode/exit-proxy.json}"
EGRESS_USAGE="${EGRESS_USAGE:-$HOME/.config/opencode/egress-usage.json}"
# R2565: anonymous free quota is per egress IP. Reusing the same relay across
# runs means paying with a partially consumed bucket; the provider's 429
# retry-after was observed at ~12.9h, longer than the 6h failure blacklist.
# R2582: the bucket is a DAILY quota (48/48 recent 429s converge to the same
# 00:44:19 UTC reset), so a 13h window can still land in the same bucket.
# Successful relays are avoided for 24h; every run starts on a fresh IP.
EGRESS_REUSE_WINDOW="${EGRESS_REUSE_WINDOW:-86400}"
# R2595 (D8, operator: "200 then 429 keeps getting worse"): the anonymous free
# bucket resets daily at a fixed UTC boundary (observed 00:44:19; 48/48 quota
# 429 retry-after values converge there). A rolling 24h reuse window is wrong
# for relays: a relay used at 23:00 yesterday is fresh again at 00:45 today,
# but the rolling window would keep excluding it until 23:00 tonight. At ~288
# selections/day that shrinks the fresh pool all day and forces the selector
# onto dirtier exits. Align the cutoff with the most recent reset boundary.
EGRESS_QUOTA_RESET_UTC="${EGRESS_QUOTA_RESET_UTC:-00:44:19}"
EGRESS_LOCAL_PORT="${EGRESS_LOCAL_PORT:-8089}"
# R2567 (operator: is provider traffic really leaving through the selected
# proxy?): the old probe used www.cloudflare.com, which the local CONNECT proxy
# always sends direct, so a relay selection always looked like "direct" and the
# check could not prove where provider traffic went. Probe a provider-owned
# Cloudflare endpoint instead: opencode.ai is routed through the selected
# upstream by the same rules as the real inference requests.
EGRESS_TRACE_URL="${EGRESS_TRACE_URL:-https://opencode.ai/cdn-cgi/trace}"

egress_now() { date +%s; }
egress_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Latest model the agent actually used. The free tier is metered per model as
# well as per account: probing `big-pickle` while the session runs
# `deepseek-v4.1-flash-free` produced the operator-reported "preflight 200 then
# provider.free-limit" false positive. Read the newest assistant message from
# the restored DB so the probe hits the same quota bucket as the real session.
# Falls back to EGRESS_PROBE_MODEL_FALLBACK (big-pickle) when the DB is absent.
egress_probe_model() {
  local db="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}" m=""
  if [ -s "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
    m=$(sqlite3 "$db" \
      "select json_extract(data,'\$.model.id') from session_message
        where type='assistant' and json_extract(data,'\$.model.id') is not null
        order by time_created desc limit 1;" 2>/dev/null | head -1)
  fi
  [ -n "$m" ] || m="${EGRESS_PROBE_MODEL_FALLBACK:-big-pickle}"
  printf '%s\n' "$m"
}

# R2584 (operator: "these exits all happen to have exactly one response left?"):
# A zengate probe is one small request (~4k prompt tokens). A real resumed turn
# carries the whole session context: live measurement over 24h gave p50≈107k,
# p90≈162k, max≈170k tokens. So a relay bucket with only ~70k left can answer
# the probe with 200, answer exactly one real turn, then 429 the next concurrent
# turn. Log the observed real prompt size next to the probe so the mismatch is
# visible in every selection (no need to re-derive it from the DB by hand).
egress_real_prompt_stats() {
  local db="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}" row avg="" max="" n="0"
  if [ -s "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
    row=$(sqlite3 -separator ' ' "$db" \
      "select cast(avg(x) as int), max(x), count(*) from (
         select coalesce(json_extract(data,'\$.tokens.input'),0)
              + coalesce(json_extract(data,'\$.tokens.cache.read'),0)
              + coalesce(json_extract(data,'\$.tokens.cache.write'),0) x
           from session_message
          where type='assistant' and json_extract(data,'\$.tokens') is not null
            and json_extract(data,'\$.error.type') is null
            and time_created > (strftime('%s','now')-86400)*1000);" 2>/dev/null | head -1)
    read -r avg max n <<< "$row"
  fi
  if [ -n "${avg:-}" ] && [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    printf 'avg=%s max=%s n=%s' "$avg" "$max" "$n"
  else
    printf 'unknown'
  fi
}

egress_bl_init() {
  mkdir -p "$EGRESS_STATE_DIR"
  [ "$EGRESS_BLACKLIST_ENABLED" = "1" ] || return 0
  mkdir -p "$(dirname "$EGRESS_BLACKLIST")"
  if [ ! -s "$EGRESS_BLACKLIST" ]; then
    printf '%s\n' '{"version":1,"entries":{}}' > "$EGRESS_BLACKLIST"
  fi
  chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
}

egress_bl_prune() {
  local now tmp
  [ "$EGRESS_BLACKLIST_ENABLED" = "1" ] || return 0
  now=$(egress_now)
  [ -s "$EGRESS_BLACKLIST" ] || return 0
  tmp=$(mktemp "${EGRESS_BLACKLIST}.XXXXXX") || return 0
  if jq --argjson now "$now" \
       '.entries |= with_entries(select((.value.until // 0) > $now))' \
       "$EGRESS_BLACKLIST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_BLACKLIST"
    chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
  else
    rm -f "$tmp"
  fi
}

# egress_bl_has <key>
egress_bl_has() {
  local key="$1" now
  [ "$EGRESS_BLACKLIST_ENABLED" = "1" ] || return 1
  now=$(egress_now)
  jq -e --arg k "$key" --argjson now "$now" \
    '(.entries[$k].until // 0) > $now' "$EGRESS_BLACKLIST" >/dev/null 2>&1
}

# egress_bl_add <key> <egress> <reason> <ttl-seconds>
egress_bl_add() {
  local key="$1" egress="$2" reason="$3" ttl="${4:-21600}" until at tmp
  [ "$EGRESS_BLACKLIST_ENABLED" = "1" ] || return 0
  until=$(( $(egress_now) + ttl ))
  at=$(egress_iso)
  tmp=$(mktemp "${EGRESS_BLACKLIST}.XXXXXX") || return 1
  if jq --arg k "$key" --arg e "$egress" --arg r "$reason" \
        --argjson u "$until" --arg at "$at" \
        '.entries[$k] = ((.entries[$k] // {}) + {
           egress:$e, reason:$r, until:$u, at:$at,
           strikes:(((.entries[$k].strikes // 0) + 1))
         })' "$EGRESS_BLACKLIST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_BLACKLIST"
    chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
  else
    rm -f "$tmp"
    return 1
  fi
}

egress_bl_del() {
  local key="$1" tmp
  [ "$EGRESS_BLACKLIST_ENABLED" = "1" ] || return 0
  tmp=$(mktemp "${EGRESS_BLACKLIST}.XXXXXX") || return 0
  if jq --arg k "$key" 'del(.entries[$k])' "$EGRESS_BLACKLIST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_BLACKLIST"
    chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
  else
    rm -f "$tmp"
  fi
}

# ---- successful-egress usage history -------------------------------------
# The failure blacklist is not enough to guarantee a fresh quota bucket: a
# relay can pass a tiny preflight, then the real (large-context) session sends
# a much larger request and hits the remainder of that IP's free budget. Keep a
# separate, longer-lived history of relays/IPs we actually selected so a new
# run prefers an unused egress.
egress_usage_init() {
  mkdir -p "$(dirname "$EGRESS_USAGE")"
  if [ ! -s "$EGRESS_USAGE" ]; then
    printf '%s\n' '{"version":1,"entries":{}}' > "$EGRESS_USAGE"
  fi
  chmod 600 "$EGRESS_USAGE" 2>/dev/null || true
}

# egress_quota_reset_epoch: epoch of the most recent daily free-quota reset.
# Empty EGRESS_QUOTA_RESET_UTC disables reset alignment (rolling window only).
egress_quota_reset_epoch() {
  local hhmmss="${EGRESS_QUOTA_RESET_UTC:-}" now today
  [ -n "$hhmmss" ] || return 1
  now=$(egress_now)
  today=$(date -u -d "today $hhmmss" +%s 2>/dev/null) || return 1
  if [ "$today" -gt "$now" ]; then
    date -u -d "yesterday $hhmmss" +%s 2>/dev/null || return 1
  else
    printf '%s\n' "$today"
  fi
}

# egress_usage_cutoff: entries with last_used > cutoff are "recently used".
# Use the later of (now - reuse_window) and the last quota reset so a new
# provider day frees every candidate consumed during the previous day.
egress_usage_cutoff() {
  local now win cutoff reset
  now=$(egress_now)
  win="${EGRESS_REUSE_WINDOW:-86400}"
  cutoff=$((now - win))
  reset=$(egress_quota_reset_epoch 2>/dev/null || true)
  if [ -n "$reset" ] && [ "$reset" -gt "$cutoff" ] 2>/dev/null; then
    cutoff=$reset
  fi
  printf '%s\n' "$cutoff"
}

egress_usage_prune() {
  local now tmp
  now=$(egress_now)
  [ -s "$EGRESS_USAGE" ] || return 0
  tmp=$(mktemp "${EGRESS_USAGE}.XXXXXX") || return 0
  if jq --argjson now "$now" --argjson win "$EGRESS_REUSE_WINDOW" \
       '.entries |= with_entries(select((.value.last_used // 0) > ($now - $win)))' \
       "$EGRESS_USAGE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_USAGE"
    chmod 600 "$EGRESS_USAGE" 2>/dev/null || true
  else
    rm -f "$tmp"
  fi
}

# egress_usage_has_key <candidate-key>
egress_usage_has_key() {
  local key="$1" cutoff
  cutoff=$(egress_usage_cutoff)
  jq -e --arg k "$key" --argjson cutoff "$cutoff" \
    '(.entries[$k].last_used // 0) > $cutoff' "$EGRESS_USAGE" >/dev/null 2>&1
}

# egress_usage_has_ip <observed-egress-ip>
egress_usage_has_ip() {
  local ip="$1" cutoff
  [ -n "$ip" ] && [ "$ip" != "unknown" ] || return 1
  cutoff=$(egress_usage_cutoff)
  jq -e --arg ip "$ip" --argjson cutoff "$cutoff" \
    '[.entries[] | select(.egress == $ip and (.last_used // 0) > $cutoff)] | length > 0' \
    "$EGRESS_USAGE" >/dev/null 2>&1
}

# egress_usage_add <candidate-key> <observed-egress-ip> <source>
egress_usage_add() {
  local key="$1" egress="$2" source="$3" now at tmp
  now=$(egress_now)
  at=$(egress_iso)
  tmp=$(mktemp "${EGRESS_USAGE}.XXXXXX") || return 1
  if jq --arg k "$key" --arg e "$egress" --arg s "$source" \
        --argjson now "$now" --arg at "$at" \
        '.entries[$k] = {egress:$e, source:$s, last_used:$now, at:$at}' \
        "$EGRESS_USAGE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_USAGE"
    chmod 600 "$EGRESS_USAGE" 2>/dev/null || true
  else
    rm -f "$tmp"
    return 1
  fi
}

# Seed the previous run's selected relay into the history on first deployment
# (the usage file did not exist before R2565). Do not seed if the state is old.
egress_usage_seed_previous() {
  local up picked picked_epoch egress
  [ -s "$EGRESS_STATE_FILE" ] || return 0
  up=$(jq -r '.upstream // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  case "$up" in
    relay:*|http:*) ;;
    *) return 0 ;;
  esac
  picked=$(jq -r '.picked_at // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  [ -n "$picked" ] || return 0
  picked_epoch=$(date -u -d "$picked" +%s 2>/dev/null || echo 0)
  [ "$picked_epoch" -gt 0 ] || return 0
  # R2595: a relay selected before the most recent daily reset already has a
  # fresh bucket again; seeding it as recently-used would exclude a healthy
  # candidate for no reason.
  local reset
  reset=$(egress_quota_reset_epoch 2>/dev/null || echo 0)
  if [ "$reset" -gt 0 ] && [ "$picked_epoch" -lt "$reset" ]; then
    return 0
  fi
  [ $(( $(egress_now) - picked_epoch )) -le "$EGRESS_REUSE_WINDOW" ] || return 0
  egress=$(jq -r '.egress_ip // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
  egress_usage_add "$up" "$egress" "previous-run" || true
}

egress_epoch_bump() {
  local e
  e=$(cat "$EGRESS_EPOCH_FILE" 2>/dev/null || echo 0)
  echo $((e + 1)) > "$EGRESS_EPOCH_FILE"
}

# egress_write_upstream <direct|relay:ip:port|http:host:port>
# The proxy reads this file on every CONNECT. Write atomically so it can never
# observe a partially written value (which would be an invalid upstream and,
# before R2567, silently fell back to direct).
egress_write_upstream() {
  local tmp="$EGRESS_UPSTREAM_FILE.tmp.$$"
  printf '%s\n' "$1" > "$tmp" || return 1
  mv -f "$tmp" "$EGRESS_UPSTREAM_FILE" || { rm -f "$tmp"; return 1; }
  egress_epoch_bump
}

# egress_write_state <kind> <upstream> <egress_ip> <source> <direct_ip>
egress_write_state() {
  local kind="$1" upstream="$2" egress="$3" source="$4" direct="$5"
  local dir tmp
  dir="$(dirname "$EGRESS_STATE_FILE")"
  # R2575 (D8): a failed write used to leave an empty/partial exit-proxy.json
  # while the caller carried on. Write atomically and let the caller fail
  # closed: no state file means no egress proof for the next step.
  mkdir -p "$dir" || return 1
  tmp="$EGRESS_STATE_FILE.tmp.$$"
  jq -n \
    --arg proxy "127.0.0.1:${EGRESS_LOCAL_PORT}" \
    --arg scheme "http" \
    --arg upstream "$upstream" \
    --arg kind "$kind" \
    --arg egress "$egress" \
    --arg direct "$direct" \
    --arg source "$source" \
    --arg at "$(egress_iso)" \
    '{proxy:$proxy, scheme:$scheme, upstream:$upstream, kind:$kind,
      egress_ip:$egress, direct_ip:$direct, latency_s:"",
      source:$source, picked_at:$at}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$EGRESS_STATE_FILE" || { rm -f "$tmp"; return 1; }
  chmod 600 "$EGRESS_STATE_FILE" 2>/dev/null || true
  return 0
}

# egress_trace_relay <ip:port> [timeout]
# `--connect-to` keeps TLS SNI/Host = opencode.ai while the TCP connection goes
# to the relay, exactly like the real inference traffic.
egress_trace_relay() {
  local hp="$1" tmo="${2:-10}" ip port
  ip=${hp%:*}; port=${hp##*:}
  curl -sS -m "$tmo" --noproxy '*' --connect-to "opencode.ai:443:$ip:$port" \
    "$EGRESS_TRACE_URL" 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}

# egress_trace_http <host:port> [timeout]
egress_trace_http() {
  local hp="$1" tmo="${2:-10}"
  curl -sS -m "$tmo" -x "http://$hp" \
    "$EGRESS_TRACE_URL" 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}

# egress_trace_direct [timeout]
egress_trace_direct() {
  curl -sS -m "${1:-10}" --noproxy '*' \
    "$EGRESS_TRACE_URL" 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}

# R2551（运营者：zengate 显示 200 后仍 429，会不会没走代理出口？）：
# 部分 relay 每次 CONNECT 会从不同出口 IP 出去（实测 58.27.117.24 在
# 210.19.219.99 与入口 IP 之间轮换，10 次 trace 为 4/6）。preflight 只验证
# 它那一次连接所用的 IP；真实会话的下一条连接可能换成另一个已 quota 的 IP，
# 于是出现“zengate 200 后仍 429”，错误卡显示的 egress 也会指错 IP。
# 选择/轮换在 preflight 成功后必须再 trace samples 次，全部一致才接受，并把
# 该稳定 IP 写入状态。退出码 0 + stdout=稳定 IP；1=不可达或 IP 轮换。
# 观测序列放在 EGRESS_TRACE_SEEN（调用方不要用 $(...) 包裹，否则丢失）。
EGRESS_TRACE_SEEN=""
# 把逗号分隔的观测序列归并：只有一个唯一 IP 才算稳定。
egress_trace_stable_from() {
  local vals="$1" uniq
  uniq=$(printf '%s\n' "$vals" | tr ',' '\n' | grep -v '^unreachable$' | grep -v '^$' | sort -u)
  [ -n "$uniq" ] || return 1
  [ "$(printf '%s\n' "$uniq" | wc -l)" -eq 1 ] || return 1
  printf '%s\n' "$uniq"
}
egress_trace_stable() {
  local kind="$1" target="${2:-}" samples="${3:-8}" tmo="${EGRESS_TRACE_TIMEOUT:-6}"
  local i ip vals="" f tmpdir pids=() uniq
  EGRESS_TRACE_SEEN=""
  case "$kind" in
    direct)
      ip=$(egress_trace_direct "$tmo")
      [ -n "$ip" ] || { EGRESS_TRACE_SEEN="unreachable"; return 1; }
      EGRESS_TRACE_SEEN="$ip"
      printf '%s\n' "$ip"
      return 0
      ;;
    relay|http) ;;
    *) return 1 ;;
  esac
  # 并行采样：轮换型 relay 在同一次成功 preflight 后，仍可能在后续 CONNECT
  # 换 IP；顺序 3 次采样有约 28% 概率恰好全落在同一侧（实测 58.27.117.24
  # 4:6 轮换）。并行 8 个新连接能稳定暴露轮换（实测两个 IP 必现）。
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/egress-trace.XXXXXX") || return 1
  for i in $(seq 1 "$samples"); do
    (
      if [ "$kind" = "relay" ]; then
        egress_trace_relay "$target" "$tmo"
      else
        egress_trace_http "$target" "$tmo"
      fi
    ) > "$tmpdir/$i" 2>/dev/null &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i" 2>/dev/null || true; done
  for f in "$tmpdir"/*; do
    ip=$(cat "$f" 2>/dev/null || true)
    if [ -z "$ip" ]; then
      vals="${vals:+$vals,}unreachable"
    else
      vals="${vals:+$vals,}$ip"
    fi
  done
  rm -rf "$tmpdir"
  EGRESS_TRACE_SEEN="$vals"
  uniq=$(egress_trace_stable_from "$vals") || return 1
  printf '%s\n' "$uniq"
}

# egress_candidate_ip <direct|relay|http> <target>
# Best-effort observed exit IP for a candidate. Used for diagnostics and for
# recording what an unavailable entry actually pointed at.
egress_candidate_ip() {
  local kind="$1" target="${2:-}"
  case "$kind" in
    direct) egress_trace_direct ;;
    relay)  egress_trace_relay "$target" ;;
    http)   egress_trace_http "$target" ;;
  esac
}
