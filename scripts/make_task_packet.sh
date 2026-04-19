#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

ROLE=""
TASK_ID=""
TARGET_DIR="$ROOT_DIR"

usage() {
    echo "Usage: bash scripts/make_task_packet.sh [--role <role>] [--task <task_id>] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            ROLE="$2"
            shift 2
            ;;
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --target)
            TARGET_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")"
            shift 2
            ;;
        main|main_brain|code|code_brain|paper|paper_brain|layout_worker|review_worker|citation_worker|utility|utility_worker)
            case "$1" in
                main) ROLE="main_brain" ;;
                code) ROLE="code_brain" ;;
                paper) ROLE="paper_brain" ;;
                utility) ROLE="utility_worker" ;;
                *) ROLE="$1" ;;
            esac
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

args=(task-packet --root "$TARGET_DIR")
[[ -n "$ROLE" ]] && args+=(--role "$ROLE")
[[ -n "$TASK_ID" ]] && args+=(--task "$TASK_ID")

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"
