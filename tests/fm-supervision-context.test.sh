#!/usr/bin/env bash
# Behavior tests for the bounded supervision context presentation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-context)
CONTEXT="$ROOT/bin/fm-supervision-context.sh"

mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

context_prints_wake_and_acknowledgement() {
  local dir out
  dir=$(make_case wake)
  append_wake "$dir/state" signal event-key 'event path'
  out="$dir/context.out"
  FM_STATE_OVERRIDE="$dir/state" "$CONTEXT" >"$out" || fail "context failed: $(cat "$out")"
  grep -F 'event path' "$out" >/dev/null || fail "context omitted the wake row: $(cat "$out")"
  grep -F 'WAKE_ACK_REQUIRED:' "$out" >/dev/null || fail "context omitted the exact acknowledgement command"
  grep -Fx 'drain-exit: 0' "$out" >/dev/null || fail "context did not report the drain exit"
  [ ! -e "$dir/state/supervision-context" ] || fail "context persisted a snapshot store"
  pass "supervision context presents the drained wake and its acknowledgement"
}

context_drains_on_every_invocation() {
  local dir out status
  dir=$(make_case every-invocation)
  status="$dir/state/task1.status"
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$dir/state" "$CONTEXT" >/dev/null || fail "first context failed"
  printf 'note: captain said use REST\n' >> "$status"
  out="$dir/second.out"
  FM_STATE_OVERRIDE="$dir/state" "$CONTEXT" >"$out" || fail "second context failed: $(cat "$out")"
  grep -F 'task1 note: captain said use REST' "$out" >/dev/null \
    || fail "a status line added without a queue row was not presented: $(cat "$out")"
  pass "supervision context reruns the drain even when the wake queue is unchanged"
}

context_rejects_arguments() {
  local dir arg
  dir=$(make_case args)
  for arg in --format --full --since-seq --home; do
    if FM_STATE_OVERRIDE="$dir/state" "$CONTEXT" "$arg" >/dev/null 2>&1; then
      fail "context accepted removed option $arg"
    fi
  done
  if FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" --format compact >/dev/null 2>&1; then
    fail "wake drain accepted a presentation flag"
  fi
  pass "supervision context and wake drain expose only their single presentation"
}

context_prints_wake_and_acknowledgement
context_drains_on_every_invocation
context_rejects_arguments
