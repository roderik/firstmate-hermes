#!/usr/bin/env bash
# Preflight host capabilities required by proof-producing work.
# Usage: fm-capability-check.sh --surface <browser|attachments|pool|seed|ci> --project <dir>
# Tool-backed surfaces probe inside the project checkout: pool needs a readable
# treehouse pool, and ci needs a reachable no-mistakes daemon and an initialized
# repo. Upload and seed routes are project-specific, so attachments and seed run
# the project's executable .firstmate/attachments-check or .firstmate/seed-check.
set -eu
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { usage; exit 0; }
SURFACE='' PROJECT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --surface) [ "$#" -gt 1 ] || exit 2; SURFACE=$2; shift 2 ;;
    --project) [ "$#" -gt 1 ] || exit 2; PROJECT=$2; shift 2 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$SURFACE" in browser|attachments|pool|seed|ci) ;; *) echo 'error: --surface must be browser, attachments, pool, seed, or ci' >&2; exit 2 ;; esac
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || { echo 'error: --project must name the project checkout' >&2; exit 2; }
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
require_tool() { command -v "$1" >/dev/null 2>&1 || { echo "capability: $SURFACE unavailable - $1 is missing" >&2; exit 1; }; }
cd "$PROJECT"
case "$SURFACE" in
  browser)
    require_tool chrome-devtools-axi
    fm_run_timed 20 chrome-devtools-axi pages >/dev/null 2>&1 || { echo 'capability: browser unavailable - chrome-devtools-axi could not drive a browser' >&2; exit 1; }
    ;;
  attachments|seed)
    [ -x ".firstmate/$SURFACE-check" ] || { echo "capability: $SURFACE unavailable - project declares no .firstmate/$SURFACE-check" >&2; exit 1; }
    ".firstmate/$SURFACE-check" || { echo "capability: $SURFACE unavailable - .firstmate/$SURFACE-check failed" >&2; exit 1; }
    ;;
  pool)
    require_tool treehouse
    treehouse status >/dev/null 2>&1 || { echo 'capability: pool unavailable - treehouse cannot read the project pool' >&2; exit 1; }
    ;;
  ci)
    require_tool no-mistakes
    no-mistakes daemon status >/dev/null 2>&1 || { echo 'capability: ci unavailable - no-mistakes daemon is not reachable' >&2; exit 1; }
    no-mistakes axi status >/dev/null 2>&1 || { echo 'capability: ci unavailable - no-mistakes is not ready for this project' >&2; exit 1; }
    ;;
esac
printf 'capability: %s ready\n' "$SURFACE"
