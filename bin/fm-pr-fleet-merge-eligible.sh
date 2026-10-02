#!/usr/bin/env bash
# Deterministic GraphQL-only eligibility for fleet admin-merge of a GitHub PR.
# Exit 0 = eligible (true). Exit 1 = not eligible (false). Exit 2 = usage/error.
#
# Mechanical gates (all required, no LLM):
#   1. PR author login is in the configured allowlist.
#   2. not a draft
#   3. mergeable == MERGEABLE
#   4. reviewDecision != CHANGES_REQUESTED  (APPROVED / empty / REVIEW_REQUIRED OK)
#   5. every reviewThreads[].isResolved == true (or no threads)
#   6. latest commit statusCheckRollup.state == SUCCESS
#   7. mergeStateStatus != BEHIND (the branch contains the current base)
#   8. the PR targets the repository's default branch
#   9. every configured required test check has at least one SUCCESS run on
#      the head; a skipped-only check does not count. With none configured,
#      the rollup gate alone decides.
#
# Usage:
#   fm-pr-fleet-merge-eligible.sh <pr-url-or-owner/repo#n-or-n with -R>
#   fm-pr-fleet-merge-eligible.sh --repo owner/name 123
#   FM_FLEET_PR_AUTHORS=person-a,person-b fm-pr-fleet-merge-eligible.sh ...
#
# The result is a mechanical gate; other tools may advise but cannot override a false result.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-fleet-config.sh
. "$SCRIPT_DIR/fm-fleet-config.sh"
if fm_fleet_config_load; then
  AUTHORS_DEFAULT="$FM_FLEET_AUTHORS"
else
  AUTHORS_DEFAULT=""
fi
AUTHORS="${FM_FLEET_PR_AUTHORS:-$AUTHORS_DEFAULT}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

REPO=""
INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    -R|--repo)
      REPO="${2:-}"; shift 2 ;;
    --repo=*)
      REPO="${1#--repo=}"; shift ;;
    --)
      shift; break ;;
    -*)
      echo "error: unknown flag $1" >&2; exit 2 ;;
    *)
      INPUT="$1"; shift
      break ;;
  esac
