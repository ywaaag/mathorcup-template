#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
CLEAR_REVIEW=false
CLEAR_RETROSPECTIVES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --clear-review)
            CLEAR_REVIEW=true
            shift
            ;;
        --clear-retrospectives)
            CLEAR_RETROSPECTIVES=true
            shift
            ;;
        -h|--help)
            echo "Usage: bash scripts/reset_state.sh [--target <dir>] [--clear-review] [--clear-retrospectives]"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

status_info "resetting MEMORY.md from scaffold"
bash "$SCRIPT_DIR/render_templates.sh" \
    --target "$TARGET_DIR" \
    --force \
    --include-state \
    --only MEMORY.md.template >/dev/null
status_ok "MEMORY.md reset"

status_info "resetting task registry and queue board from scaffold"
bash "$SCRIPT_DIR/render_templates.sh" \
    --target "$TARGET_DIR" \
    --force \
    --include-state \
    --only project/runtime/task_registry.yaml.template \
    --only project/runtime/work_queue.yaml.template \
    --only project/runtime/event_log.jsonl.template \
    --only project/workflow/MAIN_BRAIN_QUEUE.md.template >/dev/null
bash "$SCRIPT_DIR/render_task_registry.sh" --target "$TARGET_DIR" >/dev/null
status_ok "task registry, event log, and queue board reset"

if [[ -d "$TARGET_DIR/project/output/handoff" ]]; then
    find "$TARGET_DIR/project/output/handoff" -maxdepth 1 -type f -name 'P*.md' -delete
    status_ok "cleared generated handoffs"
fi

if [[ "$CLEAR_REVIEW" == true && -d "$TARGET_DIR/project/output/review" ]]; then
    find "$TARGET_DIR/project/output/review" -maxdepth 1 -type f -name '*.md' ! -name 'WORKER_FEEDBACK_TEMPLATE.md' -delete
    rm -rf "$TARGET_DIR/project/output/review/callback_runs" "$TARGET_DIR/project/output/review/exec_runs"
    status_ok "cleared review notes"
fi

if [[ "$CLEAR_RETROSPECTIVES" == true && -d "$TARGET_DIR/project/output/retrospectives" ]]; then
    find "$TARGET_DIR/project/output/retrospectives" -maxdepth 1 -type f -name '*.md' ! -name 'RETROSPECTIVE_TEMPLATE.md' -delete
    status_ok "cleared retrospectives"
fi
