#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT="${SCALE_ROOT:?}"; HERDR_LAB_HELPER_DEFAULT_ROOT="/home/roderik/.no-mistakes/worktrees/49bdd8e38f81/01M3X6T6PY9RMWYEY704XE7GZ0"
HERDR_LAB_HELPER="$HERDR_LAB_HELPER_DEFAULT_ROOT/bin/fm-herdr-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-cleanup-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name scale)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
production_process_proof() {
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "$PANE"
}
focus_snapshot() {
  local list workspace tab tabs
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg workspace "$workspace" '[.result.workspaces[] | select(.workspace_id == $workspace)] | select(length == 1) | .[0].active_tab_id') || return 1
  tabs=$(lab tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '([.result.tabs[] | select(.focused == true)] | length) == 1 and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)' >/dev/null || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

STALE=${STALE:-6}; LIVE=${LIVE:-6}; ORPHAN=${ORPHAN:-40}; NOISE=${NOISE:-20}
ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus) || fail anchor
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r '.result.tab.tab_id')
tok() { printf '%-22s' "$1" | tr ' ' '0' | cut -c1-22; }
jw() { printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$1" "$2" > "$HOME_DIR/state/$1.herdr-presentation"; }
declare -a STALE_PANES LIVE_PANES
for i in $(seq 1 "$STALE"); do id="stale-$i"; t=$(tok "Stale${i}x"); jw "$id" "$t"
  r=$(lab workspace create --cwd "$ROOT" --label "└ $id · p:$t" --no-focus) || fail create; STALE_PANES+=("$(printf '%s' "$r" | jq -r '.result.root_pane.pane_id')"); done
for i in $(seq 1 "$LIVE"); do id="live-$i"; t=$(tok "Live${i}x"); jw "$id" "$t"; : > "$HOME_DIR/state/$id.meta"
  r=$(lab workspace create --cwd "$ROOT" --label "└ $id · p:$t" --no-focus) || fail create; LIVE_PANES+=("$(printf '%s' "$r" | jq -r '.result.root_pane.pane_id')"); done
for i in $(seq 1 "$ORPHAN"); do jw "orphan-$i" "$(tok "Orphan${i}x")"; done
for i in $(seq 1 "$NOISE"); do lab workspace create --cwd "$ROOT" --label "noise-$i" --no-focus >/dev/null || fail create; done
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail stop
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail reprovision
lab tab focus "$ANCHOR_TAB" >/dev/null || fail focus
for p in "${STALE_PANES[@]}"; do PANE=$p; n=0; until production_process_proof; do n=$((n+1)); [ $n -lt 50 ] || fail "idle shell $p"; sleep 0.1; done; done
WSCOUNT=$(lab workspace list | jq '.result.workspaces|length'); JCOUNT=$(ls "$HOME_DIR/state"/*.herdr-presentation | wc -l)
BEFORE_FOCUS=$(focus_snapshot)
echo "fixture: root=$ROOT workspaces=$WSCOUNT journals=$JCOUNT stale=$STALE live=$LIVE orphan=$ORPHAN noise=$NOISE"
start=$(date +%s.%N)
FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-herdr-session-cleanup.sh" || fail 'cleanup failed'
end=$(date +%s.%N)
printf 'cleanup wall time: %.2fs\n' "$(echo "$end - $start" | bc)"
closed=0; for p in "${STALE_PANES[@]}"; do lab pane get "$p" >/dev/null 2>&1 || closed=$((closed+1)); done
kept=0; for p in "${LIVE_PANES[@]}"; do lab pane get "$p" >/dev/null 2>&1 && kept=$((kept+1)); done
sj=$(ls "$HOME_DIR/state"/stale-*.herdr-presentation 2>/dev/null | wc -l); lj=$(ls "$HOME_DIR/state"/live-*.herdr-presentation | wc -l); oj=$(ls "$HOME_DIR/state"/orphan-*.herdr-presentation | wc -l)
echo "stale panes closed: $closed/$STALE  live panes kept: $kept/$LIVE  journals left: stale=$sj live=$lj orphan=$oj  focus-preserved=$([ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] && echo yes || echo no)"
[ $closed = $STALE ] && [ $kept = $LIVE ] && [ $sj = 0 ] && [ $lj = $LIVE ] && [ $oj = $ORPHAN ] && [ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'outcome mismatch'
pass "scaled lab cleanup retired exactly the stale projections and preserved live ones"
