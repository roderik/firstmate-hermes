#!/usr/bin/env bash
# Preflight host capabilities required by proof-producing work.
# Usage: fm-capability-check.sh --surface <browser|attachments|pool|seed|ci> [--project <dir>] [--command <cmd>]
set -eu
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { usage; exit 0; }
SURFACE='' PROJECT='' COMMAND=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --surface) [ "$#" -gt 1 ] || exit 2; SURFACE=$2; shift 2 ;;
    --project) [ "$#" -gt 1 ] || exit 2; PROJECT=$2; shift 2 ;;
    --command) [ "$#" -gt 1 ] || exit 2; COMMAND=$2; shift 2 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$SURFACE" in browser|attachments|pool|seed|ci) ;; *) echo 'error: --surface must be browser, attachments, pool, seed, or ci' >&2; exit 2 ;; esac
require_tool() { command -v "$1" >/dev/null 2>&1 || { echo "capability: $SURFACE unavailable - $1 is missing" >&2; exit 1; }; }
run_browser_probe() {
  if command -v timeout >/dev/null 2>&1; then timeout 20 chrome-devtools-axi pages >/dev/null 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout 20 chrome-devtools-axi pages >/dev/null 2>&1
  else chrome-devtools-axi pages >/dev/null 2>&1
  fi
}
case "$SURFACE" in
  browser)
    require_tool chrome-devtools-axi
    run_browser_probe || { echo 'capability: browser unavailable - chrome-devtools-axi could not drive a browser' >&2; exit 1; }
    ;;
  attachments)
    require_tool gh-axi
    gh-axi api --help 2>&1 | grep -Eiq 'multipart|upload|content-type' || { echo 'capability: attachments unavailable - gh-axi exposes no upload route' >&2; exit 1; }
    ;;
  pool)
    require_tool treehouse
    treehouse status 2>/dev/null | grep -Eiq '(^|[[:space:]])(available|free|idle)([[:space:]]|$)' || { echo 'capability: pool unavailable - no free worktree slot' >&2; exit 1; }
    ;;
  seed)
    [ -n "$PROJECT" ] || { echo 'capability: seed unavailable - --project is required' >&2; exit 1; }
    if [ -n "$COMMAND" ]; then
      (cd "$PROJECT" && bash -c -- "$COMMAND") || { echo 'capability: seed unavailable - declared seed command failed' >&2; exit 1; }
    elif [ -x "$PROJECT/.firstmate/seed-check" ]; then
      (cd "$PROJECT" && .firstmate/seed-check) || { echo 'capability: seed unavailable - .firstmate/seed-check failed' >&2; exit 1; }
    else
      echo 'capability: seed unavailable - project declares no seed check' >&2; exit 1
    fi
    ;;
  ci)
    require_tool no-mistakes
    no-mistakes daemon status >/dev/null 2>&1 || { echo 'capability: ci unavailable - no-mistakes daemon is not reachable' >&2; exit 1; }
    no-mistakes axi status >/dev/null 2>&1 || { echo 'capability: ci unavailable - no-mistakes axi is not ready' >&2; exit 1; }
    ;;
esac
printf 'capability: %s ready\n' "$SURFACE"
