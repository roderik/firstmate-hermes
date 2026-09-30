#!/usr/bin/env bash
# tests/fm-watch-harness-crash.test.sh - a worker that stopped on a terminal
# harness API error is relaunched fresh by the watcher's pane-stale path
# (bin/fm-watch.sh harness_crash_relaunch, signatures in
# bin/fm-harness-crash-lib.sh). Observed on a live fleet: 13 of about 40 Codex
# workers sat dead at their composer on `thinking_signature_invalid`, each an
# ordinary idle pane that supervision never recovered.
#
# Each case drives a real fm-watch.sh subprocess against a fixture pane through
# the shared fake tmux, with FM_CONTROL_BIN pointing at a recording fake of
# bin/fm-control.sh, and asserts both directions: a crashed Codex pane is
# relaunched through the control plane with a continue note and wakes nobody,
# while the bound, a failed relaunch, another harness, and an error that is
# only scrollback all leave or return the pane to an ordinary stale wake.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-harness-crash-tests)
WINDOW="test:fm-crash"
KEY=test_fm-crash
WORKING='state: working · source: run-step · ci running'

# The last lines of a Codex pane that died on the error, as it renders: the
# error above an idle composer and footer.
codex_crash_pane() {
  printf '%s\n' \
    '• Ran bun run test' \
    '  └ 412 pass' \
    '' \
    '■ {"error":{"code":"thinking_signature_invalid","message":"The encrypted content for item rs_0123 could not be verified. Reason: Encrypted content could not be decrypted or parsed.","type":"invalid_request_error"}}' \
    '' \
    '› Ask Codex to do anything' \
    '' \
    '  ? for shortcuts                                   61% context left'
}

# A fake bin/fm-control.sh: records its arguments, and on success rewrites the
# pane the way a fresh agent would, so the next poll no longer shows the error.
# The success cases read the crew as provably working, as a fresh agent busy on
# its instructions is, so the replacement pane is absorbed rather than surfaced.
make_fake_control() {  # <case-dir>
  local dir=$1
  cat > "$dir/fakebin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CONTROL_LOG"
if [ "${FM_TEST_CONTROL_RC:-0}" -ne 0 ]; then
  echo "error: relaunch of crash was refused before its agent was touched; nothing changed" >&2
  exit "$FM_TEST_CONTROL_RC"
fi
printf 'fresh agent reading its instructions %s\n' "$$" > "$FM_TEST_CAPTURE"
exit 0
SH
  chmod +x "$dir/fakebin/fm-control.sh"
}

# A lane stably stale at its current pane: the recorded hash matches and the
# count is one poll in, so the next poll is the first stale sighting.
crash_fixture() {  # <name> <harness> <pane-file-content-fn>
  local name=$1 harness=$2 fn=$3 dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/config"
  "$fn" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=%s\nbackend=tmux\n' "$WINDOW" "$harness" > "$state/crash.meta"
  printf 'working: implementing the fix\n' > "$state/crash.status"
  prime_status_seen "$state" "$state/crash.status"
  printf '%s' "$(hash_pane_file "$dir/pane.txt")" > "$state/.hash-$KEY"
  printf '1\n' > "$state/.count-$KEY"
  make_fake_control "$dir"
  : > "$dir/control.log"
  printf '%s\n' "$dir"
}

hash_pane_file() {
  local text
  text=$(cat "$1")
  hash_text "$text"
}

