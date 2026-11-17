#!/usr/bin/env bash
# R2766: recover rollover requests orphaned by an abruptly killed bridge.
#
# The tg-bridge claims a durable request with an atomic rename:
#   ses_x.json -> ses_x.json.claimed-<bot>-<pid>
# so sibling bridge instances cannot consume it twice. If the watcher kills the
# whole OpenCode process mid-rollover (a quota 429 is exactly what ends these
# rounds), the claimed file survives but the consumer only scans
# `ses_<id>.json`, so the request would be lost forever. The successor then
# restores a front session with no pending request and automatic rollover
# silently stops even though the user never cancelled it.
#
# This runs in failure_guard, i.e. after the OpenCode process (and therefore
# every bridge) has exited and before the run-end snapshot starts. At that
# point no live process can own a claim, so:
#   * claimed file without a base file -> put it back (request stays durable);
#   * claimed file whose base exists    -> drop the duplicate claim.
# Base request files are never modified. Safe to run with no directory/files.
set +e
REQ_DIR="${ROLLOVER_REQUEST_DIR:-${HOME:-/root}/.config/opencode/rollover-requests}"
[ -d "$REQ_DIR" ] || exit 0
recovered=0
dropped=0
for f in "$REQ_DIR"/*.json.claimed-*; do
  [ -e "$f" ] || continue
  base="${f%%.claimed-*}"
  if [ -e "$base" ]; then
    rm -f "$f" 2>/dev/null && dropped=$((dropped + 1))
    echo "dropped duplicate claimed rollover request: $(basename "$f")"
  elif mv -f "$f" "$base" 2>/dev/null; then
    recovered=$((recovered + 1))
    echo "recovered orphaned rollover claim: $(basename "$f") -> $(basename "$base")"
  else
    echo "::warning::could not recover orphaned rollover claim $(basename "$f")"
  fi
done
[ "$recovered" -gt 0 ] && echo "rollover claims recovered=$recovered dropped=$dropped"
exit 0
