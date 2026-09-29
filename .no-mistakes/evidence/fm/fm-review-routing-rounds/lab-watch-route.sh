#!/usr/bin/env bash
# Live lab: real fm-watch.sh picks up a worker's committed build status and routes review; broken owner -> one attention wake
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
WPID=
trap '[ -n "$WPID" ] && kill $WPID 2>/dev/null; tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
tmux new-session -d -s lab -n fm-reviewer -x 200 -y 40 bash
tmux new-window -t lab -n fm-build bash
tmux new-window -t lab -n fm-broken bash
S="$LAB/state"; cd "$LAB"
printf 'window=lab:fm-reviewer\nkind=secondmate\nmode=secondmate\nharness=claude\n' > "$S/reviewer.meta"
printf 'kind=ship\nmode=no-mistakes\nyolo=on\nwindow=lab:fm-build\nharness=claude\n' > "$S/build.meta"
printf 'kind=ship\nmode=no-mistakes\nyolo=on\nwindow=lab:fm-broken\nharness=claude\n' > "$S/broken.meta"
chmod 600 "$S"/*.meta
"$WT/bin/fm-review-route.sh" configure build security reviewer codex
"$WT/bin/fm-review-route.sh" configure broken security reviewer codex
# broken: owner later becomes non-secondmate (torn down)
sed -i 's/^review_owner=.*/review_owner=ghost/' "$S/broken.meta"
A=$(printf a%.0s {1..40}); B=$(printf b%.0s {1..40})
watch() { FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 "$WT/bin/fm-watch.sh" > "$LAB/watch.out" 2>"$LAB/watch.err" & WPID=$!; }
waitfor() { for _ in $(seq 1 60); do eval "$1" && return 0; kill -0 $WPID 2>/dev/null || { eval "$1"; return; }; sleep 1; done; return 1; }
echo "=== S13: watcher routes a worker's 'build done commit=' status line"
watch; sleep 3
printf 'working [at=%s]: build done commit=%s\n' "$(date +%s)" "$A" >> "$S/build.status"
printf 'working [at=%s]: build done commit=%s\n' "$(date +%s)" "$B" >> "$S/broken.status"
if waitfor '[ -f "$S/build.review-rounds" ] && [ -e "$S/broken.review-route-attention" ]'; then echo "routed within watcher cycle"; else echo "TIMEOUT"; fi
echo "--- build.review-rounds:"; cat "$S/build.review-rounds" 2>/dev/null
echo "--- reviewer inbox:"; ls "$S/reviewer.inbox" 2>/dev/null; grep -ah 'Independent' "$S"/reviewer.inbox/*.msg 2>/dev/null
echo; echo "=== S14: broken review owner raises one attention wake (not repeated on next status change)"
sleep 2; kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
echo "watch stdout:"; cat "$LAB/watch.out"
cnt() { grep -rah 'review routing needs attention' "$S"/.wake* "$S"/*wake* 2>/dev/null | wc -l; }
echo "attention wakes after 1st change: $(cnt)"; ls -a "$S" | grep -i -E 'wake|attention'
watch; sleep 3
printf 'working [at=%s]: build done commit=%s\n' "$(date +%s)" "$B" >> "$S/broken.status"
sleep 6; kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
echo "attention wakes after 2nd change: $(cnt)"
grep -rah 'review' "$S"/.wake* "$S"/*wake* 2>/dev/null | sort -u
