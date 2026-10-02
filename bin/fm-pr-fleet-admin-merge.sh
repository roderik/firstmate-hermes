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
#
# The merge method is merge_method from fleet-watch.json; without one, the
# first method the repository allows, in the order squash, merge, rebase.
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

METHOD="${FM_FLEET_MERGE_METHOD:-}"
if [ -z "$METHOD" ]; then
  # shellcheck disable=SC2016 # GraphQL variables are interpreted by GitHub, not the shell
  METHOD=$("$FM_FLEET_GH_BIN" api graphql \
    -f query='query($o:String!,$n:String!){repository(owner:$o,name:$n){squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed}}' \
    -f o="$OWNER" -f n="$NAME" 2>/dev/null | jq -r '.data.repository
      | if .squashMergeAllowed then "squash" elif .mergeCommitAllowed then "merge" elif .rebaseMergeAllowed then "rebase" else empty end') || METHOD=""
  [ -n "$METHOD" ] || { echo "error: could not resolve an allowed merge method for $OWNER/$NAME" >&2; exit 2; }
fi

if [ "${FM_FLEET_MERGE_DRY_RUN:-0}" = 1 ]; then
  echo "dry-run: would admin-merge $URL with --$METHOD"
  exit 0
fi

# Re-check eligibility immediately before merge (TOCTOU bound)
"$ELIGIBLE" "$URL" >/dev/null || {
  echo "error: became ineligible before merge" >&2
  exit 1
}

"$FM_FLEET_GH_BIN" pr merge "$NUMBER" -R "${OWNER}/${NAME}" --admin "--$METHOD" --delete-branch
echo "merged: $URL"
