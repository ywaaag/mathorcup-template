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
NO_CLAIM=false
LOCK_ARGS=()

usage() {
    echo "Usage: bash scripts/dispatch_task.sh --task <task_id> [--owner <owner>] [--actor <actor>] [--lock <path>]... [--packet-out <path>] [--no-claim] [--target <dir>]" >&2
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
        --packet-out)
            PACKET_OUT="$2"
            shift 2
            ;;
        --no-claim)
            NO_CLAIM=true
            shift
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

[[ -n "$TASK_ID" ]] || { usage; exit 2; }
if [[ "$NO_CLAIM" == false && -z "$OWNER" ]]; then
    echo "--owner is required unless --no-claim is used" >&2
    exit 2
fi

if [[ "$NO_CLAIM" == false ]]; then
    bash "$SCRIPT_DIR/claim_task.sh" \
        --task "$TASK_ID" \
        --owner "$OWNER" \
        --actor "$ACTOR" \
        "${LOCK_ARGS[@]}" \
        --target "$TARGET_DIR"
fi

python3 "$SCRIPT_DIR/lib/workflow_state.py" render-queue --root "$TARGET_DIR" >/dev/null
packet="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" task-packet --root "$TARGET_DIR" --task "$TASK_ID")"
ROLE_NAME="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" role)"
CURRENT_OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
if [[ -z "$OWNER" ]]; then
    OWNER="$CURRENT_OWNER"
fi

if [[ -n "$PACKET_OUT" ]]; then
    mkdir -p "$(dirname "$PACKET_OUT")"
    printf '%s' "$packet" > "$PACKET_OUT"
fi

dispatch_event_args=(
    --event-type task.dispatched
    --task "$TASK_ID"
    --actor "$ACTOR"
    --owner "$OWNER"
    --from-status in_progress
    --to-status in_progress
    --metadata "role=$ROLE_NAME"
    --note "task dispatched and packet ready for worker handoff"
)
emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${dispatch_event_args[@]}" >/dev/null

packet_event_args=(
    --event-type task.packet_generated
    --task "$TASK_ID"
    --actor "$ACTOR"
    --owner "$OWNER"
    --metadata "role=$ROLE_NAME"
)
if [[ -n "$PACKET_OUT" ]]; then
    packet_event_args+=(--artifact "$PACKET_OUT")
else
    packet_event_args+=(--note "packet generated to stdout only")
fi
emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${packet_event_args[@]}" >/dev/null

if [[ "$NO_CLAIM" == true ]]; then
    echo "[dispatch] claim skipped for task $TASK_ID"
else
    echo "[dispatch] claimed task $TASK_ID for owner $OWNER"
fi
echo "[dispatch] queue board refreshed"
if [[ -n "$PACKET_OUT" ]]; then
    echo "[dispatch] packet written to $PACKET_OUT"
fi
echo ""
printf '%s' "$packet"
