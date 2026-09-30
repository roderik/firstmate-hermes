#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-ready-check.sh"
DIR=$(fm_test_tmproot fm-ready-check)
mkdir -p "$DIR/project/.firstmate" "$DIR/wt/.firstmate"
cat > "$DIR/project/.firstmate/ready-check" <<'SH'
#!/usr/bin/env bash
[ "${READY_CHECK_TOKEN:-}" = pass ] && [ -f worker.marker ]
SH
chmod +x "$DIR/project/.firstmate/ready-check"
: > "$DIR/wt/worker.marker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DIR/wt/.firstmate/ready-check"
chmod +x "$DIR/wt/.firstmate/ready-check"
out=$(READY_CHECK_TOKEN=pass "$SCRIPT" "$DIR/project" "$DIR/wt") || fail "declared check should pass in the worktree"
assert_contains "$out" 'ready-check: passed' "pass result missing"
if READY_CHECK_TOKEN=fail "$SCRIPT" "$DIR/project" "$DIR/wt" >/dev/null 2>&1; then
  fail "a worker-branch ready-check replaced the project declaration"
fi
cat > "$DIR/project/.firstmate/ready-check" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
rc=0
FM_READY_CHECK_TIMEOUT=1 "$SCRIPT" "$DIR/project" "$DIR/wt" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a hung ready check was not bounded"

mkdir -p "$DIR/pkg" "$DIR/pkgwt" "$DIR/fakebin"
printf '#!/usr/bin/env bash\n[ "$*" = "run pr:ready-check" ] && [ -f ready.ok ]\n' > "$DIR/fakebin/npm"
chmod +x "$DIR/fakebin/npm"
printf '%s\n' '{"scripts":{"pr:ready-check":"test -f ready.ok"}}' > "$DIR/pkg/package.json"
cp "$DIR/pkg/package.json" "$DIR/pkgwt/package.json"
: > "$DIR/pkgwt/ready.ok"
out=$(PATH="$DIR/fakebin:$PATH" "$SCRIPT" "$DIR/pkg" "$DIR/pkgwt") || fail "package ready check should pass"
assert_contains "$out" 'ready-check: passed' "package script was not run"
printf '%s\n' '{"scripts":{"pr:ready-check":"exit 0"}}' > "$DIR/pkgwt/package.json"
if PATH="$DIR/fakebin:$PATH" "$SCRIPT" "$DIR/pkg" "$DIR/pkgwt" >/dev/null 2>&1; then
  fail "a worker-edited pr:ready-check script was accepted"
fi

mkdir -p "$DIR/legacy"
out=$("$SCRIPT" "$DIR/legacy" "$DIR/wt") || fail "undeclared check should preserve legacy behavior"
assert_contains "$out" 'not declared' "undeclared check was not reported"

mkdir -p "$DIR/gitwt" "$DIR/gitproj/.firstmate"
git -C "$DIR/gitwt" init -q
printf '#!/usr/bin/env bash\ntest -f ready.ok\n' > "$DIR/gitproj/.firstmate/ready-check"
chmod +x "$DIR/gitproj/.firstmate/ready-check"
: > "$DIR/gitwt/committed"
git -C "$DIR/gitwt" add committed
git -C "$DIR/gitwt" -c user.name=t -c user.email=t@t commit -qm base
COMMITTED_HEAD=$(git -C "$DIR/gitwt" rev-parse HEAD)
: > "$DIR/gitwt/ready.ok"
if "$SCRIPT" "$DIR/gitproj" "$DIR/gitwt" >/dev/null 2>&1; then
  fail "a ready check passed on an uncommitted fix in the worktree"
fi
git -C "$DIR/gitwt" add ready.ok
git -C "$DIR/gitwt" -c user.name=t -c user.email=t@t commit -qm fix
"$SCRIPT" "$DIR/gitproj" "$DIR/gitwt" >/dev/null 2>&1 || fail "a clean committed worktree should pass"
if "$SCRIPT" "$DIR/gitproj" "$DIR/gitwt" "$COMMITTED_HEAD" >/dev/null 2>&1; then
  fail "a ready check ran against a worktree HEAD other than the handed-off head"
fi

# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
printf '#!/usr/bin/env bash\necho line-one\necho line-two\nexit 3\n' > "$DIR/project/.firstmate/ready-check"
reason=$(fm_dod_ready_check "$DIR/project" "$DIR/wt") && fail "failing ready check was accepted"
[ "$(printf '%s\n' "$reason" | wc -l | tr -d ' ')" = 1 ] || fail "ready check reason spans several lines: $reason"
assert_contains "$reason" 'project ready check failed' "ready check reason missing"
pass "project-declared ready checks gate pass, failure, timeout, worker edits, dirty worktrees, head mismatches, package scripts, and legacy projects"
