#!/usr/bin/env bash
# Behavior tests for the bounded supervision snapshot and fleet JSON state.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-context)
CONTEXT="$ROOT/bin/fm-supervision-context.sh"
CREW="$ROOT/bin/fm-crew-state.sh"

snapshot_is_reused_without_a_second_drain() {
  local dir first second
  dir=$(make_case stable)
  append_wake "$dir/state" signal event-key 'event path'
  first="$dir/first.out"
  second="$dir/second.out"
  FM_STATE_OVERRIDE="$dir/state" "$CONTEXT" --format compact >"$first" || fail "first snapshot failed"
  FM_STATE_OVERRIDE="$dir/state" "$CONTEXT" --format compact >"$second" || fail "cached snapshot failed"
  assert_equals "$(cat "$first")" "$(cat "$second")" "same generation did not reuse the immutable snapshot"
  grep -F 'WAKE_ACK_REQUIRED:' "$first" >/dev/null || fail "snapshot omitted the exact acknowledgement command"
  [ "$(find "$dir/state/supervision-context" -name '*.compact' | wc -l)" -eq 1 ] \
    || fail "same generation created more than one compact snapshot"
  pass "supervision context drains once and reuses its content-addressed snapshot"
}

json_snapshot_is_bounded_and_valid() {
  local dir out
  dir=$(make_case json)
  append_wake "$dir/state" check check-key 'event/path'
  out=$(FM_STATE_OVERRIDE="$dir/state" "$CONTEXT" --format json) || fail "JSON snapshot failed"
  printf '%s\n' "$out" | jq -e '.snapshot_key and (.drain_exit == 0) and (.record | type == "string")' >/dev/null \
    || fail "JSON snapshot is not the documented bounded record"
  [ "$(printf '%s' "$out" | wc -c)" -lt 40000 ] || fail "default JSON snapshot exceeded its bound"
  pass "JSON supervision context is valid and bounded"
}

fleet_state_json_reads_multiple_ids_once() {
  local dir out
  dir=$(make_case crew-json)
  : > "$dir/state/one.meta"
  : > "$dir/state/two.meta"
  out=$(FM_STATE_OVERRIDE="$dir/state" "$CREW" --json one two) || fail "multi-id crew state failed"
  printf '%s\n' "$out" | jq -e 'length == 2 and .[0].id == "one" and .[1].id == "two" and all(.[]; .state == "unknown")' >/dev/null \
    || fail "multi-id crew state did not return stable JSON entries"
  out=$(FM_STATE_OVERRIDE="$dir/state" "$CREW" --all --json) || fail "--all crew state failed"
  printf '%s\n' "$out" | jq -e 'map(.id) | sort == ["one", "two"]' >/dev/null \
    || fail "--all crew state omitted metadata ids"
  pass "crew state batches multiple ids and --all in one JSON call"
}

snapshot_is_reused_without_a_second_drain
json_snapshot_is_bounded_and_valid
fleet_state_json_reads_multiple_ids_once
