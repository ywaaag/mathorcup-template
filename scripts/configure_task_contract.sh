#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
FILE_PATH=""

usage() {
    echo "Usage: bash scripts/configure_task_contract.sh --task <task_id> --file <contract.json> [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK_ID="$2"; shift 2 ;;
        --file) FILE_PATH="$2"; shift 2 ;;
        --target|--root) TARGET_DIR="$(abs_path "$2")"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

[[ -n "$TASK_ID" && -n "$FILE_PATH" ]] || { usage; exit 2; }
workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" \
    python3 "$SCRIPT_DIR/lib/workflow_state.py" configure-task-contract \
        --root "$TARGET_DIR" --task "$TASK_ID" --file "$FILE_PATH"
