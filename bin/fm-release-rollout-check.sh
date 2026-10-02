#!/usr/bin/env bash
# Wake firstmate once per new failed completed run of configured workflows.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-fleet-config.sh
. "$SCRIPT_DIR/fm-fleet-config.sh"
if ! fm_fleet_config_load; then
  printf 'release rollout watch is not configured\n'
  exit 0
fi
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/state}"
CONFIG="$FM_FLEET_CONFIG_PATH"
while IFS=$'\t' read -r workflow branch; do
  [ -n "$workflow" ] || continue
  key=$(printf '%s' "$workflow" | tr ' A-Z' '-a-z')
  seen="$STATE/.watch-seen-$key"
  args=(-R "$FM_FLEET_REPO" -w "$workflow")
  [ -n "$branch" ] && args+=(--branch "$branch")
  line=$(timeout "${FM_FLEET_CHECK_TIMEOUT:-20}" "$FM_FLEET_GH_BIN" run list "${args[@]}" --limit 3 --json databaseId,status,conclusion,url,createdAt -q '[.[]|select((.createdAt|fromdateiso8601) > (now - 10800))]|.[0]|select(.!=null)|"\(.databaseId) \(.status) \(.conclusion) \(.url)"' 2>/dev/null) || continue
  read -r run_id status conclusion url <<EOF_LINE
$line
EOF_LINE
  [ "${status:-}" = completed ] || continue
  [ "${run_id:-}" = "$(cat "$seen" 2>/dev/null)" ] && continue
  printf '%s\n' "${run_id:-}" > "$seen"
  case "${conclusion:-}" in
    success|skipped) continue ;;
    *) printf '%s %s: %s\n' "$workflow" "${conclusion:-unknown}" "${url:-}" ;;
  esac
done < <(jq -r '.rollout_workflows // [] | .[] | [(.name // ""), (.branch // "")] | @tsv' "$CONFIG")
