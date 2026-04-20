#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
EVENT_ID=""
REPLAY_FROM=""
LATEST=false
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: bash scripts/process_callbacks.sh [--target <dir>] [--event-id <id> | --latest | --replay-from <id>] [--dry-run]

Processes callback_hooks.yaml against one emitted event or a replay range. This is a foreground command, not a daemon.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --event-id)
            EVENT_ID="$2"
            shift 2
            ;;
        --latest)
            LATEST=true
            shift
            ;;
        --replay-from)
            REPLAY_FROM="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
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

selection_count=0
[[ -n "$EVENT_ID" ]] && selection_count=$((selection_count + 1))
[[ -n "$REPLAY_FROM" ]] && selection_count=$((selection_count + 1))
[[ "$LATEST" == true ]] && selection_count=$((selection_count + 1))
if [[ $selection_count -gt 1 ]]; then
    die "use only one of --event-id, --latest, or --replay-from"
fi
if [[ $selection_count -eq 0 ]]; then
    LATEST=true
fi

args=(process --root "$TARGET_DIR")
[[ -n "$EVENT_ID" ]] && args+=(--event-id "$EVENT_ID")
[[ -n "$REPLAY_FROM" ]] && args+=(--replay-from "$REPLAY_FROM")
[[ "$LATEST" == true ]] && args+=(--latest)
[[ "$DRY_RUN" == true ]] && args+=(--dry-run)

python3 "$SCRIPT_DIR/lib/workflow_events.py" "${args[@]}"
