#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"

usage() {
    cat <<'EOF'
Usage: bash scripts/extract_policy_hints.sh [--target <dir>|--root <dir>]

Scans rendered worker feedback / retrospective artifacts and writes
project/output/review/policy_hints_candidate.md for main-brain review.
It does not modify runtime truth files.
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

python3 "$SCRIPT_DIR/lib/workflow_state.py" extract-policy-hints --root "$TARGET_DIR"
