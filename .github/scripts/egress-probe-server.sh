#!/usr/bin/env bash
# Managed zengate + local CONNECT proxy used only for egress validation.
# zengate creates a fresh OpenCode session for every probe request, so each
# candidate IP is checked with a real client and a new conversation.
#
# Usage: egress-probe-server.sh start|stop|ready
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-${RUNNER_TEMP:-/tmp}/egress}"
export EGRESS_STATE_DIR
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

PROBE_DIR="${EGRESS_PROBE_DIR:-$EGRESS_STATE_DIR/probe}"
PROBE_PORT="${EGRESS_PROBE_PORT:-8091}"
ZG_PORT="${EGRESS_ZENGATE_PORT:-18083}"
PIDFILE="$PROBE_DIR/server.pid"
PROXY_LOG="$PROBE_DIR/proxy.log"
ZG_LOG="$PROBE_DIR/zengate.log"
mkdir -p "$PROBE_DIR"

log() { echo "[egress-probe] $*"; }

proxy_ready() {
  local code
  code=$(curl -sS -m 1 --noproxy '*' -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${PROBE_PORT}" 2>/dev/null || true)
  [ -n "$code" ] && [ "$code" != "000" ]
}

zg_ready() {
  curl -fsS -m 2 --noproxy '*' -o /dev/null \
    "http://127.0.0.1:${ZG_PORT}/ready" 2>/dev/null
}

stop() {
  if [ -f "$PIDFILE" ]; then
    read -r p_pid z_pid < "$PIDFILE" || true
    for pid in "${z_pid:-}" "${p_pid:-}"; do
      [ -n "$pid" ] || continue
      kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${z_pid:-}" "${p_pid:-}"; do
      [ -n "$pid" ] || continue
      kill -9 "$pid" 2>/dev/null || true
    done
    rm -f "$PIDFILE"
  fi
}

start() {
  if proxy_ready && zg_ready; then
    log "already ready proxy=127.0.0.1:${PROBE_PORT} zengate=127.0.0.1:${ZG_PORT}"
    return 0
  fi
  stop
  command -v zengate >/dev/null 2>&1 || { log "zengate binary not found"; return 1; }
  command -v python3 >/dev/null 2>&1 || { log "python3 not found"; return 1; }
  printf 'direct\n' > "$PROBE_DIR/upstream"
  echo 0 > "$PROBE_DIR/epoch"
  EGRESS_LOCAL_PORT="$PROBE_PORT" EGRESS_STATE_DIR="$PROBE_DIR" \
    python3 "$SCRIPT_DIR/egress-proxy.py" > "$PROXY_LOG" 2>&1 &
  p_pid=$!
  for _ in $(seq 1 50); do
    proxy_ready && break
    kill -0 "$p_pid" 2>/dev/null || { log "probe proxy died"; tail -20 "$PROXY_LOG"; return 1; }
    sleep 0.2
  done
  proxy_ready || { log "probe proxy did not listen"; kill "$p_pid" 2>/dev/null; return 1; }
  local proxy_url="http://127.0.0.1:${PROBE_PORT}"
  env HOST=127.0.0.1 PORT="$ZG_PORT" ALLOW_NO_AUTH=true \
    LOG_LEVEL=warn REQUEST_TIMEOUT_MS="${EGRESS_PROBE_REQUEST_TIMEOUT_MS:-20000}" \
    MAX_CONCURRENT="${EGRESS_PROBE_CONCURRENCY:-1}" \
    HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" \
    http_proxy="$proxy_url" https_proxy="$proxy_url" \
    NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost" \
    zengate > "$ZG_LOG" 2>&1 &
  z_pid=$!
  printf '%s %s\n' "$p_pid" "$z_pid" > "$PIDFILE"
  for _ in $(seq 1 120); do
    zg_ready && { log "ready proxy=127.0.0.1:${PROBE_PORT} zengate=127.0.0.1:${ZG_PORT}"; return 0; }
    kill -0 "$z_pid" 2>/dev/null || { log "zengate died during startup"; tail -40 "$ZG_LOG"; stop; return 1; }
    sleep 1
  done
  log "zengate did not become ready"
  tail -40 "$ZG_LOG" 2>/dev/null || true
  stop
  return 1
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  ready) proxy_ready && zg_ready ;;
  *) echo "usage: $0 start|stop|ready" >&2; exit 64 ;;
esac
