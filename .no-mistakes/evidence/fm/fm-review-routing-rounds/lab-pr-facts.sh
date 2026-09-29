#!/usr/bin/env bash
# Live lab: real fm-pr-check.sh / fm-pr-state.sh / fm-fleet-snapshot.sh against a real GitHub PR (read-only)
set -u
WT=${WT:?}; PR=${PR:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/wt"
export TMUX_TMPDIR="$LAB/tmux"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
SHIM="$LAB/shim"; mkdir -p "$SHIM"; REAL=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L fm-lab "$@"\n' "$REAL" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH" FM_HOME="$LAB" FM_SEND_SETTLE=0
trap 'tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
tmux new-session -d -s lab -n fm-reviewer -x 200 -y 40 bash
S="$LAB/state"; cd "$LAB"
printf 'window=lab:fm-reviewer\nkind=secondmate\nmode=secondmate\nharness=claude\n' > "$S/reviewer.meta"
for t in shipa:on shipb:off; do id=${t%%:*}; y=${t#*:}
  printf 'kind=ship\nmode=no-mistakes\nyolo=%s\nworktree=%s\nproject=firstmate\nwindow=lab:fm-%s\n' "$y" "$LAB/wt" "$id" > "$S/$id.meta"; chmod 600 "$S/$id.meta"; done
"$WT/bin/fm-review-route.sh" configure shipa security reviewer codex
echo; echo "=== S8: fm-pr-check records ownership/base/merge-owner facts and routes exact PR head (yolo=on, review configured)"
echo "\$ fm-pr-check.sh shipa $PR"; "$WT/bin/fm-pr-check.sh" shipa "$PR" 2>&1 | grep -vE '^●|WARNING'; echo "[rc=${PIPESTATUS[0]}]"
echo "--- recorded meta:"; grep -E '^(task_owner|head_repo|base_repo|base_ref|base_sha|merge_target|stacked|merge_owner|pr|pr_head|review_)' "$S/shipa.meta"
echo "--- review rounds receipt:"; cat "$S/shipa.review-rounds" 2>/dev/null
echo "--- forge head for comparison: $(gh pr view "$PR" --json headRefOid -q .headRefOid)"
echo; echo "=== S9: yolo=off, no review configured -> merge_owner=operator, no review routed"
echo "\$ fm-pr-check.sh shipb $PR"; "$WT/bin/fm-pr-check.sh" shipb "$PR" 2>&1 | grep -vE '^●|WARNING'; echo "[rc=${PIPESTATUS[0]}]"
grep -E '^merge_owner|^review_' "$S/shipb.meta"; ls "$S" | grep -c 'shipb.review' || true
echo; echo "=== S10: fm-pr-state prints identity + merge-owner line, refuses non-owner task"
echo "\$ fm-pr-state.sh $PR shipa"; "$WT/bin/fm-pr-state.sh" "$PR" shipa; echo "[rc=$?]"
echo "\$ fm-pr-state.sh $PR reviewer"; "$WT/bin/fm-pr-state.sh" "$PR" reviewer; echo "[rc=$?]"
echo "\$ fm-pr-state.sh https://github.com/kunchenguid/firstmate/pull/6157 shipa"; "$WT/bin/fm-pr-state.sh" https://github.com/kunchenguid/firstmate/pull/6157 shipa; echo "[rc=$?]"
echo; echo "=== S11: fleet snapshot exposes pr ownership facts"
"$WT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null | jq -c '.. | objects | select(has("pr")) | {id:(.id//.task_id), pr}' 2>/dev/null | head -4 \
 || "$WT/bin/fm-fleet-snapshot.sh" 2>&1 | head -20
echo; echo "=== S12: fm-pr-check with gh identity API unavailable still arms (facts unknown)"
mkdir -p "$LAB/ghfail"; REALGH=$(command -v gh)
printf '#!/usr/bin/env bash\n[ "$1" = api ] && exit 1\nexec "%s" "$@"\n' "$REALGH" > "$LAB/ghfail/gh"; chmod +x "$LAB/ghfail/gh"
printf 'kind=ship\nmode=no-mistakes\nyolo=on\nworktree=%s\nproject=firstmate\n' "$LAB/wt" > "$S/shipc.meta"; chmod 600 "$S/shipc.meta"
PATH="$LAB/ghfail:$PATH" "$WT/bin/fm-pr-check.sh" shipc "$PR" 2>&1 | grep -vE '^●|WARNING'; echo "[rc=${PIPESTATUS[0]}]"
grep -E '^(head_repo|base_ref|stacked|merge_owner)' "$S/shipc.meta"
