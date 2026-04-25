#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
FEEDBACK_ONLY=false
WITH_RETROSPECTIVE=false

usage() {
    echo "Usage: bash scripts/submit_feedback.sh --task <task_id> [--feedback-only | --with-retrospective] [--target <dir>]" >&2
    echo "Helper semantics: repair missing feedback skeletons, initialize retrospective files, or backfill artifacts after the canonical dispatch path." >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --feedback-only)
            FEEDBACK_ONLY=true
            shift
            ;;
        --with-retrospective)
            WITH_RETROSPECTIVE=true
            shift
            ;;
        --target)
            TARGET_DIR="$(abs_path "$2")"
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

args=(init-feedback --root "$TARGET_DIR" --task "$TASK_ID")
if [[ "$WITH_RETROSPECTIVE" == true ]]; then
    args+=(--with-retrospective)
elif [[ "$FEEDBACK_ONLY" == true ]]; then
    args+=(--feedback-only)
fi

main() {
    output="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" "${args[@]}")"
    printf '%s\n' "$output"

    OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
    feedback_path="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" feedback_path)"
    retro_path="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" retrospective_path)"

    event_args=(
        --event-type feedback.initialized
        --task "$TASK_ID"
        --actor main_brain
        --owner "$OWNER"
        --artifact "$feedback_path"
        --metadata "with_retrospective=$WITH_RETROSPECTIVE"
    )
    if [[ "$WITH_RETROSPECTIVE" == true ]]; then
        event_args+=(--artifact "$retro_path")
    fi
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${event_args[@]}" >/dev/null
    workflow_post_change_consistency "$SCRIPT_DIR" "$TARGET_DIR"
}

workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" main
