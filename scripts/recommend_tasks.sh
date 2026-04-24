#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
OWNER_PREFIX="recommended"
LOCK_ARGS=()

usage() {
    cat <<'EOF'
Usage: bash scripts/recommend_tasks.sh [--target <dir>|--root <dir>] [--owner-prefix <prefix>] [--lock <task_id:path>]...

Advisory-only: reads project/spec/agent_roles.json, project/runtime/task_registry.json,
and project/runtime/work_queue.json from a rendered instance and prints dispatch suggestions.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --owner-prefix)
            OWNER_PREFIX="$2"
            shift 2
            ;;
        --lock)
            LOCK_ARGS+=(--lock "$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

python3 "$SCRIPT_DIR/lib/workflow_state.py" recommend-tasks \
    --root "$TARGET_DIR" \
    --owner-prefix "$OWNER_PREFIX" \
    "${LOCK_ARGS[@]}"
