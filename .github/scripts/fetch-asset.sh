#!/usr/bin/env bash
# fetch-asset.sh — download release assets with multi-range parallelism (R341).
#
# Usage: fetch-asset.sh <owner/repo> <tag> <name-glob> <outdir>
#
# Downloads every asset of <tag> whose name matches the shell glob <name-glob>
# into <outdir>. Byte content is identical to `gh release download`:
#   * small assets (< FETCH_ASSET_MIN bytes, default 32 MiB) use one streaming GET;
#   * larger assets are fetched as FETCH_ASSET_JOBS parallel byte-range requests
#     through the release asset API and reassembled in order, then size-checked.
# On any failure the asset falls back to plain `gh release download` so callers
# keep the previous single-stream behaviour if parallelism is unavailable.
# Exit status: 0 = every matched asset present, 1 = nothing matched or a fetch failed.
#
# R2773 (operator: "上一轮ci的环境还原耗时特别长"): every curl/gh call used to be
# unbounded. One half-open TCP connection could hold the whole CI restore open
# until a human cancelled the run. Each range request now has a hard timeout,
# the single-stream fallback is bounded too, and the whole invocation stops at
# FETCH_ASSET_DEADLINE (default 420s). The log names the asset and its size
# before the transfer starts so a 607MB env fallback is visible immediately.
set -u

REPO="${1:?usage: fetch-asset.sh <owner/repo> <tag> <name-glob> <outdir>}"
TAG="${2:?tag}"
PATTERN="${3:?name glob}"
OUT="${4:?outdir}"

mkdir -p "$OUT"
JOBS="${FETCH_ASSET_JOBS:-8}"
MIN_PARALLEL="${FETCH_ASSET_MIN:-33554432}"   # 32 MiB
DEADLINE_SECS="${FETCH_ASSET_DEADLINE:-420}"
MAX_TIME="${FETCH_ASSET_MAX_TIME:-90}"
SINGLE_TIMEOUT="${FETCH_ASSET_SINGLE_TIMEOUT:-240}"
case "$JOBS" in (*[!0-9]*|'') JOBS=8 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
case "$MIN_PARALLEL" in (*[!0-9]*|'') MIN_PARALLEL=33554432 ;; esac
case "$DEADLINE_SECS" in (*[!0-9]*|'') DEADLINE_SECS=420 ;; esac
case "$MAX_TIME" in (*[!0-9]*|'') MAX_TIME=90 ;; esac
case "$SINGLE_TIMEOUT" in (*[!0-9]*|'') SINGLE_TIMEOUT=240 ;; esac

T0=$(date +%s)
remaining() {
  local left=$(( DEADLINE_SECS - ( $(date +%s) - T0 ) ))
  [ "$left" -gt 0 ] && printf '%s\n' "$left" || printf '0\n'
}

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN="$(gh auth token 2>/dev/null || true)"
AUTH_H="Authorization: Bearer $TOKEN"

meta="$(timeout --kill-after=10 30 gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | [.name, .id, .size] | @tsv' 2>/dev/null)" || exit 1
[ -n "$meta" ] || exit 1

fetch_parallel() {  # name id size -> 0 ok / 1 failed
  local name="$1" id="$2" size="$3" chunk parts nchunks t0 left mt
  parts="$OUT/.parts.$$.$name"
  rm -rf "$parts"; mkdir -p "$parts"
  chunk=$(( (size + JOBS - 1) / JOBS )); [ "$chunk" -ge 1 ] || chunk=1
  nchunks=$(( (size + chunk - 1) / chunk ))
  left=$(remaining)
  [ "$left" -gt 0 ] || { echo "::error::[fetch-asset] deadline ${DEADLINE_SECS}s reached before $name" >&2; return 1; }
  mt="$MAX_TIME"; [ "$mt" -gt "$left" ] && mt="$left"
  [ "$mt" -ge 10 ] || mt=10
  t0=$(date +%s)
  echo "[fetch-asset] $name: start ($size bytes, $nchunks range(s), ${mt}s cap each, deadline ${DEADLINE_SECS}s)" >&2
  if seq 0 $(( nchunks - 1 )) \
       | SIZE="$size" CHUNK="$chunk" REPO="$REPO" ID="$id" PARTS="$parts" AUTH_H="$AUTH_H" MAX_TIME="$mt" \
         xargs -P "$JOBS" -I CX bash -c '
             i=CX; s=$(( i * CHUNK )); [ "$s" -lt "$SIZE" ] || exit 0
             e=$(( s + CHUNK - 1 )); [ "$e" -lt "$SIZE" ] || e=$(( SIZE - 1 ))
             timeout --signal=TERM --kill-after=5 "$MAX_TIME" \
               curl -sfL --retry 1 --connect-timeout 10 \
               -H "$AUTH_H" -H "Accept: application/octet-stream" \
               -r "$s-$e" "https://api.github.com/repos/$REPO/releases/assets/$ID" \
               -o "$PARTS/part-$(printf %04d "$i")"
           '; then
    if cat "$parts"/part-* > "$OUT/$name" 2>/dev/null \
       && [ "$(stat -c%s "$OUT/$name" 2>/dev/null || echo 0)" = "$size" ]; then
      echo "[fetch-asset] $name: $size bytes via $nchunks parallel range(s) in $(( $(date +%s) - t0 ))s" >&2
      rm -rf "$parts"
      return 0
    fi
  fi
  rm -rf "$parts" "$OUT/$name" 2>/dev/null
  echo "::warning::[fetch-asset] parallel fetch failed/timed out for $name (falling back to single stream)" >&2
  return 1
}

fail=0
matched=0
while IFS=$'\t' read -r name id size; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2254  # $PATTERN is intentionally an unquoted glob here
  case "$name" in $PATTERN) ;; *) continue ;; esac
  matched=1
  got=0
  if [ -n "$id" ] && [ -n "$size" ] && [ -z "${size//[0-9]/}" ] && [ "$size" -ge "$MIN_PARALLEL" ]; then
    fetch_parallel "$name" "$id" "$size" && got=1
  fi
  if [ "$got" != 1 ]; then
    left=$(remaining)
    if [ "$left" -le 0 ]; then
      echo "::error::[fetch-asset] deadline ${DEADLINE_SECS}s reached before single-stream $name" >&2
      fail=1
      continue
    fi
    st="$SINGLE_TIMEOUT"; [ "$st" -gt "$left" ] && st="$left"
    echo "[fetch-asset] $name: single-stream fallback (${st}s cap)" >&2
    if timeout --signal=TERM --kill-after=15 "$st" \
         gh release download "$TAG" --repo "$REPO" --pattern "$name" --dir "$OUT" --clobber >/dev/null 2>&1; then
      echo "[fetch-asset] $name: single-stream download ok ($size bytes) in $(( $(date +%s) - T0 ))s total" >&2
    else
      echo "::warning::[fetch-asset] $name: single-stream download failed/timed out (${st}s cap)" >&2
      fail=1
    fi
  fi
done <<< "$meta"

[ "$matched" = 1 ] || exit 1
if [ "$fail" = 0 ]; then
  echo "[fetch-asset] $TAG: all matched assets ready in $(( $(date +%s) - T0 ))s" >&2
fi
exit "$fail"
