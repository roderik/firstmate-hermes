#!/usr/bin/env bash
# Present one bounded supervision context for a wake.
#
# This is a presentation helper only. Every invocation runs fm-wake-drain.sh
# exactly once, bounds and labels its output, and never acknowledges or makes a
# semantic decision.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP=32768

case "${1:-}" in
  '') ;;
  -h|--help) echo "usage: fm-supervision-context.sh"; exit 0 ;;
  *) echo "fm-supervision-context: unknown argument: $1" >&2; echo "usage: fm-supervision-context.sh" >&2; exit 2 ;;
esac

OUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-supervision-context.XXXXXX") || exit 1
ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-supervision-context-err.XXXXXX") || { rm -f "$OUT_TMP"; exit 1; }
trap 'rm -f -- "$OUT_TMP" "$ERR_TMP"' EXIT

"$SCRIPT_DIR/fm-wake-drain.sh" >"$OUT_TMP" 2>"$ERR_TMP"
DRAIN_RC=$?

# Keep complete lines and cap the payload at a predictable byte bound. The raw
# drain already owns semantic section names and exact commands; this layer only
# labels and bounds them for callers.
{
  printf 'wake rows / event paths / latest task events / open decisions / unread status / branch outcomes / divergence:\n'
  cat "$OUT_TMP"
  printf 'acknowledgement and processing commands:\n'
  grep -hE 'WAKE_ACK_REQUIRED|mark-processed' "$OUT_TMP" "$ERR_TMP" 2>/dev/null || true
  printf 'drain-exit: %s\n' "$DRAIN_RC"
} | awk -v cap="$CAP" 'BEGIN { bytes=0 } { line=$0 ORS; if (bytes + length(line) <= cap) { printf "%s", line; bytes += length(line) } else if (!truncated++) { printf "... snapshot payload truncated at %d bytes ...\n", cap } }'
exit "$DRAIN_RC"
