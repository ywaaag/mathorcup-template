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
EPHEMERAL=true
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
  --ephemeral                 Explicitly enable ephemeral exec mode (default)
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

require_cmd codex
if ! codex exec --help >/dev/null 2>&1; then
    die "codex exec subcommand is unavailable in the current CLI"
fi

stamp="$(date +%Y%m%d_%H%M%S)"
review_dir="$TARGET_DIR/project/output/review"
mkdir -p "$review_dir"

if [[ ! -e "$TARGET_DIR/scripts" ]]; then
    ln -s "$ROOT_DIR/scripts" "$TARGET_DIR/scripts"
fi

if [[ -z "$PACKET_OUT" ]]; then
    PACKET_OUT="$review_dir/${TASK_ID}_${stamp}_exec_packet.md"
fi
if [[ -z "$LAST_MESSAGE_OUT" ]]; then
    LAST_MESSAGE_OUT="$review_dir/${TASK_ID}_${stamp}_exec_last_message.md"
fi

mkdir -p "$(dirname "$PACKET_OUT")" "$(dirname "$LAST_MESSAGE_OUT")"
dispatch_log="$review_dir/${TASK_ID}_${stamp}_dispatch.log"
submit_log="$review_dir/${TASK_ID}_${stamp}_feedback_init.log"
exec_log="$review_dir/${TASK_ID}_${stamp}_exec.log"

dispatch_args=(--task "$TASK_ID" --target "$TARGET_DIR" --packet-out "$PACKET_OUT")
if [[ "$NO_CLAIM" == true ]]; then
    dispatch_args+=(--no-claim)
else
    dispatch_args+=(--owner "$OWNER" --actor "$ACTOR")
fi
dispatch_args+=("${LOCK_ARGS[@]}")

bash "$SCRIPT_DIR/dispatch_task.sh" "${dispatch_args[@]}" > "$dispatch_log"

submit_args=(--task "$TASK_ID" --target "$TARGET_DIR")
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    submit_args+=(--with-retrospective)
fi
bash "$SCRIPT_DIR/submit_feedback.sh" "${submit_args[@]}" > "$submit_log"

role_name="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" task-field --root "$TARGET_DIR" --task "$TASK_ID" --field role)"
task_title="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" task-field --root "$TARGET_DIR" --task "$TASK_ID" --field title)"
feedback_path_rel="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" task-field --root "$TARGET_DIR" --task "$TASK_ID" --field feedback_path)"
retrospective_path_rel="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" task-field --root "$TARGET_DIR" --task "$TASK_ID" --field retrospective_path)"
current_owner="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" task-field --root "$TARGET_DIR" --task "$TASK_ID" --field owner)"

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

exec_args=(exec --skip-git-repo-check -C "$TARGET_DIR" -o "$LAST_MESSAGE_OUT")
[[ "$EPHEMERAL" == true ]] && exec_args+=(--ephemeral)
[[ -n "$MODEL" ]] && exec_args+=(-m "$MODEL")
exec_args+=(-)

set +e
codex "${exec_args[@]}" < "$PACKET_OUT" > "$exec_log" 2>&1
exit_code=$?
set -e

if [[ $exit_code -ne 0 ]]; then
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
    echo "exec_log: $exec_log"
    echo "reason: codex exec exited with code $exit_code; task remains claimed until main_brain decides whether to retry, cancel, or reopen it."
    echo "next_step_hint: inspect $exec_log, then consider bash scripts/cancel_task.sh --task $TASK_ID --reason 'exec failure' --target $TARGET_DIR"
    exit 1
fi

if [[ ! -f "$LAST_MESSAGE_OUT" ]]; then
    echo "[run_exec_worker] FAIL"
    echo "task_id: $TASK_ID"
    echo "reason: codex exec finished without writing the last-message file"
    echo "packet_path: $PACKET_OUT"
    echo "exec_log: $exec_log"
    exit 1
fi

rm -f "$dispatch_log" "$submit_log" "$exec_log"

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
if [[ -n "$MODEL" ]]; then
    echo "model: $MODEL"
fi
echo "next_step_1: inspect the exec reply and changed files"
echo "next_step_2: bash scripts/check_worker_feedback.sh --task $TASK_ID --target $TARGET_DIR"
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    echo "next_step_3: bash scripts/check_retrospective.sh --task $TASK_ID --target $TARGET_DIR"
fi
echo "next_step_4: main_brain decides whether to close, reopen, or cancel the task"
