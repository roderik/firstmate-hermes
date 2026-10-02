#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/config" "$work/home/state" "$work/bin"
cat > "$work/home/config/fleet-watch.json" <<'JSON'
{
  "repo": "owner/repo",
  "authors": ["author"],
  "required_test_checks": ["Unit Tests"],
  "thresholds": {"budget_seconds": 5, "renudge_seconds": 60, "escalate_seconds": 120},
  "rollout_workflows": [{"name": "Release", "branch": "main"}]
}
JSON
cat > "$work/bin/gh" <<'EOF_GH'
#!/usr/bin/env bash
if [ "${1:-}" = run ] && [ "${2:-}" = list ]; then
  printf '%s\n' '42 completed failure https://github.com/owner/repo/actions/runs/42'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  cat <<'JSON'
{"data":{"repository":{"pullRequest":{"number":7,"url":"https://github.com/owner/repo/pull/7","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","author":{"login":"author"},"commits":{"nodes":[{"commit":{"oid":"0123456789012345678901234567890123456789","statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[{"name":"Unit Tests","conclusion":"SUCCESS"}]}}}}]},"reviewThreads":{"nodes":[]}}}}}
JSON
  exit 0
fi
exit 2
EOF_GH
chmod +x "$work/bin/gh"
PATH="$work/bin:$PATH" FM_FLEET_GH_BIN=gh FM_HOME="$work/home" FM_CONFIG_OVERRIDE="$work/home/config" \
  "$ROOT/bin/fm-release-rollout-check.sh" > "$work/release.out"
grep -q 'Release failure: https://github.com/owner/repo/actions/runs/42' "$work/release.out"
PATH="$work/bin:$PATH" FM_FLEET_GH_BIN=gh FM_HOME="$work/home" FM_CONFIG_OVERRIDE="$work/home/config" \
  "$ROOT/bin/fm-pr-fleet-merge-eligible.sh" https://github.com/owner/repo/pull/7 > "$work/eligible.out"
grep -q '^true owner/repo#7 author=author ' "$work/eligible.out"
PATH="$work/bin:$PATH" FM_FLEET_GH_BIN=gh FM_HOME="$work/home" FM_CONFIG_OVERRIDE="$work/home/config" \
  "$ROOT/bin/fm-pr-stall-sweep.py" > "$work/sweep.out"
test ! -s "$work/sweep.out"
printf 'ok - fleet watch configuration and checks\n'
