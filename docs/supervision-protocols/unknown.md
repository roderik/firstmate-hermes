Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
Follow the generic supervision contract in `AGENTS.md`.
First cycle: run `bin/fm-supervision-context.sh` once, then choose a supervision wait that the harness can actually wake from.
Ordinary wake: run `bin/fm-supervision-context.sh` once, act from its snapshot, and run the exact generation-bound `--ack-through` command it prints after handling; then repeat that verified wait while supervision is still required.
Before that acknowledgement, interruption leaves the work durable for idempotent re-handling.
Use `bin/fm-watch-arm.sh` only when the harness has a tracked background mechanism that survives the tool call and notifies the model on process exit.
Use a bounded foreground wait over `bin/fm-watch.sh` when that wake mechanism is not verified.
Never use shell `&` for watcher supervision.
Failure or missing cycle only: inspect the failure and restore the same verified wait shape.

Record new verification evidence before promoting an unknown harness to a named snippet.
