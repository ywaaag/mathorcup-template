#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
FILE_PATH=""

usage() {
    echo "Usage: bash scripts/check_retrospective.sh [--task <task_id> | --file <path>] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --file)
            FILE_PATH="$2"
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

args=(check-retrospective --root "$TARGET_DIR")
[[ -n "$TASK_ID" ]] && args+=(--task "$TASK_ID")
[[ -n "$FILE_PATH" ]] && args+=(--file "$FILE_PATH")

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"
