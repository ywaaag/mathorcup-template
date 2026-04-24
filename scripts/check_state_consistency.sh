#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"

usage() {
    cat <<'EOF'
Usage: bash scripts/check_state_consistency.sh [--target <dir>|--root <dir>]

Advisory-only: checks registry, queue, event log, feedback, and retrospective
artifact consistency in a rendered instance. It does not repair or write state.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
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

python3 "$SCRIPT_DIR/lib/workflow_state.py" state-consistency --root "$TARGET_DIR"
