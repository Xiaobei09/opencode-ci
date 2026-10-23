#!/usr/bin/env bash
# Select the initial egress for this CI run and write a local-proxy handoff.
#
# This replaces the old "probe /zen/v1/models" logic: a 200 from that endpoint
# does NOT mean the free-tier quota is available. Every candidate is tested
# with the real inference call (egress-preflight.sh) and only a 200 switches.
#
# Outputs:
#   $RUNNER_TEMP/egress/upstream        direct | relay:ip:port | http:host:port
#   $RUNNER_TEMP/egress/candidates.tsv  ordered fallbacks for runtime rotation
#                                       (direct + proxyip relays; public HTTP
#                                       only with EGRESS_ALLOW_PUBLIC_HTTP=1)
#   $RUNNER_TEMP/exit-proxy.env         HTTP_PROXY=http://127.0.0.1:8089
#   $HOME/.config/opencode/exit-proxy.json
#   $HOME/.config/opencode/egress-blacklist.json (persisted, 0600)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-$RUNNER_TEMP/egress}"
export EGRESS_STATE_DIR
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

mkdir -p "$EGRESS_STATE_DIR"
: > "$EGRESS_CANDIDATES_FILE"
echo 0 > "$EGRESS_EPOCH_FILE"
egress_bl_init
egress_bl_prune

SELECT_BUDGET="${EGRESS_SELECT_BUDGET:-240}"
SELECT_MAX="${EGRESS_SELECT_MAX:-80}"
START=$(egress_now)

log() { echo "[egress-select] $*"; }

DIRECT_IP=$(egress_trace_direct)
DIRECT_COLO=$(curl -sS -m 10 --noproxy '*' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}')
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

# ---- pick the first candidate that passes the real preflight --------------
SELECTED_KIND=""; SELECTED_TARGET=""; SELECTED_SOURCE=""; SELECTED_UP=""; SELECTED_EGRESS=""
n=0
while IFS=$'\t' read -r kind target source; do
  [ -n "${kind:-}" ] || continue
  now=$(egress_now)
  [ $((now - START)) -ge "$SELECT_BUDGET" ] && { log "selection budget exhausted"; break; }
  [ "$n" -ge "$SELECT_MAX" ] && { log "selection max candidates reached"; break; }

  case "$kind" in
    direct) key="direct:${DIRECT_IP:-unknown}"; up="direct"; target="-" ;;
    relay)  key="relay:$target"; up="relay:$target" ;;
    http)   key="http:$target"; up="http:$target" ;;
    *) continue ;;
  esac

  if egress_bl_has "$key"; then
    log "skip blacklisted $key"
    continue
  fi
  n=$((n + 1))
  if [ "$kind" = "direct" ]; then
    out=$(bash "$SCRIPT_DIR/egress-preflight.sh" direct "" 12 2>/dev/null || true)
  else
    out=$(bash "$SCRIPT_DIR/egress-preflight.sh" "$kind" "$target" 12 2>/dev/null || true)
  fi
  code=${out%%$'\t'*}
  why=${out##*$'\t'}
  [ -n "$code" ] || code=000
  [ -n "$why" ] || why=transport
  if [ "$code" = "200" ] && [ "$why" = "ok" ]; then
    SELECTED_KIND="$kind"; SELECTED_TARGET="$target"; SELECTED_SOURCE="$source"; SELECTED_UP="$up"
    case "$kind" in
      direct) SELECTED_EGRESS="${DIRECT_IP:-unknown}" ;;
      relay)  SELECTED_EGRESS=$(egress_trace_relay "$target") ;;
      http)   SELECTED_EGRESS=$(egress_trace_http "$target") ;;
    esac
    [ -n "$SELECTED_EGRESS" ] || SELECTED_EGRESS="unknown"
    egress_bl_del "$key"
    log "selected $kind $target egress=$SELECTED_EGRESS code=200"
    break
  fi
  ttl=21600
  [ "$why" = "transport" ] && ttl=1800
  if [ "$kind" = "direct" ]; then
    failed_egress="${DIRECT_IP:-}"
  elif [ "$why" = "quota" ] || [ "$why" = "body_error" ]; then
    # Only trace quota failures: a dead relay would burn the trace timeout for
    # no diagnostic value, and the entry address is enough to blacklist it.
    failed_egress=$(egress_candidate_ip "$kind" "$target" 2>/dev/null || true)
  else
    failed_egress=""
  fi
  egress_bl_add "$key" "$failed_egress" "$why" "$ttl" || true
  log "candidate $kind $target failed code=$code reason=$why egress=${failed_egress:-?} (blacklist ${ttl}s)"
done < "$EGRESS_CANDIDATES_FILE"

if [ -z "$SELECTED_KIND" ]; then
  log "no candidate passed; falling back to direct (the next run gets a fresh runner IP)"
  SELECTED_KIND="direct"; SELECTED_TARGET="-"; SELECTED_SOURCE="fallback-direct"
  SELECTED_UP="direct"; SELECTED_EGRESS="${DIRECT_IP:-unknown}"
fi

egress_write_upstream "$SELECTED_UP"
egress_write_state "$SELECTED_KIND" "$SELECTED_UP" "$SELECTED_EGRESS" "$SELECTED_SOURCE" "${DIRECT_IP:-unknown}"

# ---- handoff to the Run OpenCode step ------------------------------------
NO_PROXY_LIST="localhost,127.0.0.1,::1,api.telegram.org,github.com,api.github.com,objects.githubusercontent.com,release-assets.githubusercontent.com,raw.githubusercontent.com,codeload.github.com,registry.npmjs.org"
{
  echo "HTTP_PROXY=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "HTTPS_PROXY=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "http_proxy=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "https_proxy=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "NO_PROXY=${NO_PROXY_LIST}"
  echo "no_proxy=${NO_PROXY_LIST}"
} > "$RUNNER_TEMP/exit-proxy.env"
chmod 600 "$RUNNER_TEMP/exit-proxy.env" 2>/dev/null || true

echo "[egress-select] upstream=$SELECTED_UP kind=$SELECTED_KIND egress=$SELECTED_EGRESS source=$SELECTED_SOURCE direct=${DIRECT_IP:-unknown}"
exit 0
