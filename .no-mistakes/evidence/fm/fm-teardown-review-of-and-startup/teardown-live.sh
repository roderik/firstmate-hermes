#!/usr/bin/env bash
# Live: real fm-teardown.sh on a marked lab home + private tmux lab socket + real git pool slot.
set -u
R=${TD_ROOT:?}; GATE=/home/roderik/.no-mistakes/worktrees/49bdd8e38f81/01M3X6T6PY9RMWYEY704XE7GZ0
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$GATE/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$GATE/bin/fm-lab-home.sh" tmux-dir "$LAB")
T() { TMUX_TMPDIR="$TD" tmux -L fm-lab "$@"; }
trap 'T kill-server 2>/dev/null; "$GATE/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
echo tmux > "$LAB/config/backend"
P="$LAB/proj"; git init -q "$P"; git -C "$P" -c user.name=t -c user.email=t@e.invalid commit --allow-empty -qm init
mkdir -p "$LAB/pool/1"; git -C "$P" worktree add -q --detach "$LAB/pool/1/proj"; SLOT="$LAB/pool/1/proj"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$LAB/pool/treehouse-state.json"
echo "author work in progress" > "$SLOT/author-work.txt"
printf 'task=author-task\nhome=%s\n' "$LAB" > "$LAB/pool/1/.fm-slot-owner"
mkdir -p "$LAB/shim"; printf '#!/bin/sh\necho "treehouse $*" >> %s/treehouse-calls.log\n' "$LAB" > "$LAB/shim/treehouse"; chmod +x "$LAB/shim/treehouse"
T new-session -d -s firstmate -n fm-author-task -c "$SLOT" 'exec sleep 600'
T new-window -t firstmate -n fm-review-task -c "$SLOT" 'exec sleep 600'
T new-window -t firstmate -n driver -c "$R"
fm_write_meta() { local f=$1 kv; shift; : > "$f"; for kv in "$@"; do printf "%s\n" "$kv" >> "$f"; done; }
fm_write_meta "$LAB/state/author-task.meta" "window=firstmate:fm-author-task" "endpoint_task_id=author-task" "worktree=$SLOT" "project=$P" "kind=ship"
fm_write_meta "$LAB/state/review-task.meta" "window=firstmate:fm-review-task" "endpoint_task_id=review-task" "worktree=$SLOT" "project=$P" "kind=scout" "review_of=author-task"
mkdir -p "$LAB/data/review-task"; echo "# Review of author-task: LGTM" > "$LAB/data/review-task/report.md"
echo "== before: windows: $(T list-windows -t firstmate -F '#W' | tr '\n' ' ')"
T send-keys -t firstmate:driver "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$LAB PATH=$LAB/shim:\$PATH sh -c \"$R/bin/fm-captain-hold.sh complete review-task --none && $R/bin/fm-teardown.sh review-task\" > $LAB/td.out 2>&1; echo \$? > $LAB/td.rc" Enter
for i in $(seq 1 600); do [ -s "$LAB/td.rc" ] && break; sleep 0.2; done
echo "== fm-teardown.sh review-task exit=$(cat "$LAB/td.rc" 2>/dev/null || echo TIMEOUT)"
grep -v '^●' "$LAB/td.out" | sed 's/^/   | /' | tail -12
echo "== after: windows: $(T list-windows -t firstmate -F '#W' | tr '\n' ' ')"
echo "reviewer meta present: $([ -e "$LAB/state/review-task.meta" ] && echo yes || echo no)"
echo "author meta present:   $([ -e "$LAB/state/author-task.meta" ] && echo yes || echo no)"
echo "author slot dir present: $([ -d "$SLOT" ] && echo yes || echo no); author work file: $(cat "$SLOT/author-work.txt" 2>/dev/null || echo MISSING)"
echo "slot owner claim: $(tr '\n' ' ' < "$LAB/pool/1/.fm-slot-owner" 2>/dev/null || echo MISSING)"
echo "git worktree list: $(git -C "$P" worktree list | wc -l) entries"
echo "treehouse calls: $(cat "$LAB/treehouse-calls.log" 2>/dev/null || echo none)"
