#!/usr/bin/env bash
# Run a project's declared handoff check before Firstmate records a ship ready.
# Usage: fm-ready-check.sh <project> <worktree> [<head> [<pr-number-or-branch>]]
# The declaration is read from the registered project checkout, never from the
# worker's branch: an executable .firstmate/ready-check or a package.json script
# named pr:ready-check. The declared check then runs inside the worker worktree;
# a package script whose text differs on the worker's branch is refused.
# A pr:ready-check script receives one argument: <pr-number-or-branch> when
# given (callers pass the PR number once a PR is known), else the worktree's
# current branch name; it gets no argument only on a detached worktree.
# A declared check runs only on a clean worktree, and only at <head> when given,
# so it judges the committed content that ships rather than uncommitted files.
# The check is bounded by FM_READY_CHECK_TIMEOUT seconds (default 1800).
set -eu

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { usage; exit 0; }
[ "$#" -ge 2 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
PROJECT=$1
WORKTREE=$2
HEAD_SHA=${3:-}
TARGET=${4:-}
[ -d "$PROJECT" ] || { echo "ready-check: project checkout is missing: $PROJECT" >&2; exit 1; }
[ -d "$WORKTREE" ] || { echo "ready-check: worktree is missing: $WORKTREE" >&2; exit 1; }
PROJECT=$(cd "$PROJECT" && pwd -P)
WORKTREE=$(cd "$WORKTREE" && pwd -P)
TIMEOUT=${FM_READY_CHECK_TIMEOUT:-1800}
case "$TIMEOUT" in ''|*[!0-9]*|0) echo 'ready-check: FM_READY_CHECK_TIMEOUT must be a positive integer' >&2; exit 2 ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

package_script() {  # <package.json>
  jq -r '.scripts["pr:ready-check"] // empty' "$1" 2>/dev/null || true
}

CMD=()
if [ -x "$PROJECT/.firstmate/ready-check" ]; then
  CMD=("$PROJECT/.firstmate/ready-check")
elif [ -f "$PROJECT/package.json" ] && grep -q '"pr:ready-check"' "$PROJECT/package.json"; then
  command -v jq >/dev/null 2>&1 || { echo 'ready-check: jq is required to read the declared pr:ready-check script' >&2; exit 1; }
  script=$(package_script "$PROJECT/package.json")
  if [ -n "$script" ]; then
    [ -f "$WORKTREE/package.json" ] && [ "$(package_script "$WORKTREE/package.json")" = "$script" ] \
      || { echo 'ready-check: pr:ready-check on the worker branch differs from the project declaration' >&2; exit 1; }
    if [ -f "$PROJECT/bun.lock" ] || [ -f "$PROJECT/bun.lockb" ]; then
      CMD=(bun run pr:ready-check)
    elif [ -f "$PROJECT/pnpm-lock.yaml" ]; then
      CMD=(pnpm run pr:ready-check)
    else
      CMD=(npm run pr:ready-check)
    fi
    [ -n "$TARGET" ] || TARGET=$(git -C "$WORKTREE" branch --show-current 2>/dev/null || true)
    [ -z "$TARGET" ] || CMD+=("$TARGET")
  fi
fi
if [ "${#CMD[@]}" -eq 0 ]; then
  printf 'ready-check: not declared for %s (handoff gate not applicable)\n' "$PROJECT"
  exit 0
fi
[ -z "$(git -C "$WORKTREE" status --porcelain 2>/dev/null | head -1)" ] \
  || { echo 'ready-check: worktree has uncommitted or untracked changes; commit them before handoff' >&2; exit 1; }
[ -z "$HEAD_SHA" ] || [ "$(git -C "$WORKTREE" rev-parse --verify --quiet 'HEAD^{commit}' || true)" = "$HEAD_SHA" ] \
  || { echo "ready-check: worktree HEAD is not the handed-off head $HEAD_SHA; fetch and check it out before handoff" >&2; exit 1; }
printf 'ready-check: running %s\n' "${CMD[*]}" >&2
rc=0
(cd "$WORKTREE" && fm_run_timed "$TIMEOUT" "${CMD[@]}") || rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'ready-check: passed\n'
elif fm_timed_out "$rc"; then
  printf 'ready-check: timed out after %ss\n' "$TIMEOUT" >&2
  exit "$rc"
else
  printf 'ready-check: failed (exit %s)\n' "$rc" >&2
  exit "$rc"
fi
