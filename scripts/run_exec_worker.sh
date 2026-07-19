#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
OWNER=""
ACTOR="main_brain"
PACKET_OUT=""
LAST_MESSAGE_OUT=""
MODEL=""
WITH_RETROSPECTIVE=false
NO_CLAIM=false
EPHEMERAL=false
RESUME_SESSION=""
POOL_WORKER=""
GOAL=""
LOCK_ARGS=()

usage() {
    cat <<'EOF'
Usage: bash scripts/run_exec_worker.sh --task <task_id> [options]

Options:
  --owner <owner>             Worker owner name. Required unless --no-claim is used on an already claimed task.
  --actor <actor>             Who is dispatching the task. Default: main_brain
  --target <dir>              Instance root
  --packet-out <path>         Save generated packet to this path
  --last-message-out <path>   Save codex exec final message to this path
  --with-retrospective        Initialize retrospective skeleton too
  --no-claim                  Reuse the current task claim instead of claiming via dispatch
  --lock <path>               Narrow claim lock path (repeatable)
  --goal <text>               Append one main-brain addendum to the generated packet
  --model <model>             Pass an explicit model to codex exec
  --resume-session <id>       Continue one explicit persistent codex exec session
  --pool-worker <key>         Bind this run to a registered worker-pool entry
  --ephemeral                 Do not persist this exec session (cannot be combined with resume)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --owner)
            OWNER="$2"
            shift 2
            ;;
        --actor)
            ACTOR="$2"
            shift 2
            ;;
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --packet-out)
            PACKET_OUT="$(abs_path "$2")"
            shift 2
            ;;
        --last-message-out)
            LAST_MESSAGE_OUT="$(abs_path "$2")"
            shift 2
            ;;
        --with-retrospective)
            WITH_RETROSPECTIVE=true
            shift
            ;;
        --no-claim)
            NO_CLAIM=true
            shift
            ;;
        --lock)
            LOCK_ARGS+=(--lock "$2")
            shift 2
            ;;
        --goal)
            GOAL="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --resume-session)
            RESUME_SESSION="$2"
            shift 2
            ;;
        --pool-worker)
            POOL_WORKER="$2"
            shift 2
            ;;
        --ephemeral)
            EPHEMERAL=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

[[ -n "$TASK_ID" ]] || { usage >&2; exit 2; }
if [[ "$NO_CLAIM" == false && -z "$OWNER" ]]; then
    die "--owner is required unless --no-claim is used"
fi
if [[ "$EPHEMERAL" == true && -n "$RESUME_SESSION" ]]; then
    die "--ephemeral cannot be combined with --resume-session"
fi
if [[ -n "$POOL_WORKER" && -n "$RESUME_SESSION" ]]; then
    :
elif [[ -n "$POOL_WORKER" && "$EPHEMERAL" == true ]]; then
    die "--pool-worker cannot be used with --ephemeral"
fi

require_cmd codex
if ! codex exec --help >/dev/null 2>&1; then
    die "codex exec subcommand is unavailable in the current CLI"
fi

stamp="$(date +%Y%m%d_%H%M%S)"
review_dir="$TARGET_DIR/project/output/review"
exec_run_dir="$review_dir/exec_runs"
mkdir -p "$review_dir"
mkdir -p "$exec_run_dir"

if [[ ! -e "$TARGET_DIR/scripts" ]]; then
    ln -s "$ROOT_DIR/scripts" "$TARGET_DIR/scripts"
fi

if [[ -z "$PACKET_OUT" ]]; then
    PACKET_OUT="$exec_run_dir/${TASK_ID}_${stamp}_exec_packet.md"
fi
if [[ -z "$LAST_MESSAGE_OUT" ]]; then
    LAST_MESSAGE_OUT="$exec_run_dir/${TASK_ID}_${stamp}_exec_last_message.md"
fi

mkdir -p "$(dirname "$PACKET_OUT")" "$(dirname "$LAST_MESSAGE_OUT")"
dispatch_log="$exec_run_dir/${TASK_ID}_${stamp}_dispatch.log"
submit_log="$exec_run_dir/${TASK_ID}_${stamp}_feedback_init.log"
exec_jsonl="$exec_run_dir/${TASK_ID}_${stamp}_exec.jsonl"
exec_stderr="$exec_run_dir/${TASK_ID}_${stamp}_exec.stderr.log"

