#!/usr/bin/env bash
# Live lab: real fm-review-route.sh -> real fm-send inbox delivery into a real tmux pane
set -u
WT=${WT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
SHIM="$LAB/shim"; mkdir -p "$SHIM"; REAL=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L fm-lab "$@"\n' "$REAL" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH" FM_HOME="$LAB" FM_SEND_SETTLE=0
trap 'tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
tmux new-session -d -s lab -n fm-reviewer -x 200 -y 40 bash
S="$LAB/state"; cd "$LAB"
printf 'window=lab:fm-reviewer\nkind=secondmate\nmode=secondmate\nharness=claude\n' > "$S/reviewer.meta"
R="$WT/bin/fm-review-route.sh"
A=$(printf a%.0s {1..40}); B=$(printf b%.0s {1..40}); C=$(printf c%.0s {1..40}); D=$(printf d%.0s {1..40})
PR=https://github.com/o/r/pull/7
inbox() { ls "$S/reviewer.inbox"/*.msg 2>/dev/null | wc -l; }
step() { echo; echo "\$ $*"; "$@"; echo "[rc=$?] reviewer inbox records: $(inbox)"; }
echo "=== S1: configure + scan routes exact committed head A"
printf 'kind=ship\nyolo=on\nwindow=lab:fm-build\n' > "$S/build.meta"; chmod 600 "$S"/*.meta
step "$R" configure build security reviewer codex
printf 'working [at=1]: some progress, not a build\n' > "$S/build.status"
step "$R" scan build
printf 'working [at=2]: build done commit=%s\n' "$A" >> "$S/build.status"
step "$R" scan build
step "$R" scan build
echo "--- inbox record body:"; for f in "$S/reviewer.inbox"/*.msg; do grep -a 'Independent' "$f"; done
echo "--- doorbell typed into reviewer pane:"; tmux capture-pane -p -t lab:fm-reviewer | grep -a 'Firstmate' | tail -1
echo; echo "=== S2: PR registered at B (request exact pr_head), then fix commit C routed by watcher scan"
printf 'pr=%s\npr_head=%s\n' "$PR" "$B" >> "$S/build.meta"
step "$R" request build "$PR" "$B" security codex
echo; echo "=== S3: cap: third ordinary round refused (C), escalation wake written once"
printf 'working [at=3]: build done commit=%s\n' "$C" >> "$S/build.status"
step "$R" scan build
step "$R" scan build
echo "--- escalation marker: $(cat "$S/build.review-cap-escalated" 2>/dev/null)"
echo "--- wake queue:"; grep -rah 'review cap' "$S" 2>/dev/null | head -3
echo; echo "=== S4 adversarial: exception without correctness/security wording refused; with it routed once"
step "$R" request build "$PR" "$C" security codex style-3 'blocking style nit'
step "$R" request build "$PR" "$C" security codex sec-9 'blocking security token leak'
step "$R" request build "$PR" "$C" security codex sec-9 'blocking security token leak'
echo; echo "=== S5 adversarial: wrong class, wrong PR, short head, self-review owner, non-secondmate owner"
step "$R" request build "$PR" "$D" perf codex
step "$R" request build https://github.com/o/r/pull/8 "$D" security codex
step "$R" request build "$PR" abc123 security codex
printf 'kind=ship\n' > "$S/other.meta"; chmod 600 "$S/other.meta"
step "$R" configure other security build codex
step "$R" configure other security other codex
echo; echo "=== S6: stale-head: registered PR head A, newer build head B scanned; older unrouted PR head never routed"
printf 'kind=ship\npr=%s\npr_head=%s\n' "$PR" "$A" > "$S/older.meta"; chmod 600 "$S/older.meta"
"$R" configure older security reviewer codex
N0=$(inbox)
printf 'working [at=4]: build done commit=%s\n' "$B" > "$S/older.status"
step "$R" scan older
step "$R" scan older
echo "--- new records: $(( $(inbox) - N0 )); routed heads:"; cut -f1 "$S/older.review-rounds"
echo; echo "=== S7: teardown state files present before teardown:"; ls "$S" | grep -E "review" 
