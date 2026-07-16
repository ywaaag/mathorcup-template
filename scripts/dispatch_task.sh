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
PRINT_ONLY=false
LOCK_ARGS=()
BACKEND="relay"

usage() {
    echo "Usage: bash scripts/dispatch_task.sh --task <task_id> [--owner <owner>] [--actor <actor>] [--backend <relay|codex_exec|subagent|human>] [--lock <path>]... [--packet-out <path>] [--print-only] [--no-claim] [--target <dir>]" >&2
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
        --backend)
            BACKEND="$2"
            case "$BACKEND" in relay|codex_exec|subagent|human) ;; *) die "invalid backend: $BACKEND" ;; esac
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
        --print-only)
            PRINT_ONLY=true
            shift
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

main() {
    python3 "$SCRIPT_DIR/lib/workflow_state.py" check-task-contract --root "$TARGET_DIR" --task "$TASK_ID" --for-dispatch >/dev/null
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

    if [[ -z "$PACKET_OUT" && "$PRINT_ONLY" == false ]]; then
        stamp="$(date +%Y%m%d_%H%M%S)"
        PACKET_OUT="$TARGET_DIR/project/workflow/packets/${TASK_ID}_${stamp}.md"
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
        --metadata "backend=$BACKEND"
        --note "task dispatched and packet ready for worker handoff"
    )
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${dispatch_event_args[@]}" >/dev/null

    packet_event_args=(
        --event-type task.packet_generated
        --task "$TASK_ID"
        --actor "$ACTOR"
        --owner "$OWNER"
        --metadata "role=$ROLE_NAME"
        --metadata "backend=$BACKEND"
    )
    if [[ -n "$PACKET_OUT" ]]; then
        packet_sha256="$(sha256sum "$PACKET_OUT" | awk '{print $1}')"
        packet_event_args+=(--metadata "packet_sha256=$packet_sha256")
        packet_event_args+=(--artifact "$PACKET_OUT")
    else
        packet_event_args+=(--note "packet generated to stdout only")
    fi
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${packet_event_args[@]}" >/dev/null
    workflow_post_change_consistency "$SCRIPT_DIR" "$TARGET_DIR"

    if [[ "$NO_CLAIM" == true ]]; then
        echo "[dispatch] claim skipped for task $TASK_ID"
    else
        echo "[dispatch] claimed task $TASK_ID for owner $OWNER"
    fi
    echo "[dispatch] queue board refreshed"
    echo "[dispatch] canonical feedback skeleton path: ensured via task.dispatched callback when missing"
    if [[ -n "$PACKET_OUT" ]]; then
        echo "[dispatch] packet written to $PACKET_OUT"
    else
        echo "[dispatch] packet printed only; no packet artifact was written"
    fi
    echo ""
    printf '%s' "$packet"
}

workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" main