dispatch_args=(--task "$TASK_ID" --target "$TARGET_DIR" --packet-out "$PACKET_OUT")
dispatch_args+=(--backend codex_exec)
if [[ "$NO_CLAIM" == true ]]; then
    dispatch_args+=(--no-claim)
else
    dispatch_args+=(--owner "$OWNER" --actor "$ACTOR")
fi
dispatch_args+=("${LOCK_ARGS[@]}")
if [[ -n "$POOL_WORKER" && -n "$RESUME_SESSION" ]]; then
    dispatch_args+=(--pool-worker "$POOL_WORKER" --session-id "$RESUME_SESSION")
fi

bash "$SCRIPT_DIR/dispatch_task.sh" "${dispatch_args[@]}" > "$dispatch_log"

submit_args=(--task "$TASK_ID" --target "$TARGET_DIR")
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    submit_args+=(--with-retrospective)
fi
bash "$SCRIPT_DIR/submit_feedback.sh" "${submit_args[@]}" > "$submit_log"

role_name="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" role)"
task_title="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" title)"
feedback_path_rel="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" feedback_path)"
retrospective_path_rel="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" retrospective_path)"
current_owner="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
cycle_id="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" cycle_id)"

if [[ -z "$OWNER" ]]; then
    OWNER="$current_owner"
fi
[[ -n "$OWNER" ]] || die "task $TASK_ID is still unowned; claim it first or pass --owner"

if [[ -n "$GOAL" ]]; then
    cat >> "$PACKET_OUT" <<EOF

## Main-Brain Addendum
- This addendum is more specific than the generic task-slot title above.
- Additional scoped goal:
  - $GOAL
- Extra execution constraints for this run:
  - Prefer the smallest read/write set that can satisfy the scoped goal.
  - Do not inspect Docker/container state unless the scoped goal explicitly requires it.
  - If the scoped goal can be satisfied by updating feedback/retrospective only, stop after doing so.
EOF
fi

if [[ -n "$RESUME_SESSION" ]]; then
    exec_args=(exec resume --json --skip-git-repo-check -o "$LAST_MESSAGE_OUT")
    [[ -n "$MODEL" ]] && exec_args+=(-m "$MODEL")
    exec_args+=("$RESUME_SESSION" -)
else
    exec_args=(exec --json --skip-git-repo-check -C "$TARGET_DIR" -o "$LAST_MESSAGE_OUT")
    [[ "$EPHEMERAL" == true ]] && exec_args+=(--ephemeral)
    [[ -n "$MODEL" ]] && exec_args+=(-m "$MODEL")
    exec_args+=(-)
fi

worker_start_args=(
    --event-type worker.started
    --task "$TASK_ID"
    --actor "$OWNER"
    --owner "$OWNER"
    --artifact "$PACKET_OUT"
    --artifact "$feedback_path_rel"
    --metadata "backend=codex_exec"
    --metadata "cycle_id=$cycle_id"
    --metadata "persistent=$([[ "$EPHEMERAL" == false ]] && echo true || echo false)"
    --metadata "with_retrospective=$WITH_RETROSPECTIVE"
)
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    worker_start_args+=(--artifact "$retrospective_path_rel")
fi
if [[ -n "$MODEL" ]]; then
    worker_start_args+=(--metadata "model=$MODEL")
fi
if [[ -n "$RESUME_SESSION" ]]; then
    worker_start_args+=(--metadata "session_id=$RESUME_SESSION" --metadata "resumed=true")
fi
if [[ -n "$POOL_WORKER" ]]; then
    worker_start_args+=(--metadata "pool_worker_key=$POOL_WORKER")
fi
emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${worker_start_args[@]}" >/dev/null

set +e
exec_started_epoch="$(date +%s)"
if [[ -n "$RESUME_SESSION" ]]; then
    (cd "$TARGET_DIR" && codex "${exec_args[@]}") < "$PACKET_OUT" > "$exec_jsonl" 2> "$exec_stderr"
else
    codex "${exec_args[@]}" < "$PACKET_OUT" > "$exec_jsonl" 2> "$exec_stderr"
fi
exit_code=$?
exec_duration_seconds="$(( $(date +%s) - exec_started_epoch ))"
set -e

SESSION_ID="$(python3 - "$exec_jsonl" <<'PY'
import json
import sys
from pathlib import Path

for raw in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "thread.started" and event.get("thread_id"):
        print(event["thread_id"])
        break
