#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-capability-check.sh"
DIR=$(fm_test_tmproot fm-capability-check)
FAKEBIN="$DIR/bin"; mkdir -p "$FAKEBIN" "$DIR/project/.firstmate" "$DIR/other"
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
[ -f pool.marker ] || { echo 'not in a git or jj repository' >&2; exit 1; }
echo 'No worktrees in pool.'
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "$1" = daemon ] && exit 0
[ -f ci.marker ] || { echo 'repo not initialized' >&2; exit 1; }
SH
chmod +x "$FAKEBIN/treehouse" "$FAKEBIN/no-mistakes"
: > "$DIR/project/pool.marker"
: > "$DIR/project/ci.marker"
cd "$DIR/other" || fail "cannot enter unrelated cwd"
out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" --surface pool --project "$DIR/project") || fail "empty pool in the project should pass"
assert_contains "$out" 'pool ready' "pool result missing"
out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" --surface ci --project "$DIR/project") || fail "ci should probe the project, not the caller cwd"
assert_contains "$out" 'ci ready' "ci result missing"
if PATH="$FAKEBIN:$PATH" "$SCRIPT" --surface ci --project "$DIR/other" >/dev/null 2>&1; then fail "uninitialized ci project was accepted"; fi
for surface in seed attachments; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DIR/project/.firstmate/$surface-check"
  chmod +x "$DIR/project/.firstmate/$surface-check"
  out=$("$SCRIPT" --surface "$surface" --project "$DIR/project") || fail "$surface preflight should pass"
  assert_contains "$out" "$surface ready" "$surface result missing"
  if "$SCRIPT" --surface "$surface" --project "$DIR/other" >/dev/null 2>&1; then fail "missing $surface declaration was accepted"; fi
done
pass "capability preflight probes pool, ci, seed, and attachments inside the project and refuses absent declarations"
