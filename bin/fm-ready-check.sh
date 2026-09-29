#!/usr/bin/env bash
# Run a project's declared handoff check before Firstmate records a ship ready.
# Usage: fm-ready-check.sh <worktree> [--command <command>]
# Projects opt in with an executable .firstmate/ready-check file or a package.json
# script named pr:ready-check (ready-check is accepted for older projects).
# An explicit --command is intended for the project declaration already resolved
# by a caller; it is never inferred from a task, PR body, or worker prose.
set -eu

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { usage; exit 0; }
[ "$#" -ge 1 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
WORKTREE=$1
shift
COMMAND=
if [ "${1:-}" = --command ]; then
  [ "$#" -eq 2 ] || { echo 'error: --command requires one value' >&2; exit 2; }
  COMMAND=$2
elif [ "$#" -ne 0 ]; then
  echo 'error: expected --command <command>' >&2
  exit 2
fi
[ -d "$WORKTREE" ] || { echo "ready-check: worktree is missing: $WORKTREE" >&2; exit 1; }
WORKTREE=$(cd "$WORKTREE" && pwd -P)

if [ -z "$COMMAND" ] && [ -x "$WORKTREE/.firstmate/ready-check" ]; then
  COMMAND="$WORKTREE/.firstmate/ready-check"
fi
if [ -z "$COMMAND" ] && [ -f "$WORKTREE/package.json" ] && command -v jq >/dev/null 2>&1; then
  script=$(jq -r '.scripts["pr:ready-check"] // .scripts["ready-check"] // empty' "$WORKTREE/package.json" 2>/dev/null || true)
  if [ -n "$script" ]; then
    if [ -f "$WORKTREE/bun.lock" ] || [ -f "$WORKTREE/bun.lockb" ]; then
      COMMAND='bun run pr:ready-check'
      jq -e '.scripts["pr:ready-check"]' "$WORKTREE/package.json" >/dev/null 2>&1 || COMMAND='bun run ready-check'
    elif [ -f "$WORKTREE/pnpm-lock.yaml" ]; then
      COMMAND='pnpm run pr:ready-check'
      jq -e '.scripts["pr:ready-check"]' "$WORKTREE/package.json" >/dev/null 2>&1 || COMMAND='pnpm run ready-check'
    else
      COMMAND='npm run pr:ready-check'
      jq -e '.scripts["pr:ready-check"]' "$WORKTREE/package.json" >/dev/null 2>&1 || COMMAND='npm run ready-check'
    fi
  fi
fi
if [ -z "$COMMAND" ]; then
  printf 'ready-check: not declared for %s (handoff gate not applicable)\n' "$WORKTREE"
  exit 0
fi
case "$COMMAND" in
  *[[:cntrl:]]*) echo 'ready-check: declaration contains control characters' >&2; exit 1 ;;
esac
printf 'ready-check: running %s\n' "$COMMAND" >&2
if (cd "$WORKTREE" && bash -c -- "$COMMAND"); then
  printf 'ready-check: passed\n'
else
  rc=$?
  printf 'ready-check: failed (exit %s)\n' "$rc" >&2
  exit "$rc"
fi
