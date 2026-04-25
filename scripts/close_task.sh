#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
NEXT_STATUS=""
ACCEPTED_BY=""
ACTOR=""

usage() {
    echo "Usage: bash scripts/close_task.sh --task <task_id> --to <review|done> [--accepted-by <main_brain>] [--actor <actor>] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --to)
            NEXT_STATUS="$2"
            shift 2
            ;;
        --accepted-by)
            ACCEPTED_BY="$2"
            shift 2
            ;;
        --actor)
            ACTOR="$2"
            shift 2
            ;;
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

[[ -n "$TASK_ID" && -n "$NEXT_STATUS" ]] || { usage; exit 2; }

main() {
    FROM_STATUS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" status)"
    OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
    feedback_path="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" feedback_path)"
    retro_path="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" retrospective_path)"

    args=(close-task --root "$TARGET_DIR" --task "$TASK_ID" --to "$NEXT_STATUS")
    [[ -n "$ACCEPTED_BY" ]] && args+=(--accepted-by "$ACCEPTED_BY")
    [[ -n "$ACTOR" ]] && args+=(--actor "$ACTOR")

    python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"

    event_args=(
        --event-type task.closed
        --task "$TASK_ID"
        --actor "${ACTOR:-${ACCEPTED_BY:-main_brain}}"
        --owner "$OWNER"
        --from-status "$FROM_STATUS"
        --to-status "$NEXT_STATUS"
        --artifact "$feedback_path"
    )
    [[ "$NEXT_STATUS" == "done" ]] && event_args+=(--artifact "$retro_path" --metadata "accepted_by=$ACCEPTED_BY")
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${event_args[@]}" >/dev/null
    workflow_post_change_consistency "$SCRIPT_DIR" "$TARGET_DIR"
}

workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" main
