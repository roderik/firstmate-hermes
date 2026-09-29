#!/usr/bin/env bash
# Live lab: real fm-teardown.sh clears review state so a reused task id can be re-configured
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
tmux new-window -t lab -n fm-x bash
S="$LAB/state"; cd "$WT"   # teardown driven from the gate worktree: lab-home allowance applies
printf 'window=lab:fm-reviewer\nkind=secondmate\nmode=secondmate\nharness=claude\n' > "$S/reviewer.meta"
G="$LAB/git"; mkdir -p "$G"
git init -q --bare "$G/origin.git"; git -C "$G/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$G/origin.git" "$G/seed" 2>/dev/null; git -C "$G/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base; git -C "$G/seed" push -q origin main
git clone -q "$G/origin.git" "$G/project"; git -C "$G/project" remote set-head origin main
git -C "$G/project" worktree add -q -b fm/x "$G/wt" main
touch "$S/.last-watcher-beat"
printf "#!/usr/bin/env bash\n# lab shim: treehouse pool return is out of scope (would write ~/.treehouse)\nexit 0\n" > "$SHIM/treehouse"; chmod +x "$SHIM/treehouse"
printf 'window=lab:fm-x\nendpoint_task_id=x\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=on\nharness=claude\nspawn_gen=lab-x\n' "$G/wt" "$G/project" > "$S/x.meta"; chmod 600 "$S"/*.meta
( cd "$LAB"; "$WT/bin/fm-review-route.sh" configure x security reviewer codex
  printf 'working [at=1]: build done commit=%s\n' "$(printf a%.0s {1..40})" > "$S/x.status"
  "$WT/bin/fm-review-route.sh" scan x 2>&1 | grep 'review routed'
  : > "$S/x.review-cap-escalated"; : > "$S/x.review-route-attention" )
echo "before teardown:"; ls -a "$S" | grep -E '^\.?x\.review'
echo "\$ fm-teardown.sh x --force"; "$WT/bin/fm-teardown.sh" x --force 2>&1 | tail -5; echo "[rc=${PIPESTATUS[0]}]"
echo "after teardown:"; ls -a "$S" | grep -E '^\.?x\.' || echo "(no x.* state left)"
echo "--- reuse id x:"
printf 'kind=ship\nmode=no-mistakes\nyolo=on\n' > "$S/x.meta"; chmod 600 "$S/x.meta"
( cd "$LAB"; "$WT/bin/fm-review-route.sh" configure x security reviewer codex; echo "[rc=$?]" )
