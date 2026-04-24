#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

COMPETITION_NAME_ARG="smokecontest"
TARGET_DIR=""
TARGET_PROVIDED=false
KEEP_TEMP=false
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="$ROOT_DIR/reports"
REPORT_PATH="$REPORT_DIR/smoke_instance_${STAMP}.md"
STEP_INDEX=0
OVERALL_STATUS=0

usage() {
    cat <<'EOF'
Usage: bash scripts/smoke_instance.sh [options]

Options:
  --competition <name>  Competition name used for render-only setup. Default: smokecontest
  --target <dir>        Use an explicit rendered instance directory.
  --keep-temp           Keep the temporary rendered instance on success.
  -h, --help            Show this help.

Default path is low risk: no Docker and no codex exec.
EOF
}

quote_command() {
    local out="" quoted
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        out+="$quoted "
    done
    printf '%s' "${out% }"
}

append_report_header() {
    mkdir -p "$REPORT_DIR"
    cat > "$REPORT_PATH" <<EOF
# smoke_instance report

- test_time: $(date '+%Y-%m-%d %H:%M:%S %z')
- template_root: $ROOT_DIR
- rendered_instance: $TARGET_DIR
- competition: $COMPETITION_NAME_ARG
- keep_temp: $KEEP_TEMP
- target_provided: $TARGET_PROVIDED
- docker_enabled: false
- exec_enabled: false

## Steps

EOF
}

append_step_result() {
    local label="$1"
    local command_text="$2"
    local exit_code="$3"
    local output_file="$4"
    local result="PASS"
    [[ "$exit_code" -eq 0 ]] || result="FAIL"
    {
        echo "### ${STEP_INDEX}. ${label}"
        echo ""
        echo "- command: \`$command_text\`"
        echo "- exit_code: $exit_code"
        echo "- result: $result"
        echo ""
        echo '```text'
        tail -n 80 "$output_file" || true
        echo '```'
        echo ""
    } >> "$REPORT_PATH"
}

run_step() {
    local label="$1"
    shift
    STEP_INDEX=$((STEP_INDEX + 1))
    local output_file
    output_file="$(mktemp)"
    local command_text
    command_text="$(quote_command "$@")"
    set +e
    "$@" > "$output_file" 2>&1
    local exit_code=$?
    set -e
    append_step_result "$label" "$command_text" "$exit_code" "$output_file"
    rm -f "$output_file"
    return "$exit_code"
}

run_required() {
    set +e
    run_step "$@"
    local exit_code=$?
    set -e
    if [[ "$exit_code" -ne 0 ]]; then
        OVERALL_STATUS="$exit_code"
        finish_report
        echo "[smoke_instance] FAIL"
        echo "report: $REPORT_PATH"
        echo "rendered_instance: $TARGET_DIR"
        exit "$exit_code"
    fi
}

ready_task_count() {
    python3 - "$TARGET_DIR/project/runtime/task_registry.json" <<'PY'
import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(sum(1 for task in payload.get("tasks", []) if task.get("status") == "ready"))
PY
}

write_minimal_feedback() {
    local feedback_rel
    feedback_rel="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" TASK_REVIEW_CONSISTENCY feedback_path)"
    cat > "$TARGET_DIR/$feedback_rel" <<EOF
# Worker Feedback Template

