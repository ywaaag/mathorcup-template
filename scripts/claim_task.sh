#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
OWNER=""
LOCK_ARGS=()

usage() {
    echo "Usage: bash scripts/claim_task.sh --task <task_id> --owner <owner> [--lock <path>]... [--target <dir>]" >&2
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
        --lock)
            LOCK_ARGS+=(--lock "$2")
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

[[ -n "$TASK_ID" && -n "$OWNER" ]] || { usage; exit 2; }

python3 "$SCRIPT_DIR/lib/workflow_state.py" claim-task --root "$TARGET_DIR" --task "$TASK_ID" --owner "$OWNER" "${LOCK_ARGS[@]}"