PY
)"
if [[ -n "$RESUME_SESSION" && -n "$SESSION_ID" && "$SESSION_ID" != "$RESUME_SESSION" ]]; then
    exit_code=70
    printf 'resume session mismatch: expected %s, got %s\n' "$RESUME_SESSION" "$SESSION_ID" >> "$exec_stderr"
fi

sync_pool_idle() {
    [[ -n "$POOL_WORKER" && -n "$SESSION_ID" ]] || return 0
    if [[ -n "$RESUME_SESSION" ]]; then
        bash "$SCRIPT_DIR/worker_pool.sh" mark-idle \
            --worker-key "$POOL_WORKER" \
            --task "$TASK_ID" \
            --actor "$ACTOR" \
            --target "$TARGET_DIR" >/dev/null
    else
        bash "$SCRIPT_DIR/worker_pool.sh" register \
            --worker-key "$POOL_WORKER" \
            --role "$role_name" \
            --backend codex_exec \
            --session-id "$SESSION_ID" \
            --last-task "$TASK_ID" \
            --actor "$ACTOR" \
            --replace \
            --target "$TARGET_DIR" >/dev/null
    fi
}

if [[ $exit_code -ne 0 ]]; then
    worker_fail_args=(
        --event-type worker.failed
        --task "$TASK_ID"
        --actor "$OWNER"
        --owner "$OWNER"
        --artifact "$PACKET_OUT"
        --artifact "$exec_jsonl"
        --artifact "$exec_stderr"
        --note "codex exec exited with code $exit_code"
        --metadata "backend=codex_exec"
        --metadata "cycle_id=$cycle_id"
        --metadata "duration_seconds=$exec_duration_seconds"
        --metadata "exit_code=$exit_code"
        --metadata "with_retrospective=$WITH_RETROSPECTIVE"
    )
    [[ -n "$SESSION_ID" ]] && worker_fail_args+=(--metadata "session_id=$SESSION_ID")
    [[ -n "$POOL_WORKER" ]] && worker_fail_args+=(--metadata "pool_worker_key=$POOL_WORKER")
    if [[ -f "$LAST_MESSAGE_OUT" ]]; then
        worker_fail_args+=(--artifact "$LAST_MESSAGE_OUT")
    fi
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${worker_fail_args[@]}" >/dev/null
    echo "[run_exec_worker] FAIL"
    echo "task_id: $TASK_ID"
    echo "role: $role_name"
    echo "owner: $OWNER"
    echo "packet_path: $PACKET_OUT"
    echo "feedback_path: $feedback_path_rel"
    if [[ "$WITH_RETROSPECTIVE" == true ]]; then
        echo "retrospective_path: $retrospective_path_rel"
    fi
    echo "last_message_path: $LAST_MESSAGE_OUT"
    echo "exec_jsonl: $exec_jsonl"
    echo "exec_stderr: $exec_stderr"
    echo "reason: codex exec exited with code $exit_code; task remains claimed until main_brain decides whether to retry, cancel, or reopen it."
    if [[ -n "$POOL_WORKER" ]]; then
        bash "$SCRIPT_DIR/worker_pool.sh" mark-stale --worker-key "$POOL_WORKER" --reason "codex exec failed with code $exit_code" --force --target "$TARGET_DIR" >/dev/null || true
    fi
    echo "next_step_hint: inspect $exec_stderr and $exec_jsonl, then decide whether to retry, replace the session, or cancel"
    exit 1
fi

if [[ ! -f "$LAST_MESSAGE_OUT" ]]; then
    fallback_status="$exec_run_dir/${TASK_ID}_${stamp}_exec_status.md"
    cat > "$fallback_status" <<EOF
# Exec Worker Partial Status

task_id: $TASK_ID
role: $role_name
owner: $OWNER
status: partial
reason: codex exec finished with exit code 0 but did not write the configured last-message file

## Artifacts
- packet_path: $PACKET_OUT
- feedback_path: $feedback_path_rel
- retrospective_path: $retrospective_path_rel
- exec_jsonl: $exec_jsonl
- exec_stderr: $exec_stderr
- expected_last_message_path: $LAST_MESSAGE_OUT

