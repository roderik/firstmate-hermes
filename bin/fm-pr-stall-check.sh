#!/usr/bin/env bash
# Run the configurable fleet PR stall sweep as a registered custom check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-fleet-config.sh
. "$SCRIPT_DIR/fm-fleet-config.sh"
fm_fleet_config_load || { printf 'fleet PR stall watch is not configured\n'; exit 0; }
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/state}"
STAMP="$STATE/.pr-stall-last"
now=$(date +%s)
last=$(cat "$STAMP" 2>/dev/null || printf '0')
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ $((now - last)) -lt "$FM_FLEET_CADENCE_S" ]; then
  exit 0
fi
printf '%s\n' "$now" > "$STAMP"
export FM_FLEET_CONFIG_FILE="$FM_FLEET_CONFIG_PATH"
exec timeout "${FM_FLEET_CHECK_TIMEOUT:-28}" python3 "$SCRIPT_DIR/fm-pr-stall-sweep.py"
