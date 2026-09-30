#!/usr/bin/env bash
# fm-harness-crash-lib.sh - recognize a worker agent that stopped on a
# terminal harness API error, and keep the bounded ledger for relaunching it.
# bin/fm-watch.sh's pane-stale path is the only caller: it reads the same
# bounded capture it already hashes, asks fm_harness_crash_cause whether that
# capture ends on a known terminal error, and on a match relaunches the ship or
# scout fresh through `bin/fm-control.sh <id> relaunch --note ...`.
#
# A terminal error here is one the harness cannot recover from inside the same
# session: the agent sits idle at its composer and every further turn fails the
# same way, so the only fix is a fresh agent in the same local copy.
# Known signatures, matched only for the harness named with them:
#
#   codex  thinking_signature_invalid - the provider rejects the session's own
#          encrypted reasoning items ("Encrypted content could not be decrypted
#          or parsed"), so every later request in that session fails. Only the
#          API error envelope Codex prints as its own error line counts: a line
#          that starts (after an optional error marker such as `■`) with
#          {"error":{"code":"thinking_signature_invalid" and whose envelope,
#          joined across wrapped lines, closes with
#          "type":"invalid_request_error"}}. The token or phrase quoted in
#          prose, such as a finished worker's summary, is not a match.
#
# Only the last FM_HARNESS_CRASH_TAIL_LINES non-blank lines of the capture are
# read (default 15): the error renders just above the composer, so a match
# higher up is scrollback - for example a worker that is reading or editing
# code mentioning the error - and must not trigger a relaunch.
#
# Ledger: state/.harness-crash-relaunch-<id>, one `<epoch>\t<row>` line per
# attempt and one per outcome (attempt, relaunched, failed). The watcher bound
# counts attempt rows inside its window; the file is also the durable per-task
# relaunch record, and teardown removes it.

set -u

# fm_harness_crash_cause <harness> <capture>
# Prints a short cause phrase and returns 0 when the capture's tail shows a
# known terminal error for <harness>; returns 1 otherwise.
fm_harness_crash_cause() {  # <harness> <capture>
  local harness=$1 capture=$2 lines tail
  lines=${FM_HARNESS_CRASH_TAIL_LINES:-}
  case "$lines" in ''|*[!0-9]*|0) lines=15 ;; esac
  tail=$(printf '%s\n' "$capture" | grep -v '^[[:space:]]*$' | tail -n "$lines")
  case "$harness" in
    codex)
      if printf '%s\n' "$tail" | awk '
        { sub(/^[[:space:]]+/, "") }
        /^([^[:space:]{]+[[:space:]]+)?\{"error":\{"code":"thinking_signature_invalid"/ { buf = ""; open = 1 }
        open { buf = buf $0; if (buf ~ /"type":"invalid_request_error"\}\}/) { found = 1; exit } }
        END { exit !found }'; then
        printf 'codex thinking_signature_invalid\n'
        return 0
      fi
      ;;
  esac
  return 1
}

fm_harness_crash_ledger() {  # <state> <id>
  printf '%s/.harness-crash-relaunch-%s\n' "$1" "$2"
}

# Fails when the row cannot be appended.
fm_harness_crash_ledger_add() {  # <state> <id> <attempt|relaunched|failed>
  printf '%s\t%s\n' "$(date +%s)" "$3" >> "$(fm_harness_crash_ledger "$1" "$2")" 2>/dev/null
}

# Count of attempt rows no older than <window-secs>. An absent ledger counts
# zero; an existing ledger that cannot be read fails rather than counting zero.
fm_harness_crash_recent_attempts() {  # <state> <id> <window-secs>
  local ledger cutoff
  ledger=$(fm_harness_crash_ledger "$1" "$2")
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  cutoff=$(( $(date +%s) - $3 ))
  awk -F '\t' -v cutoff="$cutoff" \
    '$1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "attempt" { n++ } END { print n + 0 }' \
    "$ledger" 2>/dev/null
}
