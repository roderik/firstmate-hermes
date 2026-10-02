#!/usr/bin/env bash
# Shared configuration reader for fleet PR and rollout watches.
# Usage: source this file, then call fm_fleet_config_load [optional path].
set -u
# shellcheck disable=SC2034 # callers consume the exported-by-sourcing configuration values

fm_fleet_config_load() {
  local explicit=${1:-} home config
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  config=${explicit:-${FM_FLEET_CONFIG_FILE:-${FM_CONFIG_OVERRIDE:-$home/config}/fleet-watch.json}}
  [ -f "$config" ] && [ ! -L "$config" ] || {
    printf 'fleet watch configuration is unavailable: %s\n' "$config" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fleet watch configuration requires jq\n' >&2
    return 1
  }
  FM_FLEET_CONFIG_PATH=$config
  FM_FLEET_GH_BIN=${FM_FLEET_GH_BIN:-gh-axi}
  FM_FLEET_REPO=$(jq -er '.repo | strings | select(length > 0)' "$config") || return 1
  FM_FLEET_AUTHORS=$(jq -r '(.authors // []) | map(strings) | join(",")' "$config") || return 1
  FM_FLEET_REQUIRED_TEST_CHECKS=$(jq -r '(.required_test_checks // []) | map(strings) | join(",")' "$config") || return 1
  FM_FLEET_RENUDGE_S=$(jq -er '(.thresholds.renudge_seconds // 2700) | numbers | select(. >= 0)' "$config") || return 1
  FM_FLEET_ESCALATE_S=$(jq -er '(.thresholds.escalate_seconds // 7200) | numbers | select(. >= 0)' "$config") || return 1
  FM_FLEET_BUDGET_S=$(jq -er '(.thresholds.budget_seconds // 24) | numbers | select(. > 0)' "$config") || return 1
  FM_FLEET_MERGE_METHOD=$(jq -er '(.merge_method // "") | strings | select(. == "" or . == "merge" or . == "squash" or . == "rebase")' "$config") || return 1
  FM_FLEET_CADENCE_S=$(jq -er '(.cadence_seconds // 300) | numbers | select(. > 0)' "$config") || return 1
  return 0
}
