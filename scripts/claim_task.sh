#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
OWNER=""
ACTOR=""
LOCK_ARGS=()

usage() {
    echo "Usage: bash scripts/claim_task.sh --task <task_id> --owner <owner> [--actor <actor>] [--lock <path>]... [--target <dir>]" >&2
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

[[ -n "$TASK_ID" && -n "$OWNER" ]] || { usage; exit 2; }

FROM_STATUS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" status)"
ROLE_NAME="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" role)"

args=(claim-task --root "$TARGET_DIR" --task "$TASK_ID" --owner "$OWNER")
[[ -n "$ACTOR" ]] && args+=(--actor "$ACTOR")
args+=("${LOCK_ARGS[@]}")

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"

event_args=(
    --event-type task.claimed
    --task "$TASK_ID"
    --actor "${ACTOR:-$OWNER}"
    --owner "$OWNER"
    --from-status "$FROM_STATUS"
    --to-status in_progress
    --metadata "role=$ROLE_NAME"
)
for pair in "${LOCK_ARGS[@]}"; do
    if [[ "$pair" != "--lock" ]]; then
        event_args+=(--artifact "$pair")
    fi
done
emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${event_args[@]}" >/dev/null
