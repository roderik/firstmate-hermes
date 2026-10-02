#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/config" "$work/home/state" "$work/bin"
write_config() {
  cat > "$work/home/config/fleet-watch.json"
}
write_config <<'JSON'
{
  "repo": "owner/repo",
  "authors": ["author"],
  "required_test_checks": ["Unit Tests"],
  "thresholds": {"budget_seconds": 5, "renudge_seconds": 60, "escalate_seconds": 120},
  "rollout_workflows": [{"name": "Release", "branch": "main"}]
}
JSON
# pr_fixture <base> <default-branch> <check-name>
pr_fixture() {
  cat > "$work/pr.json" <<JSON
{"data":{"repository":{"defaultBranchRef":{"name":"$2"},"pullRequest":{"number":7,"url":"https://github.com/owner/repo/pull/7","isDraft":false,"baseRefName":"$1","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","author":{"login":"author"},"commits":{"nodes":[{"commit":{"oid":"0123456789012345678901234567890123456789","statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[{"name":"$3","conclusion":"SUCCESS"}]}}}}]},"reviewThreads":{"nodes":[]}}}}}
JSON
}
printf '%s\n' '{"data":{"repository":{"squashMergeAllowed":false,"mergeCommitAllowed":true,"rebaseMergeAllowed":true}}}' > "$work/methods.json"
cat > "$work/bin/gh" <<EOF_GH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/gh.log"
if [ "\${1:-}" = run ] && [ "\${2:-}" = list ]; then
  printf '%s\n' '42 completed failure https://github.com/owner/repo/actions/runs/42'
  exit 0
fi
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  case "\$*" in
    *squashMergeAllowed*) cat "$work/methods.json" ;;
    *) cat "$work/pr.json" ;;
  esac
  exit 0
fi
if [ "\${1:-}" = pr ] && [ "\${2:-}" = merge ]; then
  exit 0
fi
if [ "\${1:-}" = pr ] && [ "\${2:-}" = list ]; then
  printf '%s\n' 7
  exit 0
fi
exit 2
EOF_GH
# gh-axi rejects the gh flags the fleet scripts pass, so the default binary must be plain gh.
printf '#!/usr/bin/env bash\nexit 2\n' > "$work/bin/gh-axi"
chmod +x "$work/bin/gh" "$work/bin/gh-axi"
fleet() {
  PATH="$work/bin:$PATH" FM_HOME="$work/home" FM_CONFIG_OVERRIDE="$work/home/config" \
    FM_STATE_OVERRIDE="$work/home/state" "$@"
}

fleet "$ROOT/bin/fm-release-rollout-check.sh" > "$work/release.out"
grep -q 'Release failure: https://github.com/owner/repo/actions/runs/42' "$work/release.out"

pr_fixture trunk trunk "Unit Tests"
fleet "$ROOT/bin/fm-pr-fleet-merge-eligible.sh" https://github.com/owner/repo/pull/7 > "$work/eligible.out"
grep -q '^true owner/repo#7 author=author ' "$work/eligible.out"

pr_fixture trunk trunk "Lint"
if fleet "$ROOT/bin/fm-pr-fleet-merge-eligible.sh" https://github.com/owner/repo/pull/7 > "$work/eligible.out" 2> "$work/eligible.err"; then
  fail "a missing configured required check must refuse the pull request"
fi
grep -q 'required test check "Unit Tests" has no passing run' "$work/eligible.err"

pr_fixture release/1.x trunk "Unit Tests"
if fleet "$ROOT/bin/fm-pr-fleet-merge-eligible.sh" https://github.com/owner/repo/pull/7 > "$work/eligible.out" 2> "$work/eligible.err"; then
  fail "a pull request against a non-default base must be refused"
fi
grep -q 'base branch is "release/1.x", want the default branch "trunk"' "$work/eligible.err"

write_config <<'JSON'
{"repo": "owner/repo", "authors": ["author"]}
JSON
pr_fixture trunk trunk "Lint"
fleet "$ROOT/bin/fm-pr-fleet-merge-eligible.sh" https://github.com/owner/repo/pull/7 > "$work/eligible.out"
grep -q '^true owner/repo#7 ' "$work/eligible.out"

FM_FLEET_MERGE_DRY_RUN=1 fleet "$ROOT/bin/fm-pr-fleet-admin-merge.sh" https://github.com/owner/repo/pull/7 > "$work/merge.out"
grep -qxF 'dry-run: would admin-merge https://github.com/owner/repo/pull/7 with --merge' "$work/merge.out"
if grep -q '^pr merge' "$work/gh.log"; then fail "dry run must not merge"; fi

# The merge hold lives beside fleet-watch.json in $FM_HOME/config.
fleet "$ROOT/bin/fm-pr-fleet-any-eligible.sh" > "$work/any.out"
grep -qxF 'https://github.com/owner/repo/pull/7' "$work/any.out"
printf '%s\n' 7 > "$work/home/config/fleet-merge-hold.txt"
if PATH="$work/bin:$PATH" FM_HOME="$work/home" FM_STATE_OVERRIDE="$work/home/state" \
  "$ROOT/bin/fm-pr-fleet-any-eligible.sh" > "$work/any.out"; then
  fail "a pull request held in \$FM_HOME/config/fleet-merge-hold.txt must not be reported eligible"
fi
test ! -s "$work/any.out"
rm "$work/home/config/fleet-merge-hold.txt"

write_config <<'JSON'
{"repo": "owner/repo", "authors": ["author"], "merge_method": "rebase"}
JSON
fleet "$ROOT/bin/fm-pr-fleet-admin-merge.sh" https://github.com/owner/repo/pull/7 > "$work/merge.out"
grep -qxF 'merged: https://github.com/owner/repo/pull/7' "$work/merge.out"
grep -qxF 'pr merge 7 -R owner/repo --admin --rebase --delete-branch' "$work/gh.log"

write_config <<'JSON'
{"repo": "owner/repo", "authors": ["author"], "steering": {"behind": "{url} trails {base}; run team-sync.", "threads": "{nope}", "conflict": "{url.name}"}}
JSON
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" > "$work/steer.out" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
def pr(state, threads=0):
    return {"url": "https://github.com/owner/repo/pull/7", "baseRefName": "trunk", "isDraft": False,
            "mergeable": "MERGEABLE", "mergeStateStatus": state,
            "reviewThreads": {"nodes": [{"isResolved": False}] * threads},
            "commits": {"nodes": [{"commit": {"oid": "0123456789abcdef", "statusCheckRollup": {"state": "SUCCESS", "contexts": {"nodes": []}}}}]}}
print(sweep.classify(pr("BEHIND"))[2])
print(sweep.classify(pr("CLEAN", threads=2))[2])
print(sweep.classify(pr("DIRTY"))[2])
PY
sed -n 1p "$work/steer.out" | grep -qxF 'https://github.com/owner/repo/pull/7 trails trunk; run team-sync.'
sed -n 2p "$work/steer.out" | grep -q '^https://github.com/owner/repo/pull/7 has 2 unresolved review thread(s)\.'
sed -n 3p "$work/steer.out" | grep -q '^https://github.com/owner/repo/pull/7 conflicts with trunk\.'
write_config <<'JSON'
{"repo": "owner/repo", "authors": ["author"], "steering": ["not", "an", "object"]}
JSON
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" > "$work/steer.out" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
print(sweep.REPO)
PY
grep -qxF owner/repo "$work/steer.out"
printf 'ok - fleet watch configuration and checks\n'