Filename suggestion: \`YYYYMMDD_HHMM_role_topic.md\`

All body sections from \`Task ID\` through \`What Main Brain Should Have Told Me Earlier\` must contain concrete non-empty content before this feedback can pass the gate. A blank bullet, bare \`-\`, or low-signal value like \`none\`, \`n/a\`, \`no\`, \`empty\`, or \`no meaningful change\` is not valid body content.

## Task ID
- TASK_REVIEW_CONSISTENCY

## Role
- review_worker

## Files Changed
- $feedback_rel

## Work Done
- Filled minimum valid feedback content for smoke_instance.

## Verified Facts
- Render-only instance smoke reached dispatch and feedback gate.

## Validation Or Acceptance
- command: bash scripts/check_worker_feedback.sh --task TASK_REVIEW_CONSISTENCY --target $TARGET_DIR
- result: pending smoke gate check

## Remaining Risks
- This is a generated temporary smoke artifact only.

## Lesson Learned
- Phase 1 gates require concrete feedback body content.

## What Main Brain Should Have Told Me Earlier
- smoke_instance intentionally fills only the minimum valid feedback body.

These fields below are candidate policy hints only. They may stay at their default \`none\` / \`no\` values, do not become rules automatically, and must be reviewed by the main brain before any contract or prompt update.

## Failure Cause
- none

## Missing Context
- none

## Suggested Rule
- none

## Suggested Contract Update
- none

## Reusable Lesson
- none

## Should Promote To Contract
- no
EOF
}

finish_report() {
    local ready_count="unavailable"
    local policy_hints_generated="false"
    local reset_validate_passed="false"
    if [[ -f "$TARGET_DIR/project/runtime/task_registry.json" ]]; then
        ready_count="$(ready_task_count 2>/dev/null || echo unavailable)"
    fi
    if [[ -f "$TARGET_DIR/project/output/review/policy_hints_candidate.md" ]]; then
        policy_hints_generated="true"
    fi
    if grep -q "reset_validate_after" "$REPORT_PATH" && grep -A4 "reset_validate_after" "$REPORT_PATH" | grep -q "result: PASS"; then
        reset_validate_passed="true"
    fi
    {
        echo "## Key Observations"
        echo ""
        echo "- ready_task_count_current: $ready_count"
        echo "- policy_hints_generated: $policy_hints_generated"
        echo "- reset_after_validate_passed: $reset_validate_passed"
        echo "- kept_temp_dir: $([[ "$KEEP_TEMP" == true || "$TARGET_PROVIDED" == true || "$OVERALL_STATUS" -ne 0 ]] && echo true || echo false)"
        echo "- overall_status: $([[ "$OVERALL_STATUS" -eq 0 ]] && echo PASS || echo FAIL)"
        echo ""
    } >> "$REPORT_PATH"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --competition)
            COMPETITION_NAME_ARG="$2"
            shift 2
            ;;
        --target)
            TARGET_DIR="$(abs_path "$2")"
            TARGET_PROVIDED=true
            shift 2
            ;;
        --keep-temp)
            KEEP_TEMP=true
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

if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="$(mktemp -d)"
else
    mkdir -p "$TARGET_DIR"
fi

append_report_header

run_required "template_source_validate" bash "$SCRIPT_DIR/validate_agent_docs.sh" --template-source-only
run_required "render_only" bash "$SCRIPT_DIR/setup.sh" "$COMPETITION_NAME_ARG" --render-only --target "$TARGET_DIR"
run_required "rendered_validate_all" bash "$SCRIPT_DIR/validate_agent_docs.sh" --root "$TARGET_DIR"
run_required "doctor" bash "$SCRIPT_DIR/doctor.sh" --root "$TARGET_DIR"
run_required "main_brain_summary" bash "$SCRIPT_DIR/main_brain_summary.sh" --target "$TARGET_DIR"
run_required "list_open_tasks" bash "$SCRIPT_DIR/list_open_tasks.sh" --open-only --target "$TARGET_DIR"
run_required "recommend_tasks" bash "$SCRIPT_DIR/recommend_tasks.sh" --target "$TARGET_DIR"
run_required "make_task_packet" bash "$SCRIPT_DIR/make_task_packet.sh" --task TASK_REVIEW_CONSISTENCY --target "$TARGET_DIR"
run_required "dispatch_task" bash "$SCRIPT_DIR/dispatch_task.sh" --task TASK_REVIEW_CONSISTENCY --owner smoke_review --target "$TARGET_DIR"
run_required "fill_minimal_feedback" write_minimal_feedback
run_required "check_worker_feedback" bash "$SCRIPT_DIR/check_worker_feedback.sh" --task TASK_REVIEW_CONSISTENCY --target "$TARGET_DIR"
run_required "close_task_review" bash "$SCRIPT_DIR/close_task.sh" --task TASK_REVIEW_CONSISTENCY --to review --target "$TARGET_DIR"
run_required "check_state_consistency" bash "$SCRIPT_DIR/check_state_consistency.sh" --target "$TARGET_DIR"
run_required "extract_policy_hints" bash "$SCRIPT_DIR/extract_policy_hints.sh" --target "$TARGET_DIR"
run_required "paper_print_config" bash "$SCRIPT_DIR/paper.sh" --target "$TARGET_DIR" print-config
run_required "reset_state" bash "$SCRIPT_DIR/reset_state.sh" --target "$TARGET_DIR"
run_required "reset_validate_after" bash "$SCRIPT_DIR/validate_agent_docs.sh" --root "$TARGET_DIR"

finish_report

if [[ "$KEEP_TEMP" == false && "$TARGET_PROVIDED" == false ]]; then
    rm -rf "$TARGET_DIR"
fi

echo "[smoke_instance] OK"
echo "report: $REPORT_PATH"
echo "rendered_instance: $TARGET_DIR"
