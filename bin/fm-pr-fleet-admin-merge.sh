#!/usr/bin/env bash
# Admin-merge a fleet-authored GitHub PR only when fm-pr-fleet-merge-eligible.sh
# returns true (deterministic GraphQL gates).
#
# Usage:
#   fm-pr-fleet-admin-merge.sh <pr-url>
#   fm-pr-fleet-admin-merge.sh --repo owner/name <n>
#
# Optional: FM_FLEET_PR_AUTHORS=person-a
# Optional: FM_FLEET_MERGE_DRY_RUN=1  — print eligible + would-merge, no merge
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-fleet-config.sh
. "$SCRIPT_DIR/fm-fleet-config.sh"
fm_fleet_config_load || true
ELIGIBLE="$SCRIPT_DIR/fm-pr-fleet-merge-eligible.sh"

[ -x "$ELIGIBLE" ] || chmod +x "$ELIGIBLE" || true
command -v "$FM_FLEET_GH_BIN" >/dev/null || { echo "error: gh required" >&2; exit 2; }

OUT=$("$ELIGIBLE" "$@" 2>/tmp/fm-fleet-elig.err) || {
  cat /tmp/fm-fleet-elig.err >&2
  exit 1
}
cat /tmp/fm-fleet-elig.err >&2 || true
echo "$OUT"

# Parse true owner/name#n
if [[ ! "$OUT" =~ ^true\ ([^/]+)/([^#]+)#([0-9]+) ]]; then
  echo "error: unexpected eligible output: $OUT" >&2
  exit 2
fi
OWNER="${BASH_REMATCH[1]}"
NAME="${BASH_REMATCH[2]}"
NUMBER="${BASH_REMATCH[3]}"
URL="https://github.com/${OWNER}/${NAME}/pull/${NUMBER}"

if [ "${FM_FLEET_MERGE_DRY_RUN:-0}" = 1 ]; then
  echo "dry-run: would admin-merge $URL"
  exit 0
fi

# Re-check eligibility immediately before merge (TOCTOU bound)
"$ELIGIBLE" "$URL" >/dev/null || {
  echo "error: became ineligible before merge" >&2
  exit 1
}

# Admin merge: squash to match fleet default, delete branch
"$FM_FLEET_GH_BIN" pr merge "$NUMBER" -R "${OWNER}/${NAME}" --admin --squash --delete-branch
echo "merged: $URL"