## Main-Brain Next Step
- Inspect the feedback, changed files, and exec log.
- If evidence is sufficient, run check_worker_feedback.sh and close to review.
- If evidence is insufficient, cancel or reopen explicitly.
EOF
    partial_args=(
        --event-type worker.partial \
        --task "$TASK_ID" \
        --actor "$OWNER" \
        --owner "$OWNER" \
        --artifact "$PACKET_OUT" \
        --artifact "$exec_jsonl" \
        --artifact "$exec_stderr" \
        --artifact "$fallback_status" \
        --artifact "$feedback_path_rel" \
        --note "codex exec finished without writing the last-message file" \
        --metadata "backend=codex_exec"
        --metadata "cycle_id=$cycle_id"
        --metadata "duration_seconds=$exec_duration_seconds"
        --metadata "partial_success=true"
        --metadata "with_retrospective=$WITH_RETROSPECTIVE"
    )
    [[ -n "$SESSION_ID" ]] && partial_args+=(--metadata "session_id=$SESSION_ID")
    [[ -n "$POOL_WORKER" ]] && partial_args+=(--metadata "pool_worker_key=$POOL_WORKER")
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${partial_args[@]}" >/dev/null
    sync_pool_idle
    echo "[run_exec_worker] PARTIAL"
    echo "task_id: $TASK_ID"
    echo "reason: codex exec finished without writing the last-message file"
    echo "packet_path: $PACKET_OUT"
    echo "feedback_path: $feedback_path_rel"
    echo "fallback_status_path: $fallback_status"
    echo "exec_jsonl: $exec_jsonl"
    echo "exec_stderr: $exec_stderr"
    [[ -n "$SESSION_ID" ]] && echo "session_id: $SESSION_ID"
    echo "next_step_hint: inspect feedback and fallback status; main_brain decides whether to close, cancel, or reopen"
    exit 0
fi

worker_complete_args=(
    --event-type worker.completed
    --task "$TASK_ID"
    --actor "$OWNER"
    --owner "$OWNER"
    --artifact "$PACKET_OUT"
    --artifact "$LAST_MESSAGE_OUT"
    --artifact "$feedback_path_rel"
    --metadata "backend=codex_exec"
    --metadata "cycle_id=$cycle_id"
    --metadata "duration_seconds=$exec_duration_seconds"
    --metadata "persistent=$([[ "$EPHEMERAL" == false ]] && echo true || echo false)"
    --metadata "with_retrospective=$WITH_RETROSPECTIVE"
)
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    worker_complete_args+=(--artifact "$retrospective_path_rel")
fi
if [[ -n "$MODEL" ]]; then
    worker_complete_args+=(--metadata "model=$MODEL")
fi
[[ -n "$SESSION_ID" ]] && worker_complete_args+=(--metadata "session_id=$SESSION_ID")
[[ -n "$POOL_WORKER" ]] && worker_complete_args+=(--metadata "pool_worker_key=$POOL_WORKER")
emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${worker_complete_args[@]}" >/dev/null

sync_pool_idle
rm -f "$dispatch_log" "$submit_log"

echo "[run_exec_worker] OK"
echo "task_id: $TASK_ID"
echo "role: $role_name"
echo "title: $task_title"
echo "owner: $OWNER"
echo "packet_path: $PACKET_OUT"
echo "feedback_path: $feedback_path_rel"
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    echo "retrospective_path: $retrospective_path_rel"
else
    echo "retrospective_path: $retrospective_path_rel (not auto-initialized this run)"
fi
echo "last_message_path: $LAST_MESSAGE_OUT"
echo "exec_jsonl: $exec_jsonl"
if [[ -s "$exec_stderr" ]]; then
    echo "exec_stderr: $exec_stderr (contains warnings or diagnostics)"
else
    rm -f "$exec_stderr"
fi
if [[ -n "$SESSION_ID" ]]; then
    echo "session_id: $SESSION_ID"
    echo "resume_hint: bash scripts/run_exec_worker.sh --task $TASK_ID --owner $OWNER --no-claim --resume-session $SESSION_ID${POOL_WORKER:+ --pool-worker $POOL_WORKER} --target $TARGET_DIR"
elif [[ "$EPHEMERAL" == false ]]; then
    echo "session_warning: codex exec succeeded but no thread.started.thread_id was found in $exec_jsonl"
fi
if [[ -n "$MODEL" ]]; then
    echo "model: $MODEL"
fi
echo "next_step_1: inspect the exec reply and changed files"
echo "next_step_2: bash scripts/check_worker_feedback.sh --task $TASK_ID --target $TARGET_DIR"
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    echo "next_step_3: bash scripts/check_retrospective.sh --task $TASK_ID --target $TARGET_DIR"
fi
echo "next_step_4: main_brain decides whether to close, reopen, or cancel the task"
