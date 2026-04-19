#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
FEEDBACK_ONLY=false
WITH_RETROSPECTIVE=false

usage() {
    echo "Usage: bash scripts/submit_feedback.sh --task <task_id> [--feedback-only | --with-retrospective] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --feedback-only)
            FEEDBACK_ONLY=true
            shift
            ;;
        --with-retrospective)
            WITH_RETROSPECTIVE=true
            shift
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

[[ -n "$TASK_ID" ]] || { usage; exit 2; }

args=(init-feedback --root "$TARGET_DIR" --task "$TASK_ID")
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    args+=(--with-retrospective)
elif [[ "$FEEDBACK_ONLY" == true ]]; then
    args+=(--feedback-only)
fi

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"
