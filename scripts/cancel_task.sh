#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

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
            TARGET_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")"
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

python3 "$SCRIPT_DIR/lib/workflow_state.py" cancel-task --root "$TARGET_DIR" --task "$TASK_ID" --reason "$REASON" --actor "$ACTOR" --to "$NEXT_STATUS"
