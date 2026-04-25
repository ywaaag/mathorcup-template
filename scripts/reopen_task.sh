#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
NEXT_STATUS=""
REASON=""
OWNER=""
ACTOR="main_brain"
LOCK_ARGS=()

usage() {
    echo "Usage: bash scripts/reopen_task.sh --task <task_id> --to <ready|review|in_progress> --reason <text> [--owner <owner>] [--actor <actor>] [--lock <path>]... [--target <dir>]" >&2
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
        --reason)
            REASON="$2"
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
        --lock)
            LOCK_ARGS+=(--lock "$2")
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

[[ -n "$TASK_ID" && -n "$NEXT_STATUS" && -n "$REASON" ]] || { usage; exit 2; }

main() {
    FROM_STATUS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" status)"
    PREV_OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"

    args=(reopen-task --root "$TARGET_DIR" --task "$TASK_ID" --to "$NEXT_STATUS" --reason "$REASON" --actor "$ACTOR")
    [[ -n "$OWNER" ]] && args+=(--owner "$OWNER")
    args+=("${LOCK_ARGS[@]}")

    python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"

    CURRENT_OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
    event_owner="$CURRENT_OWNER"
    [[ -z "$event_owner" ]] && event_owner="$PREV_OWNER"
    event_args=(
        --event-type task.reopened
        --task "$TASK_ID"
        --actor "$ACTOR"
        --owner "$event_owner"
        --from-status "$FROM_STATUS"
        --to-status "$NEXT_STATUS"
        --note "$REASON"
    )
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${event_args[@]}" >/dev/null
    workflow_post_change_consistency "$SCRIPT_DIR" "$TARGET_DIR"
}

workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" main
