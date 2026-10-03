#!/usr/bin/env bash
# Present one labeled supervision context for a wake.
#
# This is a presentation helper only. Every invocation runs fm-wake-drain.sh
# exactly once, labels its output, and never acknowledges or makes a
# semantic decision.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# The raw drain already owns semantic section names and exact commands; this
# layer only labels them. The output is never truncated: the acknowledgement
# covers every drained wake row, so every row must be presented. Drain stderr
# carries the acknowledgement and the guard's watcher-down and worktree-tangle
# alarms, so it leads the payload.
{
  printf 'drain-exit: %s\n' "$DRAIN_RC"
  printf 'diagnostics and acknowledgement:\n'
  cat "$ERR_TMP"
  printf 'wake rows / event paths / latest task events / open decisions / unread status / branch outcomes / divergence:\n'
  cat "$OUT_TMP"
  printf 'processing commands:\n'
  grep -hE 'mark-processed' "$OUT_TMP" 2>/dev/null || true
}
exit "$DRAIN_RC"
