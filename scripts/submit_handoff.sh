#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
HANDOFF_PATH=""
ACTOR=""
NO_INDEX=false

usage() {
    cat <<'EOF'
Usage: bash scripts/submit_handoff.sh --task <task_id> --handoff <path> [--target <dir>] [--actor <name>] [--no-index]

Validates a code-brain handoff in a rendered instance, updates MEMORY.md -> Handoff Index by default,
and emits a handoff_submitted workflow event. It does not change task status or close tasks.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --handoff)
            HANDOFF_PATH="$2"
            shift 2
            ;;
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --actor)
            ACTOR="$2"
            shift 2
            ;;
        --no-index)
            NO_INDEX=true
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

[[ -n "$TASK_ID" ]] || { usage >&2; exit 2; }
[[ -n "$HANDOFF_PATH" ]] || { usage >&2; exit 2; }

main() {
    args=(submit-handoff --root "$TARGET_DIR" --task "$TASK_ID" --handoff "$HANDOFF_PATH")
    if [[ "$NO_INDEX" == true ]]; then
        args+=(--no-index)
    fi

    output="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}")"
    printf '%s\n' "$output"

    handoff_rel="$(printf '%s\n' "$output" | awk -F': ' '/handoff submitted:/ {print $2; exit}')"
    [[ -n "$handoff_rel" ]] || die "submit_handoff did not report a handoff path"

    OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
    STATUS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" status)"
    EVENT_ACTOR="$ACTOR"
    if [[ -z "$EVENT_ACTOR" ]]; then
        EVENT_ACTOR="${OWNER:-system}"
    fi

    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" \
        --event-type handoff_submitted \
        --task "$TASK_ID" \
        --actor "$EVENT_ACTOR" \
        --owner "$OWNER" \
        --from-status "$STATUS" \
        --to-status "$STATUS" \
        --artifact "$handoff_rel" \
        --metadata "indexed=$([[ "$NO_INDEX" == true ]] && echo false || echo true)" \
        --metadata "handoff=$handoff_rel" >/dev/null

    workflow_post_change_consistency "$SCRIPT_DIR" "$TARGET_DIR"
}

workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" main