done
[ -n "$INPUT" ] || usage
[ $# -eq 0 ] || { echo "error: unexpected args: $*" >&2; exit 2; }
if [ -z "$REPO" ] && [ -n "${FM_FLEET_REPO:-}" ]; then REPO=$FM_FLEET_REPO; fi

command -v "$FM_FLEET_GH_BIN" >/dev/null || { echo "error: gh required" >&2; exit 2; }
command -v jq >/dev/null || { echo "error: jq required" >&2; exit 2; }

# Resolve owner/name/number
OWNER=""; NAME=""; NUMBER=""
if [[ "$INPUT" =~ ^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
  NUMBER="${BASH_REMATCH[3]}"
elif [[ "$INPUT" =~ ^([^/]+)/([^/#]+)#([0-9]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  NAME="${BASH_REMATCH[2]}"
  NUMBER="${BASH_REMATCH[3]}"
elif [[ "$INPUT" =~ ^[0-9]+$ ]]; then
  NUMBER="$INPUT"
  if [ -n "$REPO" ]; then
    OWNER="${REPO%%/*}"
    NAME="${REPO#*/}"
  else
    echo "error: bare number requires --repo owner/name or fleet-watch.json" >&2
    exit 2
  fi
else
  echo "error: could not parse PR identity from: $INPUT" >&2
  exit 2
fi

# shellcheck disable=SC2016 # GraphQL variables are interpreted by GitHub, not the shell
QUERY='query($o:String!,$n:String!,$number:Int!) {
  repository(owner:$o, name:$n) {
    defaultBranchRef { name }
    pullRequest(number:$number) {
      number
      url
      isDraft
      baseRefName
      mergeable
      mergeStateStatus
      reviewDecision
      author { login }
      commits(last: 1) {
        nodes {
          commit {
            oid
            statusCheckRollup {
              state
              contexts(first: 100) {
                nodes {
                  __typename
                  ... on CheckRun { name conclusion }
                  ... on StatusContext { context state }
                }
              }
            }
          }
        }
      }
      reviewThreads(first: 100) {
        nodes { isResolved }
      }
    }
  }
}'

# GitHub answers mergeable=UNKNOWN while it recomputes after the base moves;
# poll briefly (FM_FLEET_MERGE_UNKNOWN_WAIT seconds, default 180) instead of
# refusing a PR that is only waiting on GitHub's own computation.
unknown_deadline=$(( $(date +%s) + ${FM_FLEET_MERGE_UNKNOWN_WAIT:-180} ))
while :; do
  JSON=$("$FM_FLEET_GH_BIN" api graphql \
    -f query="$QUERY" \
    -f o="$OWNER" \
    -f n="$NAME" \
    -F number="$NUMBER" 2>/dev/null) \
    || { echo "error: graphql read failed for $OWNER/$NAME#$NUMBER" >&2; exit 2; }
  [ "$(printf '%s' "$JSON" | jq -r '.data.repository.pullRequest.mergeable // ""')" = "UNKNOWN" ] || break
  [ "$(date +%s)" -lt "$unknown_deadline" ] || break
  sleep 15
done

DEFAULT_BRANCH=$(printf '%s' "$JSON" | jq -r '.data.repository.defaultBranchRef.name // ""')
PR=$(printf '%s' "$JSON" | jq -c '.data.repository.pullRequest // empty')
if [ -z "$PR" ] || [ "$PR" = "null" ]; then
  echo "false missing_pr"
  echo "reason: pull request not found" >&2
  exit 1
fi

eval "$(printf '%s' "$PR" | jq -r '
  "URL=\(.url | @sh)",
  "PR_AUTHOR=\(.author.login // "" | @sh)",
  "DRAFT=\(.isDraft | tostring)",
  "BASE=\(.baseRefName // "" | @sh)",
  "MERGEABLE=\(.mergeable // "" | @sh)",
  "MERGESTATE=\(.mergeStateStatus // "" | @sh)",
  "REVIEW=\(.reviewDecision // "" | @sh)",
  "ROLLUP=\(.commits.nodes[0].commit.statusCheckRollup.state // "" | @sh)",
  "HEAD=\(.commits.nodes[0].commit.oid // "" | @sh)",
  "UNRESOLVED=\([.reviewThreads.nodes[]? | select(.isResolved == false)] | length | tostring)"
')"

refusals=""
author_ok=0
IFS=',' read -r -a author_list <<<"$AUTHORS"
for a in "${author_list[@]}"; do
  a_trim="${a// /}"
  [ -n "$a_trim" ] || continue
  if [ "$PR_AUTHOR" = "$a_trim" ]; then author_ok=1; break; fi
done
[ "$author_ok" -eq 1 ] || refusals="${refusals}  - author \"${PR_AUTHOR}\" not in fleet allowlist (${AUTHORS})"$'\n'
[ "$DRAFT" = "false" ] || refusals="${refusals}  - is draft"$'\n'
[ "$MERGEABLE" = "MERGEABLE" ] || refusals="${refusals}  - mergeable is \"${MERGEABLE}\", want MERGEABLE"$'\n'
[ "$MERGESTATE" != "BEHIND" ] || refusals="${refusals}  - branch is behind its base (mergeStateStatus BEHIND); merge the base branch in first"$'\n'
[ -n "$DEFAULT_BRANCH" ] && [ "$BASE" = "$DEFAULT_BRANCH" ] || refusals="${refusals}  - base branch is \"${BASE}\", want the default branch \"${DEFAULT_BRANCH}\""$'\n'
if [ "$REVIEW" = "CHANGES_REQUESTED" ]; then
  refusals="${refusals}  - reviewDecision is CHANGES_REQUESTED"$'\n'
fi
[ "$UNRESOLVED" = "0" ] || refusals="${refusals}  - ${UNRESOLVED} unresolved review thread(s)"$'\n'
REQUIRED_TESTS="${FM_FLEET_REQUIRED_TEST_CHECKS:-}"
IFS=',' read -r -a required_list <<<"$REQUIRED_TESTS"
for chk in "${required_list[@]}"; do
  chk="${chk#"${chk%%[![:space:]]*}"}"; chk="${chk%"${chk##*[![:space:]]}"}"
  [ -n "$chk" ] || continue
  passed=$(printf '%s' "$PR" | jq --arg c "$chk" '[.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
    | select((.name // .context) == $c) | select((.conclusion // .state) == "SUCCESS")] | length')
  [ "$passed" != "0" ] || refusals="${refusals}  - required test check \"${chk}\" has no passing run on the head (missing or skipped only)"$'\n'
done
[ "$ROLLUP" = "SUCCESS" ] || refusals="${refusals}  - statusCheckRollup.state is \"${ROLLUP}\", want SUCCESS"$'\n'

if [ -n "$refusals" ]; then
  echo "false $OWNER/$NAME#$NUMBER"
  echo "not eligible: $URL" >&2
  printf '%s' "$refusals" >&2
  exit 1
fi

echo "true $OWNER/$NAME#$NUMBER author=$PR_AUTHOR head=$HEAD"
echo "eligible: $URL" >&2
exit 0
