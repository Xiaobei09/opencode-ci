#!/usr/bin/env bash
# Select a public forward proxy for the provider traffic of this CI run.
#
# Why this exists (replaces the old force-resolve IP switching):
#   The opencode zen free tier is quota'd per client IP, so a long-lived CI
#   runner eventually gets "Free usage limit reached. Connect a provider or
#   subscribe to OpenCode Go to keep going, or switch models.".
#   The old mechanism rewrote /etc/hosts to point opencode.ai at another
#   Cloudflare edge IP (force-resolve.sh) and/or switched a mihomo node. That
#   is DNS-level IP switching: it does not change the client IP the origin
#   sees, it only changes which edge answers, so the quota was still hit - and
#   it needed a writable /etc/hosts plus a node switcher inside the bridge.
#   This script picks a real forward proxy from public proxy lists and exports
#   HTTP_PROXY/HTTPS_PROXY, so the provider traffic leaves the runner through
#   that proxy (a different egress IP per run).
#
# opencode v2 is a Bun binary. Its fetch honours http_proxy/HTTP_PROXY,
# https_proxy/HTTPS_PROXY and no_proxy/NO_PROXY (verified locally: a provider
# request is tunnelled with CONNECT through the proxy, NO_PROXY hosts bypass
# it). SOCKS is NOT supported by Bun ("UnsupportedProxyProtocol"), so only
# http:// proxies are considered here. The CLI and the server it spawns both
# inherit the environment, so exporting the variables in the caller is enough.
#
# Contract with the workflow:
#   * writes $RUNNER_TEMP/exit-proxy.env  (shell-sourceable, consumed by the
#     step that runs opencode - deliberately NOT $GITHUB_ENV, so that gh/curl
#     in the snapshot and relay steps keep talking to github.com directly)
#   * writes $HOME/.config/opencode/exit-proxy.json (state for the TG bridge
#     and for the next run, which then avoids reusing the same proxy)
#   * never fails the step: with no usable proxy the run continues on a direct
#     connection and says so.
set -uo pipefail

# The probe must measure the candidates themselves, not an inherited proxy.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
ENV_FILE="$RUNNER_TEMP/exit-proxy.env"
STATE_FILE="$HOME/.config/opencode/exit-proxy.json"
PROBE_URL="${EXIT_PROXY_PROBE_URL:-https://opencode.ai/zen/v1/models}"
IP_URL="${EXIT_PROXY_IP_URL:-https://api.ipify.org}"
MAX_CANDIDATES="${EXIT_PROXY_MAX_CANDIDATES:-150}"
PROBE_TIMEOUT="${EXIT_PROXY_PROBE_TIMEOUT:-7}"
BUDGET_SECONDS="${EXIT_PROXY_BUDGET_SECONDS:-240}"
PARALLEL="${EXIT_PROXY_PARALLEL:-16}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo "[exit-proxy] $*"; }

mkdir -p "$(dirname "$STATE_FILE")"

# --- 0. never reuse the proxy of the previous run ----------------------------
PREV=""
PREV_EGRESS=""
if [ -f "$STATE_FILE" ]; then
  PREV=$(jq -r '.proxy // empty' "$STATE_FILE" 2>/dev/null || true)
  PREV_EGRESS=$(jq -r '.egress_ip // empty' "$STATE_FILE" 2>/dev/null || true)
fi

# --- 1. direct egress IP (the identity whose quota is exhausted) -------------
DIRECT_IP=$(curl -s -m 12 "$IP_URL" 2>/dev/null | tr -dc '0-9a-fA-F.:' | head -c 64)
log "direct egress=${DIRECT_IP:-unknown} previous=${PREV:-none}"

