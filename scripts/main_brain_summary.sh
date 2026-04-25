#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
OUTPUT_FORMAT="text"

usage() {
    cat <<'EOF'
Usage: bash scripts/main_brain_summary.sh [--target <dir>|--root <dir>] [--json|--format text|json]

Advisory-only: reads rendered instance runtime/config state and prints a one-page
main-brain decision panel. It does not dispatch, close, reopen, cancel, or write state.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --format)
            case "$2" in
                text|json)
                    OUTPUT_FORMAT="$2"
                    shift 2
                    ;;
                *)
                    usage >&2
                    die "unknown format: $2"
                    ;;
            esac
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

args=(main-summary --root "$TARGET_DIR")
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    args+=(--json)
fi

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"
