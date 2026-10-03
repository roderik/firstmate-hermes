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
# pr_fixture <base> <default-branch> <check-name> [state]
pr_fixture() {
  cat > "$work/pr.json" <<JSON
{"data":{"repository":{"defaultBranchRef":{"name":"$2"},"pullRequest":{"number":7,"url":"https://github.com/owner/repo/pull/7","state":"${4:-OPEN}","isDraft":false,"baseRefName":"$1","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","author":{"login":"author"},"commits":{"nodes":[{"commit":{"oid":"0123456789012345678901234567890123456789","statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[{"name":"$3","conclusion":"SUCCESS"}]}}}}]},"reviewThreads":{"nodes":[]}}}}}
JSON
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d["data"]["repository"]; r["pr7"]=r["pullRequest"]; json.dump(d, open(sys.argv[2], "w"))' "$work/pr.json" "$work/pr-many.json"
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
    *"pr7: pullRequest"*) cat "$work/pr-many.json" ;;
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
# Registered PRs remain in the sweep even when their author is outside the
# configured author allowlist, and ownership uses both pr= and the branch.
printf '%s\n' 'window=fm-task-a' 'branch=feature/task-a' 'pr=https://github.com/owner/repo/pull/7' > "$work/home/state/task-a.meta"
write_config <<'JSON'
{"repo": "owner/repo", "authors": ["different-author"]}
JSON
pr_fixture trunk trunk "Unit Tests"
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" > "$work/registered.out" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
items = sweep.prs()
assert any(p["number"] == 7 for p in items), "registered PR was filtered by author"
assert sweep.owner_of(items[0], sweep.owners()) == "task-a", "registered PR did not map to its owner"
print("registered")
PY
grep -qxF registered "$work/registered.out"
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" > "$work/red.out" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
pr = {"url": "https://github.com/owner/repo/pull/7", "number": 7,
      "baseRefName": "trunk", "headRefName": "feature/task-a", "isDraft": False,
      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
      "author": {"login": "different-author"},
      "reviewThreads": {"nodes": []},
      "commits": {"nodes": [{"commit": {"oid": "0123456789abcdef",
        "statusCheckRollup": {"state": "FAILURE", "contexts": {"nodes": [
          {"name": "Unit Tests", "conclusion": "FAILURE", "detailsUrl": "https://ci.invalid/1"}]}}}}]}}
sweep.prs = lambda: [pr]
sweep.owners = lambda: {"task-a": {"branch": "feature/task-a", "pr": pr["url"]}}
calls = []
sweep.sh = lambda args, timeout=15: (calls.append(args) or (0, ""))
sweep.main()
assert any("fm-send.sh" in args[0] and args[1] == "task-a" for args in calls), "red PR did not wake its owner"
print("red steer")
PY
grep -qxF 'red steer' "$work/red.out"
# A registered PR that is no longer open is not swept.
pr_fixture trunk trunk "Unit Tests" MERGED
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
assert sweep.prs() == [], "a merged registered PR was swept"
PY
# A configured takeover is fetched by number even when no task registered it
# and its author is outside the allowlist.
rm -f "$work/home/state/task-a.meta"
write_config <<'JSON'
{"repo": "owner/repo", "authors": [], "takeovers": {"7": "task-b"}}
JSON
pr_fixture trunk trunk "Unit Tests"
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
assert [p["number"] for p in sweep.prs()] == [7], "takeover PR was not fetched"
PY
# Every directly fetched number shares one request, string-typed repository
# variables, and an unresolved number does not hide the others.
write_config <<'JSON'
{"repo": "2048/2048", "authors": [], "takeovers": {"7": "task-b", "8": "task-c", "9": "task-d"}}
JSON
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
calls = []
repo = {"pr7": {"number": 7, "state": "OPEN", "isDraft": False}, "pr8": None,
        "pr9": {"number": 9, "state": "CLOSED", "isDraft": False}}
sweep.sh = lambda args, timeout=15: (calls.append(args) or (1, json.dumps({"data": {"repository": repo}, "errors": [{}]})))
assert [p["number"] for p in sweep.prs()] == [7], "aliased fetch lost an open PR"
assert len(calls) == 1, calls
assert "owner=2048" in calls[0] and calls[0][calls[0].index("owner=2048") - 1] == "-f", calls[0]
assert "name=2048" in calls[0] and calls[0][calls[0].index("name=2048") - 1] == "-f", calls[0]
PY
# A search result from a deleted author account does not abort the sweep.
write_config <<'JSON'
{"repo": "owner/repo", "authors": ["author"]}
JSON
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
nodes = [{"number": 8, "author": None}, {"number": 9, "author": {"login": "author"}}]
sweep.sh = lambda args, timeout=15: (0, json.dumps({"data": {"search": {"nodes": nodes}}}))
assert [p["number"] for p in sweep.prs()] == [9], "ghost-author search result broke the sweep"
PY
# Remote lanes are neither matched by pr= or branch nor steered locally.
write_config <<'JSON'
{"repo": "owner/repo", "authors": ["author"], "remote_lanes": ["task-r"]}
JSON
printf '%s\n' 'see https://github.com/owner/repo/pull/7' > "$work/home/state/task-r.status"
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
url = "https://github.com/owner/repo/pull/7"
pr = {"url": url, "number": 7, "baseRefName": "trunk", "headRefName": "feature/task-r", "isDraft": False,
      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewThreads": {"nodes": []},
      "commits": {"nodes": [{"commit": {"oid": "0123456789abcdef", "statusCheckRollup": {"state": "FAILURE",
        "contexts": {"nodes": [{"name": "Unit Tests", "conclusion": "FAILURE", "detailsUrl": "https://ci.invalid/1"}]}}}}]}}
metas = {"task-r": {"branch": "feature/task-r", "pr": url}}
assert sweep.owner_of(pr, {"task-r": metas["task-r"], "task-x": {"branch": "", "pr": ""}}) == "task-r"
sweep.REMOTE = {"task-r", "task-x"}
sweep.prs = lambda: [pr]
sweep.owners = lambda: metas
calls = []
sweep.sh = lambda args, timeout=15: (calls.append(args) or (0, ""))
sweep.main()
assert not any("fm-send.sh" in args[0] for args in calls), "remote lane was steered locally"
PY
# A green PR owned only through a remote lane's status mention, with no local
# metadata for that lane, is neither a crash nor a steer.
rm -f "$work/home/state/.pr-stall-seen.json"
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
url = "https://github.com/owner/repo/pull/7"
pr = {"url": url, "number": 7, "baseRefName": "trunk", "headRefName": "feature/task-r", "isDraft": False,
      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewThreads": {"nodes": []},
      "commits": {"nodes": [{"commit": {"oid": "0123456789abcdef", "statusCheckRollup": {"state": "SUCCESS",
        "contexts": {"nodes": [{"name": "Unit Tests", "conclusion": "SUCCESS"}]}}}}]}}
sweep.REMOTE = {"task-r"}
sweep.prs = lambda: [pr]
sweep.owners = lambda: {}
calls = []
sweep.sh = lambda args, timeout=15: (calls.append(args) or (0, ""))
sweep.main()
assert not any("fm-send.sh" in args[0] for args in calls), "remote lane without metadata was steered"
PY
test -f "$work/home/state/.pr-stall-seen.json"
rm -f "$work/home/state/task-r.status" "$work/home/state/.pr-stall-seen.json"
# A registered PR that turns green without an armed merge poll (its ready
# check failed while CI was pending) wakes its owner to report ready again.
fleet python3 - "$ROOT/bin/fm-pr-stall-sweep.py" "$work/home/state" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
url = "https://github.com/owner/repo/pull/7"
pr = {"url": url, "number": 7, "baseRefName": "trunk", "headRefName": "feature/task-a", "isDraft": False,
      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewThreads": {"nodes": []},
      "commits": {"nodes": [{"commit": {"oid": "0123456789abcdef", "statusCheckRollup": {"state": "SUCCESS",
        "contexts": {"nodes": [{"name": "Unit Tests", "conclusion": "SUCCESS"}]}}}}]}}
sweep.prs = lambda: [pr]
sweep.owners = lambda: {"task-a": {"branch": "feature/task-a", "pr": url}}
def run(path):
    calls = []
    sweep.sh = lambda args, timeout=15: (calls.append(args) or (0, ""))
    try:
        os.remove(sweep.SEEN)
    except OSError:
        pass
    sweep.main()
    return [a for a in calls if "fm-send.sh" in a[0]]
sent = run(None)
assert len(sent) == 1 and sent[0][1] == "task-a" and "report the pull request ready" in sent[0][2], sent
open(os.path.join(sys.argv[2], "task-a.check.sh"), "w").close()
assert run(None) == [], "an armed merge poll must not be re-steered"
os.remove(os.path.join(sys.argv[2], "task-a.check.sh"))
PY
rm -f "$work/home/state/.pr-stall-seen.json"


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
