#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
SWEEP="$ROOT/bin/fm-pr-stall-sweep.py"
URL=https://github.com/o/r/pull/41
say() { printf '\n=== %s ===\n' "$*"; }
dir=$(make_case e2e)
write_task_meta "$dir"
mkdir -p "$dir/project/.firstmate"
printf '#!/usr/bin/env bash\n# stands in for a DALP ready check that fails while required CI is pending\necho "required checks still pending" >&2\ntest -f ready.ok\n' > "$dir/project/.firstmate/ready-check"
chmod +x "$dir/project/.firstmate/ready-check"
head=$(git -C "$dir/wt" rev-parse HEAD)

say "S1: fm-pr-check.sh task-a $URL while the ready check fails (CI pending)"
FM_TEST_GH_HEAD=$head run_check_entry "$dir" task-a "$URL"; echo "exit=$?"
echo "--- state/task-a.meta (pr/ownership lines)"; grep -E '^(pr=|pr_head=|task_owner=|branch=)' "$dir/home/state/task-a.meta"
echo "--- pr_head recorded? $(grep -q '^pr_head=' "$dir/home/state/task-a.meta" && echo yes || echo no)"
echo "--- merge poll armed (task-a.check.sh)? $([ -e "$dir/home/state/task-a.check.sh" ] && echo yes || echo no)"

# Sweep fixture: fleet config whose author allowlist does NOT include the PR author,
# and a gh that answers the author search with nothing and the aliased per-number
# fetch with PR 41 in the scenario's CI state.
cat > "$dir/home/config/fleet-watch.json" <<JSON
{"repo":"o/r","authors":["some-other-author"],"required_test_checks":["ci"],
 "thresholds":{"budget_seconds":20,"renudge_seconds":3600,"escalate_seconds":7200}}
JSON
cat > "$dir/sweepgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SWEEP_GH_LOG"
case "$*" in
  *"pr41: pullRequest"*)
    python3 - "$SWEEP_PR_STATE" "$SWEEP_PR_CI" <<'PY'
import json,sys
state,ci=sys.argv[1],sys.argv[2]
ctx={"name":"ci","conclusion":"FAILURE" if ci=="red" else "SUCCESS","status":"COMPLETED","detailsUrl":"https://github.com/o/r/actions/runs/9"}
node={"number":41,"url":"https://github.com/o/r/pull/41","state":state,"isDraft":False,"mergeable":"MERGEABLE",
 "mergeStateStatus":"CLEAN","headRefName":"fm/task-a","baseRefName":"main","author":{"login":"codex-bot"},
 "reviewThreads":{"nodes":[]},"commits":{"nodes":[{"commit":{"oid":"abcdef0123456789","statusCheckRollup":{"state":"FAILURE" if ci=="red" else "SUCCESS","contexts":{"nodes":[ctx]}}}}]}}
print(json.dumps({"data":{"repository":{"pr41":node}}}))
PY
    ;;
  *"search(query"*) echo '{"data":{"search":{"nodes":[]}}}' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$dir/sweepgh"
sweep() {
  : > "$dir/sweepgh.log"
  env -u NO_MISTAKES_GATE FM_HOME="$dir/home" FM_FLEET_GH_BIN="$dir/sweepgh" SWEEP_GH_LOG="$dir/sweepgh.log" \
    SWEEP_PR_STATE="$1" SWEEP_PR_CI="$2" PATH="$dir/fakebin:$BASE_PATH" python3 "$SWEEP"
  echo "sweep exit=$?"
  echo "--- gh calls: $(grep -c . "$dir/sweepgh.log") ($(grep -c 'pr41: pullRequest' "$dir/sweepgh.log") aliased per-number fetch)"
  cut -c1-90 "$dir/sweepgh.log" | sort | uniq -c | sed "s/^/    /"
}
inbox() {
  echo "--- task-a steering inbox records:"
  find "$dir/home/state/task-a.inbox" -type f 2>/dev/null | sort | while read -r f; do echo "[$f]"; grep -a 'pr-stall' "$f" | head -3; done
}

say "S2: sweep with PR 41 open + red (author outside allowlist, registered only via pr=)"
sweep OPEN red; inbox
say "S3: same red head again (no re-nudge within renudge window)"
sweep OPEN red; inbox | grep -c 'pr-stall sweep\]' | sed 's/^/steer records containing pr-stall: /'
say "S4: PR 41 turns green, still no merge poll armed -> ready wake"
sweep OPEN green; inbox
say "S5: lane re-runs fm-pr-check after CI went green (ready check now passes)"
touch "$dir/wt/ready.ok"; git -C "$dir/wt" add ready.ok; git -C "$dir/wt" commit -q -m ready
head=$(git -C "$dir/wt" rev-parse HEAD)
FM_TEST_GH_HEAD=$head run_check_entry "$dir" task-a "$URL"; echo "exit=$?"
echo "--- pr_head: $(grep '^pr_head=' "$dir/home/state/task-a.meta")"
echo "--- merge poll armed? $([ -e "$dir/home/state/task-a.check.sh" ] && echo yes || echo no)"
before=$(find "$dir/home/state/task-a.inbox" -type f | wc -l)
rm -f "$dir/home/state/.pr-stall-seen.json"
say "S6: sweep on green PR with armed merge poll -> no ready steer"
sweep OPEN green
echo "--- inbox records before=$before after=$(find "$dir/home/state/task-a.inbox" -type f | wc -l)"
say "S7: PR merged but meta still has pr= (teardown pending) -> not swept"
rm -f "$dir/home/state/task-a.check.sh" "$dir/home/state/.pr-stall-seen.json"
before=$(find "$dir/home/state/task-a.inbox" -type f | wc -l)
sweep MERGED red
echo "--- inbox records before=$before after=$(find "$dir/home/state/task-a.inbox" -type f | wc -l)"
say "S8: lane listed in remote_lanes -> registered red PR is not steered locally"
python3 - "$dir/home/config/fleet-watch.json" <<'PY'
import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["remote_lanes"]=["task-a"]; json.dump(c,open(p,"w"))
PY
rm -f "$dir/home/state/.pr-stall-seen.json"
before=$(find "$dir/home/state/task-a.inbox" -type f | wc -l)
sweep OPEN red
echo "--- inbox records before=$before after=$(find "$dir/home/state/task-a.inbox" -type f | wc -l)"