# --- 2. candidate pool from public proxy lists ------------------------------
# Only http:// proxies: Bun cannot use SOCKS. Note that Xiaobei09/proxyip is a
# Cloudflare edge / relay dataset (it feeds DNS-level --resolve tricks) and
# contains no usable CONNECT proxies - measured 0/100 reachable - so it is not
# part of the pool any more.
SOURCES=(
  "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt"
  "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"
  "https://raw.githubusercontent.com/jetkai/proxy-list/main/online-proxies/txt/proxies-http.txt"
  "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt"
)
: > "$WORK/pool.txt"
for url in "${SOURCES[@]}"; do
  f="$WORK/$(printf '%s' "$url" | md5sum | cut -c1-12).txt"
  if curl -fsSL -m 25 "$url" -o "$f" 2>/dev/null; then
    n=$(tr -d '\r' < "$f" | sed 's/#.*//' | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' | sort -u | wc -l)
    log "source $n entries ${url}"
    tr -d '\r' < "$f" | sed 's/#.*//' \
      | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' | sort -u >> "$WORK/pool.txt"
  else
    log "source unavailable: ${url}"
  fi
done

sort -u "$WORK/pool.txt" | grep -v "^${PREV:-__none__}$" > "$WORK/pool_u.txt"
if command -v shuf >/dev/null 2>&1; then
  shuf "$WORK/pool_u.txt" > "$WORK/pool_shuf.txt"
else
  sort -R "$WORK/pool_u.txt" > "$WORK/pool_shuf.txt" 2>/dev/null || cp "$WORK/pool_u.txt" "$WORK/pool_shuf.txt"
fi
head -"$MAX_CANDIDATES" "$WORK/pool_shuf.txt" > "$WORK/cands.txt"
log "candidates: $(wc -l < "$WORK/cands.txt") (cap $MAX_CANDIDATES)"

# --- 3. probe: a working CONNECT tunnel to the provider endpoint ------------
: > "$WORK/probe.txt"
probe_one() {
  hp="$1"
  t=$(curl -x "http://$hp" -m "$PROBE_TIMEOUT" -s -o /dev/null \
        -w '%{http_code} %{time_total}' "$PROBE_URL" 2>/dev/null)
  code="${t%% *}"
  if [ "$code" != "000" ] && [ -n "$code" ]; then
    echo "$hp $t" >> "$WORK/probe.txt"
  fi
}
export -f probe_one
export PROBE_URL PROBE_TIMEOUT WORK
if command -v xargs >/dev/null 2>&1; then
  timeout "$BUDGET_SECONDS" xargs -a "$WORK/cands.txt" -I{} -P "$PARALLEL" bash -c 'probe_one "$@"' _ {} 2>/dev/null
else
  while read -r hp; do probe_one "$hp"; done < "$WORK/cands.txt"
fi
log "reachable proxies: $(wc -l < "$WORK/probe.txt")"

# --- 4. pick: lowest latency whose egress IP really differs ----------------
SELECTED=""; LATENCY=""; EGRESS=""
if [ -s "$WORK/probe.txt" ]; then
  sort -k2 -n "$WORK/probe.txt" | cut -d' ' -f1,3 > "$WORK/probe_sorted.txt"
  while read -r hp lat; do
    eip=$(curl -x "http://$hp" -m 12 -s "$IP_URL" 2>/dev/null | tr -dc '0-9a-fA-F.:' | head -c 64)
    [ -z "$eip" ] && continue
    [ -n "$DIRECT_IP" ] && [ "$eip" = "$DIRECT_IP" ] && continue
    [ -n "$PREV_EGRESS" ] && [ "$eip" = "$PREV_EGRESS" ] && continue
    SELECTED="$hp"; LATENCY="$lat"; EGRESS="$eip"
    break
  done < "$WORK/probe_sorted.txt"
fi

# --- 5. export --------------------------------------------------------------
NO_PROXY_LIST="localhost,127.0.0.1,::1,api.telegram.org,github.com,api.github.com,objects.githubusercontent.com,raw.githubusercontent.com,codeload.github.com,registry.npmjs.org"

if [ -n "$SELECTED" ]; then
  {
    echo "HTTP_PROXY=http://${SELECTED}"
    echo "HTTPS_PROXY=http://${SELECTED}"
    echo "http_proxy=http://${SELECTED}"
    echo "https_proxy=http://${SELECTED}"
    echo "NO_PROXY=${NO_PROXY_LIST}"
    echo "no_proxy=${NO_PROXY_LIST}"
  } > "$ENV_FILE"
  log "selected http://${SELECTED} egress=${EGRESS} latency=${LATENCY}s"
else
  : > "$ENV_FILE"
  log "no usable proxy found; continuing on the direct connection (${DIRECT_IP:-unknown})"
fi

# --- 6. state for the TG bridge and the next run ----------------------------
cat > "$STATE_FILE" <<JSON
{
  "proxy": "${SELECTED}",
  "scheme": "http",
  "egress_ip": "${EGRESS}",
  "direct_ip": "${DIRECT_IP}",
  "latency_s": "${LATENCY}",
  "source": "public-proxy-pool",
  "picked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
chmod 600 "$STATE_FILE" 2>/dev/null || true

if [ -n "$SELECTED" ]; then
  echo "exit-proxy: http://${SELECTED} egress=${EGRESS} latency=${LATENCY}s"
else
  echo "exit-proxy: none (direct ${DIRECT_IP:-unknown})"
fi
exit 0
