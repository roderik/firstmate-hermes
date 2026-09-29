#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-ready-check.sh"
DIR=$(fm_test_tmproot fm-ready-check)
mkdir -p "$DIR/project/.firstmate"
cat > "$DIR/project/.firstmate/ready-check" <<'SH'
#!/usr/bin/env bash
[ "${READY_CHECK_TOKEN:-}" = pass ]
SH
chmod +x "$DIR/project/.firstmate/ready-check"
out=$(READY_CHECK_TOKEN=pass "$SCRIPT" "$DIR/project") || fail "declared check should pass"
assert_contains "$out" 'ready-check: passed' "pass result missing"
if READY_CHECK_TOKEN=fail "$SCRIPT" "$DIR/project" >/dev/null 2>&1; then fail "declared check failure was accepted"; fi
mkdir -p "$DIR/package"
cat > "$DIR/package/package.json" <<'JSON'
{"scripts":{"pr:ready-check":"test -f ready.ok"}}
JSON
: > "$DIR/package/ready.ok"
out=$("$SCRIPT" "$DIR/package") || fail "package ready check should pass"
assert_contains "$out" 'ready-check: passed' "package script was not run"
mkdir -p "$DIR/legacy"
out=$("$SCRIPT" "$DIR/legacy") || fail "undeclared check should preserve legacy behavior"
assert_contains "$out" 'not declared' "undeclared check was not reported"
pass "project-declared ready checks gate pass, failure, package scripts, and legacy projects"
