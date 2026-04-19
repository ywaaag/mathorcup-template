#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
ROLE=""
STATUS=""
OPEN_ONLY=false

usage() {
    echo "Usage: bash scripts/list_open_tasks.sh [--target <dir>] [--role <role>] [--status <status>] [--open-only]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")"
            shift 2
            ;;
        --role)
            ROLE="$2"
            shift 2
            ;;
        --status)
            STATUS="$2"
            shift 2
            ;;
        --open-only)
            OPEN_ONLY=true
            shift
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

args=(list-tasks --root "$TARGET_DIR")
[[ -n "$ROLE" ]] && args+=(--role "$ROLE")
[[ -n "$STATUS" ]] && args+=(--status "$STATUS")
[[ "$OPEN_ONLY" == true ]] && args+=(--open-only)

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"
