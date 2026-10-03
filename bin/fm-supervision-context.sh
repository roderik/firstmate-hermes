#!/usr/bin/env bash
# Present one bounded, reusable supervision context for a wake.
#
# This is a presentation helper only. It runs fm-wake-drain.sh at most once for
# a queue/recovery generation, stores the result under state/supervision-context
# by content hash, and never acknowledges or makes a semantic decision.
# Repeating the command for the same generation reads the cached snapshot.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FORMAT=compact
FULL=0
SINCE_SEQ=

usage() {
  cat <<'EOF'
usage: fm-supervision-context.sh [--home FM_HOME] [--since-seq N] [--format compact|json] [--full]

Run one wake drain and print a bounded reusable supervision snapshot.
Snapshots are content-addressed under state/supervision-context and are reused
for the same queue and recovery generation. --full keeps the complete drain
presentation as the snapshot payload.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -gt 1 ] || { usage >&2; exit 2; }; FM_HOME=$2; STATE="$FM_HOME/state"; shift 2 ;;
    --since-seq) [ "$#" -gt 1 ] || { usage >&2; exit 2; }; SINCE_SEQ=$2; shift 2 ;;
    --format) [ "$#" -gt 1 ] || { usage >&2; exit 2; }; FORMAT=$2; shift 2 ;;
    --full) FULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-supervision-context: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$FORMAT" in compact|json) ;; *) echo "fm-supervision-context: --format must be compact or json" >&2; exit 2 ;; esac
case "$SINCE_SEQ" in ''|*[!0-9]*) [ -z "$SINCE_SEQ" ] || { echo "fm-supervision-context: invalid --since-seq" >&2; exit 2; } ;; esac

SNAP_DIR="$STATE/supervision-context"
INDEX="$SNAP_DIR/index.tsv"
mkdir -p "$SNAP_DIR" || exit 1
QUEUE="$STATE/wake-queue"
MARKER="$STATE/.watcher-down"
OUT_TMP=$(mktemp "$SNAP_DIR/.drain.XXXXXX") || exit 1
ERR_TMP=$(mktemp "$SNAP_DIR/.drain-err.XXXXXX") || { rm -f "$OUT_TMP"; exit 1; }
KEY_TMP=$(mktemp "$SNAP_DIR/.key.XXXXXX") || { rm -f "$OUT_TMP" "$ERR_TMP"; exit 1; }
trap 'rm -f -- "$OUT_TMP" "$ERR_TMP" "$KEY_TMP"' EXIT

# Queue and marker are the generation boundary. A newly appended wake changes
# the queue hash; an acknowledgement or recovery transition changes the marker.
{
  printf 'format=%s\nfull=%s\nsince=%s\n' "$FORMAT" "$FULL" "${SINCE_SEQ:-}"
  if [ -f "$QUEUE" ]; then sha256sum "$QUEUE"; else printf 'queue=absent\n'; fi
  if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then sha256sum "$MARKER" 2>/dev/null || printf 'marker=unreadable\n'; else printf 'marker=absent\n'; fi
} > "$KEY_TMP"
KEY=$(sha256sum "$KEY_TMP" | awk '{print $1}') || exit 1

SNAPSHOT=
if [ -f "$INDEX" ]; then
  SNAPSHOT=$(awk -F '\t' -v key="$KEY" -v fmt="$FORMAT" -v full="$FULL" '$1 == key && $2 == fmt && $3 == full { print $4; exit }' "$INDEX")
fi
if [ -n "$SNAPSHOT" ] && [ -f "$SNAPSHOT" ]; then
  if [ "$FORMAT" = json ]; then cat "$SNAPSHOT"; else cat "$SNAPSHOT"; fi
  exit 0
fi

# Capture both streams so the exact generation-bound acknowledgement is part of
# the reusable record without leaking an unbounded child presentation.
set +e
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-wake-drain.sh" >"$OUT_TMP" 2>"$ERR_TMP"
DRAIN_RC=$?
set -e

CAP=$([ "$FULL" -eq 1 ] && printf 104857600 || printf 32768)
# Keep complete lines and cap the payload at a predictable byte bound. The raw
# drain already owns semantic section names and exact commands; this layer only
# labels and bounds them for callers.
PAYLOAD_TMP=$(mktemp "$SNAP_DIR/.payload.XXXXXX") || exit 1
{
  printf 'wake rows / event paths / latest task events / open decisions / unread status / branch outcomes / divergence:\n'
  # fm-wake-drain already owns the section folding and ordering. Preserve it
  # once here; --since-seq only drops older tabular wake rows.
  awk -v since="${SINCE_SEQ:-0}" '/^[[:space:]]*[0-9]+\t[0-9]+\t/ { if ($2 + 0 > since) print; next } { print }' "$OUT_TMP"
  printf 'acknowledgement and processing commands:\n'
  grep -hE 'WAKE_ACK_REQUIRED|mark-processed' "$OUT_TMP" "$ERR_TMP" 2>/dev/null || true
  printf 'drain-exit: %s\n' "$DRAIN_RC"
} | awk -v cap="$CAP" 'BEGIN { bytes=0 } { line=$0 ORS; if (bytes + length(line) <= cap) { printf "%s", line; bytes += length(line) } else if (!truncated++) { printf "... snapshot payload truncated at %d bytes ...\n", cap } }' > "$PAYLOAD_TMP"

if [ "$FORMAT" = compact ]; then
  SNAPSHOT_PAYLOAD=$(cat "$PAYLOAD_TMP")
else
  # jq is part of the Firstmate runtime and gives correct escaping for tabs and
  # multiline drain payloads without a second, bespoke JSON encoder.
  SNAPSHOT_PAYLOAD=$(jq -Rs --arg key "$KEY" --argjson exit "$DRAIN_RC" \
    '{snapshot_key:$key,drain_exit:$exit,record: .}' "$PAYLOAD_TMP") || { rm -f "$PAYLOAD_TMP"; exit 1; }
fi
HASH=$(printf '%s' "$SNAPSHOT_PAYLOAD" | sha256sum | awk '{print $1}') || { rm -f "$PAYLOAD_TMP"; exit 1; }
SNAPSHOT="$SNAP_DIR/$HASH.$FORMAT"
printf '%s' "$SNAPSHOT_PAYLOAD" > "$SNAPSHOT.tmp" || { rm -f "$PAYLOAD_TMP"; exit 1; }
mv -f -- "$SNAPSHOT.tmp" "$SNAPSHOT" || { rm -f "$PAYLOAD_TMP"; exit 1; }
printf '%s\t%s\t%s\t%s\n' "$KEY" "$FORMAT" "$FULL" "$SNAPSHOT" >> "$INDEX"
# The first drain may create the recovery marker, changing the pre-drain key.
# Alias the post-drain generation to this same immutable snapshot so a repeated
# call for the wake does not drain again merely because handling began.
{
  if [ -f "$QUEUE" ]; then sha256sum "$QUEUE"; else printf 'queue=absent\n'; fi
  if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then sha256sum "$MARKER" 2>/dev/null || printf 'marker=unreadable\n'; else printf 'marker=absent\n'; fi
} > "$KEY_TMP"
POST_KEY=$(sha256sum "$KEY_TMP" | awk '{print $1}')
printf '%s\t%s\t%s\t%s\n' "$POST_KEY" "$FORMAT" "$FULL" "$SNAPSHOT" >> "$INDEX"
rm -f "$PAYLOAD_TMP"
cat "$SNAPSHOT"
exit "$DRAIN_RC"