# Run one watcher over <dir>. mode=exit waits for it to surface a wake;
# mode=absorb waits for three whole poll cycles and stops it.
crash_round() {  # <dir> <exit|absorb> [extra env assignments...]
  local dir=$1 mode=$2 pid cycles=0
  shift 2
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=codex FM_FAKE_TMUX_WINDOWS=fm-crash \
    FM_CONFIG_OVERRIDE="$dir/config" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_CONTROL_BIN="$dir/fakebin/fm-control.sh" \
    FM_TEST_CONTROL_LOG="$dir/control.log" FM_TEST_CAPTURE="$dir/pane.txt" \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    env "$@" "$WATCH" >> "$dir/watch.out" 2>> "$dir/watch.err" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || return 1
    return 0
  fi
  while [ "$cycles" -lt 3 ]; do
    wait_poll_cycle "$dir/state" "$pid" 300 || { reap "$pid"; return 1; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
}

# Same helpers as fm-watch-triage.test.sh: a watcher must be observed through
# whole poll cycles, and an owned watcher must be stopped with a bounded wait.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

stale_wakes() {  # <state>
  awk -F '\t' -v w="$WINDOW" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

ledger_rows() {  # <state> <row>
  awk -F '\t' -v r="$2" '$2 == r { n++ } END { print n + 0 }' \
    "$1/.harness-crash-relaunch-crash" 2>/dev/null || echo 0
}

seed_attempts() {  # <state> <count> <age-secs>
  local i=0 at
  at=$(( $(date +%s) - $3 ))
  while [ "$i" -lt "$2" ]; do
    printf '%s\tattempt\n' "$at" >> "$1/.harness-crash-relaunch-crash"
    i=$((i + 1))
  done
}

test_codex_crash_is_relaunched_silently_with_a_continue_note() {
  local dir state
  dir=$(crash_fixture relaunch codex codex_crash_pane); state="$dir/state"
  crash_round "$dir" absorb FM_FAKE_CREW_STATE="$WORKING" || fail "the watcher stopped instead of recovering the crashed worker: $(cat "$dir/watch.out" "$dir/watch.err")"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "expected exactly one relaunch, control log: $(cat "$dir/control.log")"
  grep -F 'crash relaunch --note ' "$dir/control.log" >/dev/null \
    || fail "the relaunch did not go through the control plane with a note: $(cat "$dir/control.log")"
  grep -F 'thinking_signature_invalid' "$dir/control.log" >/dev/null \
    || fail "the continue note did not name the error: $(cat "$dir/control.log")"
  grep -F 'Continue where it stopped' "$dir/control.log" >/dev/null \
    || fail "the note did not tell the fresh worker to continue: $(cat "$dir/control.log")"
  [ "$(stale_wakes "$state")" -eq 0 ] || fail "a successful relaunch still woke firstmate: $(cat "$state/.wake-queue")"
  [ "$(ledger_rows "$state" attempt)" -eq 1 ] && [ "$(ledger_rows "$state" relaunched)" -eq 1 ] \
    || fail "the relaunch ledger did not record the attempt and outcome: $(cat "$state/.harness-crash-relaunch-crash" 2>/dev/null)"
  pass "a Codex worker dead on thinking_signature_invalid is relaunched once with a continue note and no wake"
}

test_old_attempts_outside_the_window_do_not_count() {
  local dir state
  dir=$(crash_fixture old-attempts codex codex_crash_pane); state="$dir/state"
  seed_attempts "$state" 3 7200
  crash_round "$dir" absorb FM_FAKE_CREW_STATE="$WORKING" || fail "old ledger rows blocked recovery: $(cat "$dir/watch.out" "$dir/watch.err")"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "attempts older than the window still counted: $(cat "$dir/control.log")"
  pass "relaunch attempts older than the window do not spend the bound"
}

test_bound_spent_surfaces_an_ordinary_stale_wake() {
  local dir state
  dir=$(crash_fixture bound codex codex_crash_pane); state="$dir/state"
  seed_attempts "$state" 3 60
  crash_round "$dir" exit || fail "a worker past its relaunch bound was never surfaced: $(cat "$dir/watch.out" "$dir/watch.err")"
  [ ! -s "$dir/control.log" ] || fail "a worker past its bound was relaunched again: $(cat "$dir/control.log")"
  grep -F "stale: $WINDOW (stopped on codex thinking_signature_invalid; auto-relaunch bound spent: 3 in 3600s)" "$dir/watch.out" >/dev/null \
    || fail "the stale wake did not name the error and the spent bound: $(cat "$dir/watch.out")"
  [ "$(stale_wakes "$state")" -eq 1 ] || fail "expected one stale wake, queue: $(cat "$state/.wake-queue" 2>/dev/null)"
  pass "a worker that keeps crashing past the bound surfaces as one ordinary stale wake"
}

test_failed_relaunch_surfaces_the_failure() {
  local dir state
  dir=$(crash_fixture failed codex codex_crash_pane); state="$dir/state"
  crash_round "$dir" exit FM_TEST_CONTROL_RC=1 \
    || fail "a failed relaunch was never surfaced: $(cat "$dir/watch.out" "$dir/watch.err")"
  grep -F "auto-relaunch failed: error: relaunch of crash was refused" "$dir/watch.out" >/dev/null \
    || fail "the stale wake did not carry the relaunch failure: $(cat "$dir/watch.out")"
  [ "$(ledger_rows "$state" failed)" -eq 1 ] || fail "the failed relaunch was not ledgered"
  pass "a relaunch the control plane refuses surfaces as a stale wake naming the refusal"
}

claude_crash_pane() { codex_crash_pane; }

scrollback_crash_pane() {
  local i=0
  codex_crash_pane | sed -n '4p'
  while [ "$i" -lt 20 ]; do
    printf 'reading bin/fm-watch.sh line %s\n' "$i"
    i=$((i + 1))
  done
  printf '› Ask Codex to do anything\n'
}

test_other_harness_and_scrollback_keep_ordinary_triage() {
  local dir state spec name harness fn
  for spec in 'other-harness|claude|claude_crash_pane' 'scrollback|codex|scrollback_crash_pane'; do
    name=${spec%%|*}; harness=${spec#*|}; fn=${harness#*|}; harness=${harness%%|*}
    dir=$(crash_fixture "$name" "$harness" "$fn"); state="$dir/state"
    crash_round "$dir" exit || fail "$name: the ordinary stale path did not surface: $(cat "$dir/watch.out" "$dir/watch.err")"
    [ ! -s "$dir/control.log" ] || fail "$name: a pane without a live terminal error was relaunched: $(cat "$dir/control.log")"
    grep -F 'stopped on' "$dir/watch.out" >/dev/null \
      && fail "$name: an ordinary stale was reported as a harness crash: $(cat "$dir/watch.out")"
    grep -F "stale: $WINDOW" "$dir/watch.out" >/dev/null \
      || fail "$name: the ordinary stale wake is missing: $(cat "$dir/watch.out")"
  done
  pass "the error on another harness or only in scrollback leaves ordinary stale triage unchanged"
}

test_codex_crash_is_relaunched_silently_with_a_continue_note
test_old_attempts_outside_the_window_do_not_count
test_bound_spent_surfaces_an_ordinary_stale_wake
test_failed_relaunch_surfaces_the_failure
test_other_harness_and_scrollback_keep_ordinary_triage

echo "# all fm-watch-harness-crash tests passed"
