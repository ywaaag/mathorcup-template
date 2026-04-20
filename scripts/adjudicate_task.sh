#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
INPUTS=""
MODE="compare"
OUTPUT=""
DECISION="manual"
NOTE=""

usage() {
    cat <<'EOF' >&2
Usage: bash scripts/adjudicate_task.sh --task <task_id> [options]

Options:
  --inputs <path1,path2,...>
  --mode <compare|summarize|choose>
  --output <path>
  --decision <close_review|reopen|cancel|manual>
  --note <text>
  --target <dir>
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --inputs)
            INPUTS="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --decision)
            DECISION="$2"
            shift 2
            ;;
        --note)
            NOTE="$2"
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
    adjudicate \
    --root "$TARGET_DIR" \
    --task "$TASK_ID" \
    --inputs "$INPUTS" \
    --mode "$MODE" \
    --output "$OUTPUT" \
    --decision "$DECISION" \
    --note "$NOTE"
