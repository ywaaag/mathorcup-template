#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
NEXT_STATUS="blocked"
REASON=""
ACTOR="main_brain"

usage() {
    echo "Usage: bash scripts/cancel_task.sh --task <task_id> --reason <text> [--to <blocked|ready>] [--actor <actor>] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --reason)
            REASON="$2"
            shift 2
            ;;
        --to)
            NEXT_STATUS="$2"
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

[[ -n "$TASK_ID" && -n "$REASON" ]] || { usage; exit 2; }

main() {
    FROM_STATUS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" status)"
    OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"

    python3 "$SCRIPT_DIR/lib/workflow_state.py" cancel-task --root "$TARGET_DIR" --task "$TASK_ID" --reason "$REASON" --actor "$ACTOR" --to "$NEXT_STATUS"

    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" \
        --event-type task.cancelled \
        --task "$TASK_ID" \
        --actor "$ACTOR" \
        --owner "$OWNER" \
        --from-status "$FROM_STATUS" \
        --to-status "$NEXT_STATUS" \
        --note "$REASON" >/dev/null
    workflow_post_change_consistency "$SCRIPT_DIR" "$TARGET_DIR"
}

workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" main
