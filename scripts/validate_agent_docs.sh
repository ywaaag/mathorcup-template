#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

MODE="all"
TARGET_ROOT="$ROOT_DIR"

usage() {
    echo "Usage: $0 [--root <dir>] [--memory-only|--handoff-only|--contracts-only|--paper-config-only|--roles-only|--tasks-only|--queue-only|--feedback-only|--retrospective-only]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            TARGET_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")"
            shift 2
            ;;
        --memory-only)
            MODE="memory"
            shift
            ;;
        --handoff-only)
            MODE="handoff"
            shift
            ;;
        --contracts-only)
            MODE="contracts"
            shift
            ;;
        --paper-config-only)
            MODE="paper"
            shift
            ;;
        --roles-only)
            MODE="roles"
            shift
            ;;
        --tasks-only)
            MODE="tasks"
            shift
            ;;
        --queue-only)
            MODE="queue"
            shift
            ;;
        --feedback-only)
            MODE="feedback"
            shift
            ;;
        --retrospective-only)
            MODE="retrospective"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            echo "[validate_agent_docs] ERROR: unknown option: $1" >&2
            exit 2
            ;;
    esac
done

python3 "$SCRIPT_DIR/lib/workflow_state.py" validate --root "$TARGET_ROOT" --mode "$MODE"
