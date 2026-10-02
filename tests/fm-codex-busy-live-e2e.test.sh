#!/usr/bin/env bash
# tests/fm-codex-busy-live-e2e.test.sh - live guard for Codex's semantic busy
# source and its dormant-when-idle fact (live-harness-optin family).
#
# bin/fm-busy-lib.sh classifies a Codex worker by folding Codex's own session
# rollout (task_started opens a turn, task_complete or turn_aborted closes it)
# and binds the pane from the task's recorded worktree and spawn time. It also
# declares Codex dormant when idle (fm_busy_idle_is_dormant): a background job
# Codex started does not wake it when the job finishes, which is why supervision
# ages an idle Codex worker's declared wait instead of trusting it. Both are
# vendor behavior, so per .agents/skills/firstmate-coding-guidelines the rollout
# fixtures in tests/fm-busy-state.test.sh are not enough on their own: this
# guard launches the INSTALLED codex with the crewmate launch flags in an
# isolated tmux server and requires, through the real classifier,
#   1. busy codex-rollout while a foreground command runs, then idle at turn end;
#   2. idle codex-rollout after an Escape interrupt, with a turn_aborted record;
#   3. no new turn after a background job it started finishes while it is idle.
# It fails naming codex and `codex --version`, and refuses a vacuous pass.
#
# It submits prompts, so it is opt-in (fm_live_gate): FM_CODEX_BUSY_LIVE=1 or
# FM_LIVE=1 runs it, and an absent codex or tmux then fails instead of skipping.
# Refresh docs/verification/supervision.md ("Semantic busy state") from this
# guard's output after any codex upgrade.
#
# Folder trust: codex runs in a git-ignored scratch folder inside this checkout,
# so the repository's existing Codex trust applies; a trust dialog is a real
# unreadable state and correctly fails the check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_BUSY_LIVE codex tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SOCKET="fm-codex-busy-$$"
SESSION="codexbusy"
TARGET="$SESSION:codex"
CHECKED=0
WT=$(mktemp -d "$ROOT/scratchpad-codex-busy-live.XXXXXX")
STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-busy-live.XXXXXX")

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$WT" "$STATE"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; dump_tail; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

VERSION=$(codex --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'

dump_tail() {
  printf '# codex pane tail:\n' >&2
  tmux -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
}

classify() { fm_busy_classify tmux "$TARGET" codex cx "$STATE"; }

rollout() { fm_busy_codex_kv "$STATE/cx.codex-session" rollout; }

count_events() {  # <task_started|task_complete|turn_aborted>
  local f
  f=$(rollout) || { printf '0'; return; }
  LC_ALL=C grep -cF "\"payload\":{\"type\":\"$1\",\"turn_id\":\"" "$f" || true
}

wait_verdict() {  # <verdict> <seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(classify)" = "$1" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

submit() {  # <text>
  tmux -L "$SOCKET" send-keys -t "$TARGET" -l "$1"
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$TARGET" Enter
}

# The prompts quote shell commands in literal backticks for the model to run.
# shellcheck disable=SC2016
PROMPT_FOREGROUND='Run the shell command `sleep 15` in the foreground and wait for it to finish, then reply with exactly FMCX-ONE and nothing else.'
# shellcheck disable=SC2016
PROMPT_INTERRUPT='Run the shell command `sleep 300` in the foreground and wait for it to finish, then reply with exactly FMCX-TWO.'
# shellcheck disable=SC2016
PROMPT_BACKGROUND='Start the shell command `sleep 20 && echo FMCX-BG-DONE` so that it keeps running in the background, do not wait for it, and end your turn immediately by replying exactly FMCX-STARTED.'

# The task metadata fm-spawn would record: the worktree Codex runs in and a
# spawn_gen minted before the pane launches.
printf 'window=%s\nworktree=%s\nharness=codex\nkind=ship\nbackend=tmux\nspawn_gen=s%s.%s.1\n' \
  "$TARGET" "$WT" "$(date +%s)" "$$" > "$STATE/cx.meta"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 45 -c "$WT"
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n codex -c "$WT" -- codex \
  -c 'model_reasoning_effort="low"' --dangerously-bypass-approvals-and-sandbox --disable hooks \
  "$PROMPT_FOREGROUND" \
  || fail "codex ($VERSION): could not launch in the isolated tmux server"

# 1. A real foreground turn reads busy, then idle when it ends.
wait_verdict 'busy codex-rollout' 90 \
  || fail "codex ($VERSION): a running foreground turn never classified busy codex-rollout (last: $(classify))"
wait_verdict 'idle codex-rollout' 240 \
  || fail "codex ($VERSION): the finished turn never classified idle codex-rollout (last: $(classify))"
CHECKED=$((CHECKED + 1))
pass "codex ($VERSION): a foreground turn classifies busy from its rollout, then idle when it completes"

# 2. An Escape interrupt closes the turn with turn_aborted.
aborted=$(count_events turn_aborted)
submit "$PROMPT_INTERRUPT"
wait_verdict 'busy codex-rollout' 90 \
  || fail "codex ($VERSION): the interruptible turn never classified busy (last: $(classify))"
sleep 5
tmux -L "$SOCKET" send-keys -t "$TARGET" Escape
wait_verdict 'idle codex-rollout' 60 \
  || fail "codex ($VERSION): an Escape interrupt never classified idle (last: $(classify))"
[ "$(count_events turn_aborted)" -gt "$aborted" ] \
  || fail "codex ($VERSION): the interrupt closed the turn without a turn_aborted record"
CHECKED=$((CHECKED + 1))
pass "codex ($VERSION): an Escape interrupt closes the turn with turn_aborted and classifies idle"

# 3. Dormant when idle: a background job finishing does not start a turn.
submit "$PROMPT_BACKGROUND"
wait_verdict 'busy codex-rollout' 90 \
  || fail "codex ($VERSION): the background-job turn never classified busy (last: $(classify))"
wait_verdict 'idle codex-rollout' 180 \
  || fail "codex ($VERSION): the background-job turn never ended (last: $(classify))"
started=$(count_events task_started)
sleep 60
[ "$(count_events task_started)" = "$started" ] \
  || fail "codex ($VERSION): a finished background job started a new turn - Codex is no longer dormant when idle; revisit fm_busy_idle_is_dormant"
[ "$(classify)" = 'idle codex-rollout' ] \
  || fail "codex ($VERSION): an idle worker left classifying '$(classify)' after its background job finished"
CHECKED=$((CHECKED + 1))
pass "codex ($VERSION): idle Codex stays at its prompt after its background job finishes (dormant when idle)"

[ "$CHECKED" -gt 0 ] || fail "live codex busy guard verified nothing; refusing a vacuous pass"
note "codex ($VERSION): rollout $(rollout)"
pass "live codex busy guard verified $CHECKED live behavior(s)"
