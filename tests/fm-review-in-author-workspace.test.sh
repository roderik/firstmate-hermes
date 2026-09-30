#!/usr/bin/env bash
# Behavior tests for `fm-spawn.sh <review-id> --review-of <author-id>`: the
# reviewer opens beside the author in the author's own worktree, and neither
# the review spawn nor its teardown rewrites the author's harness wiring there.
#
# These run the REAL fm-spawn and fm-teardown against a fake tmux and an
# isolated git worktree recorded as a live author task.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

TMP_ROOT=$(fm_test_tmproot fm-review-in-author-workspace)
AUTHOR=author-1

make_review_case() {  # <name> -> "<home>|<proj>|<wt>|<fakebin>"
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude opencode gh gh-axi no-mistakes)
  # The shared spawn tmux stub prints nothing for `new-window -P`; the review
  # path needs the new window's id back.
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in new-window) printf '@77\n'; exit 0 ;; esac
case "$*" in *"#{pane_id}"*) [ -z "${FM_FAKE_AUTHOR_GONE:-}" ] || exit 1 ;; esac
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "fm/$AUTHOR"
  fm_write_meta "$home/state/$AUTHOR.meta" \
    "window=fmsess:fm-$AUTHOR" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "backend=tmux" "mode=no-mistakes" "yolo=off"
  mkdir -p "$wt/.claude" "$wt/.opencode/plugins"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch author.turn-ended"}]}]}}' \
    >"$wt/.claude/settings.local.json"
  printf '%s\n' '// author opencode plugin' >"$wt/.opencode/plugins/fm-busy-state.js"
  printf '%s\n' 'token=fm.authorgrok01' >"$wt/.fm-grok-turnend"
  printf '%s\n' 'token=fm.authorkimi01' >"$wt/.fm-kimi-turnend"
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

author_wiring_digest() {  # <wt>
  local wt=$1 f
  for f in .claude/settings.local.json .opencode/plugins/fm-busy-state.js \
    .fm-grok-turnend .fm-kimi-turnend; do
    printf '%s ' "$f"
    cksum <"$wt/$f"
  done
  printf 'exclude '
  cksum <"$(git -C "$wt" rev-parse --git-path info/exclude)" 2>/dev/null || printf 'absent\n'
}

run_review_spawn() {  # <home> <wt> <fakebin> <id> [args...]
  local home=$1 wt=$2 fakebin=$3
  shift 3
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

run_teardown() {  # <home> <fakebin> <id>
  local home=$1 fakebin=$2 id=$3
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    TMUX="${TMUX:-fake,1,0}" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1
}

test_claude_review_keeps_author_wiring() {
  local rec id=review-1 out before after launch_log settings
  rec=$(make_review_case claude-review)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  before=$(author_wiring_digest "$WT_DIR")
  launch_log="$TMP_ROOT/claude-review.launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" run_review_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --review-of "$AUTHOR" --harness claude)
  expect_code 0 $? "claude review spawn should succeed: $out"

  after=$(author_wiring_digest "$WT_DIR")
  [ "$before" = "$after" ] || fail "review spawn changed the author's wiring:
before: $before
after:  $after"
  [ "$(meta_value "$HOME_DIR/state/$id.meta" worktree)" = "$WT_DIR" ] \
    || fail "review did not run in the author's worktree: $(cat "$HOME_DIR/state/$id.meta")"
  [ "$(meta_value "$HOME_DIR/state/$id.meta" review_of)" = "$AUTHOR" ] \
    || fail "review meta does not name its author"
  settings="$HOME_DIR/state/$id.claude-settings.json"
  assert_present "$settings" "review spawn did not write its state-dir claude settings"
  jq -e --arg id "$id" '
    .feedbackDrafts == "off"
    and (.hooks.Stop[0].hooks[0].command | contains($id + ".turn-ended"))
    and (.hooks.UserPromptSubmit[0].hooks[0].command | contains(" " + $id + " busy") or contains("'"'"'" + $id + "'"'"' busy"))
  ' "$settings" >/dev/null || fail "review claude settings are not the reviewer's hooks: $(cat "$settings")"
  grep -F -- "--settings '$settings' --setting-sources user,project" "$launch_log" >/dev/null \
    || fail "claude review launch must load the state-dir settings and skip the author's local settings: $(cat "$launch_log")"
  pass "a claude review spawn loads its hooks from state/ and leaves the author's worktree wiring byte-identical"

  printf '%s\n' '# Review' 'No findings.' >"$HOME_DIR/data/$id/report.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not record the review's completed captain-call inventory"
  out=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 $? "review teardown should succeed: $out"
  after=$(author_wiring_digest "$WT_DIR")
  [ "$before" = "$after" ] || fail "review teardown changed the author's wiring:
before: $before
after:  $after"
  [ -d "$WT_DIR" ] || fail "review teardown removed the author's worktree"
  [ ! -e "$settings" ] || fail "review teardown left the reviewer's claude settings behind"
  pass "review teardown leaves the author's worktree wiring byte-identical and retires the reviewer's settings"
}

test_worktree_wired_harness_refused() {
  local rec id=review-2 out before after harness
  rec=$(make_review_case opencode-review)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  before=$(author_wiring_digest "$WT_DIR")
  for harness in opencode grok kimi; do
    if out=$(run_review_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" --review-of "$AUTHOR" --harness "$harness"); then
      fail "$harness review in the author's workspace must be refused: $out"
    fi
    case "$out" in
      *"harness '$harness' cannot review in author task $AUTHOR's workspace"*) ;;
      *) fail "$harness refusal did not explain itself: $out" ;;
    esac
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$harness refusal left a review task record"
  done
  after=$(author_wiring_digest "$WT_DIR")
  [ "$before" = "$after" ] || fail "a refused review changed the author's wiring"
  pass "opencode, grok, and kimi reviews are refused before touching the author's worktree"
}

test_dead_author_endpoint_falls_back() {
  local rec id=review-3 out
  rec=$(make_review_case dead-author)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(FM_FAKE_AUTHOR_GONE=1 run_review_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --review-of "$AUTHOR" --harness claude)
  case "$out" in
    *"notice: review $id of $AUTHOR falls back to a pooled review worktree in $PROJ_DIR: author endpoint fmsess:fm-$AUTHOR on tmux is gone"*) ;;
    *) fail "a recorded but dead author endpoint must take the logged pool fallback: $out" ;;
  esac
  [ ! -e "$HOME_DIR/state/$id.claude-settings.json" ] \
    || fail "a fallback review must not take the in-workspace claude settings path"
  pass "a review whose recorded author endpoint is dead falls back to a pooled worktree with a logged reason"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_claude_review_keeps_author_wiring
test_worktree_wired_harness_refused
test_dead_author_endpoint_falls_back

echo "all fm-review-in-author-workspace tests passed"
