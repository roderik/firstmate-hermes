#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-capability-check.sh"
DIR=$(fm_test_tmproot fm-capability-check)
FAKEBIN="$DIR/bin"; mkdir -p "$FAKEBIN" "$DIR/project/.firstmate"
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '1 available'
SH
chmod +x "$FAKEBIN/treehouse"
out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" --surface pool) || fail "free pool preflight should pass"
assert_contains "$out" 'pool ready' "pool result missing"
cat > "$DIR/project/.firstmate/seed-check" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$DIR/project/.firstmate/seed-check"
out=$("$SCRIPT" --surface seed --project "$DIR/project") || fail "seed preflight should pass"
assert_contains "$out" 'seed ready' "seed result missing"
if "$SCRIPT" --surface seed --project "$DIR" >/dev/null 2>&1; then fail "missing seed declaration was accepted"; fi
pass "capability preflight checks free pool and seed readiness and refuses absent seed checks"
