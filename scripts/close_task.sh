#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
NEXT_STATUS=""
ACCEPTED_BY=""

usage() {
    echo "Usage: bash scripts/close_task.sh --task <task_id> --to <review|done> [--accepted-by <main_brain>] [--target <dir>]" >&2
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

[[ -n "$TASK_ID" && -n "$NEXT_STATUS" ]] || { usage; exit 2; }

args=(close-task --root "$TARGET_DIR" --task "$TASK_ID" --to "$NEXT_STATUS")
[[ -n "$ACCEPTED_BY" ]] && args+=(--accepted-by "$ACCEPTED_BY")

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"
