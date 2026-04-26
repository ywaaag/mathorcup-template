#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
MODE="report"
OUTPUT_FORMAT="text"

usage() {
    cat <<'EOF'
Usage: bash scripts/check_handoff_intake.sh [--target <dir>] [--latest|--files] [--json|--format text|json]

Read-only handoff intake guard for rendered instances.
- Default report mode is the human / Agent intake guard before consuming handoffs
- Reads only MEMORY.md -> ## Handoff Index
- Validates indexed handoff files still exist and still satisfy the handoff contract
- Warns about disk handoffs under project/output/handoff/P*.md that are not indexed
- Never includes unindexed handoffs in the default consumable result
- --latest and --files are shortcuts for retrieving indexed paths only
- In shortcut modes, stdout contains only indexed paths; warnings are printed to stderr
- JSON output is available only in default report mode; shortcut modes stay path-only
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")"
            shift 2
            ;;
        --latest)
            MODE="latest"
            shift
            ;;
        --files)
            MODE="files"
            shift
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
                    echo "[check_handoff_intake] ERROR: unknown format: $2" >&2
                    exit 2
                    ;;
            esac
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            echo "[check_handoff_intake] ERROR: unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if [[ "$OUTPUT_FORMAT" == "json" && "$MODE" != "report" ]]; then
    echo "[check_handoff_intake] ERROR: --json/--format json cannot be combined with --latest or --files; shortcut stdout must stay indexed paths only" >&2
    exit 2
fi

args=(handoff-intake --root "$TARGET_DIR")
if [[ "$MODE" == "latest" ]]; then
    args+=(--latest)
elif [[ "$MODE" == "files" ]]; then
    args+=(--files)
fi
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    args+=(--json)
fi

python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}"
