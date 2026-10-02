#!/usr/bin/env bash
# Condition for a fleet-wide merge watch: exit 0 when at least one open,
# non-draft PR by a fleet author in the repo passes
# fm-pr-fleet-merge-eligible.sh; exit 1 when none does; any other exit is an
# error. Prints the eligible PR URLs on stdout, one per line.
#
# Usage: fm-pr-fleet-any-eligible.sh [owner/repo]
# Optional: FM_FLEET_PR_AUTHORS=person-a
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-fleet-config.sh
. "$SCRIPT_DIR/fm-fleet-config.sh"
fm_fleet_config_load || true
REPO=${1:-${FM_FLEET_REPO:-}}
AUTHOR=${FM_FLEET_PR_AUTHORS:-${FM_FLEET_AUTHORS:-}}
[ -n "$REPO" ] || { echo "error: configure repo in fleet-watch.json or pass owner/name" >&2; exit 2; }
[ -n "$AUTHOR" ] || { echo "error: configure at least one author in fleet-watch.json or FM_FLEET_PR_AUTHORS" >&2; exit 2; }
ELIGIBLE="$SCRIPT_DIR/fm-pr-fleet-merge-eligible.sh"

found=1
HOLD="${FM_FLEET_HOLD_FILE:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)/config}}/fleet-merge-hold.txt}"
IFS=',' read -r -a authors <<<"$AUTHOR"
for author in "${authors[@]}"; do
  author=${author// /}
  [ -n "$author" ] || continue
  numbers=$("$FM_FLEET_GH_BIN" pr list --repo "$REPO" --author "$author" --state open --limit 100 \
    --json number,isDraft \
    --jq '.[] | select(.isDraft | not) | .number') || exit 2
  for n in $numbers; do
  if [ -f "$HOLD" ] && grep -qxF "$n" "$HOLD"; then continue; fi
  if "$ELIGIBLE" "https://github.com/$REPO/pull/$n" >/dev/null 2>&1; then
    echo "https://github.com/$REPO/pull/$n"
    found=0
  fi
  done
done
exit "$found"
