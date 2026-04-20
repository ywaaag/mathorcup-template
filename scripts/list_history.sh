#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
LATEST=20
EVENT_TYPE=""
ACTOR=""

usage() {
    echo "Usage: bash scripts/list_history.sh --task <task_id> [--latest <n>] [--event-type <type>] [--actor <actor>] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --latest)
            LATEST="$2"
            shift 2
            ;;
        --event-type)
            EVENT_TYPE="$2"
            shift 2
            ;;
        --actor)
            ACTOR="$2"
            shift 2
            ;;
        --target|--root)
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

python3 "$SCRIPT_DIR/lib/workflow_audit.py" \
    list-history \
    --root "$TARGET_DIR" \
    --task "$TASK_ID" \
    --latest "$LATEST" \
    --event-type "$EVENT_TYPE" \
    --actor "$ACTOR"
