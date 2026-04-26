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
DATE_STAMP="$(date +%Y%m%d)"
REPORT_DIR="$ROOT_DIR/reports"
REPORT_PATH="$REPORT_DIR/smoke_instance_${STAMP}.md"
STEP_INDEX=0
OVERALL_STATUS=0
HANDOFF_REL="project/output/handoff/P1_smoke_handoff_${DATE_STAMP}.md"
HANDOFF_INDEX_VERIFIED=false
HANDOFF_EVENT_VERIFIED=false
HANDOFF_INTAKE_PROBE_VERIFIED=false
JSON_QUERY_REGRESSION_VERIFIED=false
JSON_STDOUT_FILE=""
JSON_STDERR_FILE=""

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

write_minimal_handoff() {
    cat > "$TARGET_DIR/$HANDOFF_REL" <<EOF
# P1 Smoke Handoff

## Problem
- P1 smoke validation for the submit_handoff workflow entrypoint.

## Inputs
- MEMORY.md and project/runtime files are rendered from scaffold for this temporary instance.
- No competition dataset is required for this host-only smoke artifact.

## Method
- Created a deterministic handoff artifact to exercise validation, indexing, and event emission.
- Verified the handoff submit contract without starting Docker or running codex exec.

## Outputs
- $HANDOFF_REL records the smoke handoff content.
- project/runtime/event_log.jsonl should contain a handoff_submitted event.

## For Paper Brain
- Paper brain should treat this as smoke evidence for workflow mechanics only.
- Indexed handoffs in MEMORY.md are the consumable handoff list.

## Risks
- This synthetic handoff is not a modeling result.
- No paper claim should cite this smoke artifact as problem evidence.
EOF
}

check_handoff_index() {
    grep -F "latest: $HANDOFF_REL" "$TARGET_DIR/MEMORY.md" >/dev/null
    grep -F "  - $HANDOFF_REL" "$TARGET_DIR/MEMORY.md" >/dev/null
    HANDOFF_INDEX_VERIFIED=true
}

check_handoff_event() {
    grep -F '"event_type": "handoff_submitted"' "$TARGET_DIR/project/runtime/event_log.jsonl" >/dev/null
    grep -F "\"handoff\": \"$HANDOFF_REL\"" "$TARGET_DIR/project/runtime/event_log.jsonl" >/dev/null
    HANDOFF_EVENT_VERIFIED=true
}

prepare_handoff_intake_probe() {
    HANDOFF_INTAKE_PROBE_DIR="$(mktemp -d "$TARGET_DIR/intake_probe.XXXXXX")"
    HANDOFF_INTAKE_PROBE_INDEXED_REL="project/output/handoff/P1_intake_indexed_${DATE_STAMP}.md"
    HANDOFF_INTAKE_PROBE_UNINDEXED_REL="project/output/handoff/P2_intake_unindexed_${DATE_STAMP}.md"

    bash "$SCRIPT_DIR/setup.sh" "$COMPETITION_NAME_ARG" --render-only --target "$HANDOFF_INTAKE_PROBE_DIR" >/dev/null

    python3 - "$HANDOFF_INTAKE_PROBE_DIR" "$HANDOFF_INTAKE_PROBE_INDEXED_REL" "$HANDOFF_INTAKE_PROBE_UNINDEXED_REL" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
indexed_rel = sys.argv[2]
unindexed_rel = sys.argv[3]

body = """# Intake Probe Handoff

## Problem
- indexed handoff intake probe

## Inputs
- canonical inputs: synthetic probe state
- supporting files: MEMORY.md and project/output/handoff/

## Method
- model / script: host-only smoke probe
- what was actually validated: default intake, shortcut output, missing-indexed failure

## Outputs
- figures: none
- tables: stdout and stderr captures
- csv: none

## For Paper Brain
- key claims: indexed handoffs are consumable; unindexed valid handoffs warn only
- variable definitions: latest means the MEMORY.md Handoff Index latest entry
- wording boundaries / caveats: this is a synthetic workflow probe, not a modeling result

## Risks
- assumption risk: probe content is synthetic but contract-valid
- sensitivity risk: none
"""

(root / indexed_rel).write_text(body, encoding="utf-8")
(root / unindexed_rel).write_text(body, encoding="utf-8")

memory_path = root / "MEMORY.md"
lines = memory_path.read_text(encoding="utf-8").splitlines()
start = lines.index("## Handoff Index")
end = len(lines)
for index in range(start + 1, len(lines)):
    if lines[index].startswith("## "):
        end = index
        break

replacement = [
    "## Handoff Index",
    f"- latest: {indexed_rel}",
    "- files:",
    f"  - {indexed_rel}",
]
memory_path.write_text("\n".join(lines[:start] + replacement + lines[end:]).rstrip() + "\n", encoding="utf-8")
PY

    echo "probe_dir: $HANDOFF_INTAKE_PROBE_DIR"
    echo "indexed_rel: $HANDOFF_INTAKE_PROBE_INDEXED_REL"
    echo "unindexed_rel: $HANDOFF_INTAKE_PROBE_UNINDEXED_REL"
}

check_handoff_intake_default_probe() {
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"

    bash "$SCRIPT_DIR/check_handoff_intake.sh" --target "$HANDOFF_INTAKE_PROBE_DIR" >"$stdout_file" 2>"$stderr_file"

    grep -Fx "[workflow] indexed latest: $HANDOFF_INTAKE_PROBE_INDEXED_REL" "$stdout_file" >/dev/null
    grep -Fx "[workflow] indexed files:" "$stdout_file" >/dev/null
    grep -Fx -- "- $HANDOFF_INTAKE_PROBE_INDEXED_REL" "$stdout_file" >/dev/null
    grep -Fx "[workflow] warnings:" "$stdout_file" >/dev/null
    grep -F "unindexed handoff ignored by default intake: $HANDOFF_INTAKE_PROBE_UNINDEXED_REL" "$stdout_file" >/dev/null
    [[ ! -s "$stderr_file" ]]

    echo "[probe] default_report_stdout:"
    cat "$stdout_file"
    echo "[probe] default_report_stderr: <empty>"

    rm -f "$stdout_file" "$stderr_file"
}

check_handoff_intake_shortcut_probe() {
    local mode="$1"
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"

    local args=()
    if [[ "$mode" == "latest" ]]; then
        args+=(--latest)
    else
        args+=(--files)
    fi

    bash "$SCRIPT_DIR/check_handoff_intake.sh" "${args[@]}" --target "$HANDOFF_INTAKE_PROBE_DIR" >"$stdout_file" 2>"$stderr_file"

    grep -Fx "$HANDOFF_INTAKE_PROBE_INDEXED_REL" "$stdout_file" >/dev/null
    [[ "$(wc -l < "$stdout_file")" -eq 1 ]]
    grep -F "unindexed handoff ignored by default intake: $HANDOFF_INTAKE_PROBE_UNINDEXED_REL" "$stderr_file" >/dev/null

    echo "[probe] ${mode}_stdout:"
    cat "$stdout_file"
    echo "[probe] ${mode}_stderr:"
    cat "$stderr_file"

    rm -f "$stdout_file" "$stderr_file"
}

check_handoff_intake_missing_indexed_failure() {
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"

    rm -f "$HANDOFF_INTAKE_PROBE_DIR/$HANDOFF_INTAKE_PROBE_INDEXED_REL"

    set +e
    bash "$SCRIPT_DIR/check_handoff_intake.sh" --target "$HANDOFF_INTAKE_PROBE_DIR" >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    set -e

    [[ "$exit_code" -ne 0 ]]
    [[ ! -s "$stdout_file" ]]
    grep -F "missing file:" "$stderr_file" >/dev/null
    grep -F "$HANDOFF_INTAKE_PROBE_INDEXED_REL" "$stderr_file" >/dev/null

    echo "[probe] missing_indexed_exit_code: $exit_code"
    echo "[probe] missing_indexed_stdout: <empty>"
    echo "[probe] missing_indexed_stderr:"
    cat "$stderr_file"

    rm -f "$stdout_file" "$stderr_file"
    HANDOFF_INTAKE_PROBE_VERIFIED=true
}

check_handoff_intake_shortcut_json_rejection() {
    local mode="$1"
    local stdout_file stderr_file exit_code command_text
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"

    local args=()
    if [[ "$mode" == "latest" ]]; then
        args+=(--latest --json)
    else
        args+=(--files --json)
    fi

    command_text="$(quote_command bash "$SCRIPT_DIR/check_handoff_intake.sh" "${args[@]}" --target "$HANDOFF_INTAKE_PROBE_DIR")"
    set +e
    bash "$SCRIPT_DIR/check_handoff_intake.sh" "${args[@]}" --target "$HANDOFF_INTAKE_PROBE_DIR" >"$stdout_file" 2>"$stderr_file"
    exit_code=$?
    set -e

    [[ "$exit_code" -eq 2 ]]
    [[ ! -s "$stdout_file" ]]
    grep -F "cannot be combined with --latest or --files" "$stderr_file" >/dev/null

    echo "[probe] command: $command_text"
    echo "[probe] exit_code: $exit_code"
    echo "[probe] result: PASS"
    echo "[probe] stdout: <empty>"
    echo "[probe] stderr:"
    cat "$stderr_file"

    rm -f "$stdout_file" "$stderr_file"
}

cleanup_json_probe_capture() {
    rm -f "${JSON_STDOUT_FILE:-}" "${JSON_STDERR_FILE:-}"
    JSON_STDOUT_FILE=""
    JSON_STDERR_FILE=""
}

summarize_json_payload() {
    local payload_file="$1"
    python3 - "$payload_file" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
keys = ",".join(sorted(payload)[:12])
print(
    "[probe] stdout_json_summary: "
    f"schema_version={payload.get('schema_version', '')} "
    f"status={payload.get('status', '')} "
    f"read_only={payload.get('read_only', '<missing>')} "
    f"keys={keys}"
)
PY
}

run_json_probe_keep() {
    local label="$1"
    shift
    local stdout_file stderr_file json_error_file command_text exit_code summary
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    json_error_file="$(mktemp)"
    command_text="$(quote_command "$@")"

    set +e
    "$@" >"$stdout_file" 2>"$stderr_file"
    exit_code=$?
    set -e

    echo "[probe] label: $label"
    echo "[probe] command: $command_text"
    echo "[probe] exit_code: $exit_code"

    if [[ "$exit_code" -ne 0 ]]; then
        echo "[probe] result: FAIL"
        echo "[probe] stderr:"
        cat "$stderr_file"
        rm -f "$json_error_file"
        JSON_STDOUT_FILE="$stdout_file"
        JSON_STDERR_FILE="$stderr_file"
        return 1
    fi
    if ! python3 -m json.tool <"$stdout_file" >/dev/null 2>"$json_error_file"; then
        echo "[probe] result: FAIL"
        echo "[probe] json_tool_stderr:"
        cat "$json_error_file"
        rm -f "$json_error_file"
        JSON_STDOUT_FILE="$stdout_file"
        JSON_STDERR_FILE="$stderr_file"
        return 1
    fi
    if ! summary="$(summarize_json_payload "$stdout_file")"; then
        echo "[probe] result: FAIL"
        rm -f "$json_error_file"
        JSON_STDOUT_FILE="$stdout_file"
        JSON_STDERR_FILE="$stderr_file"
        return 1
    fi

    echo "[probe] result: PASS"
    echo "$summary"
    if [[ -s "$stderr_file" ]]; then
        echo "[probe] stderr_summary:"
        tail -n 20 "$stderr_file"
    else
        echo "[probe] stderr: <empty>"
    fi

    rm -f "$json_error_file"
    JSON_STDOUT_FILE="$stdout_file"
    JSON_STDERR_FILE="$stderr_file"
}

assert_handoff_intake_json_payload() {
    local indexed_rel="$1"
    local unindexed_rel="$2"
    python3 - "$JSON_STDOUT_FILE" "$indexed_rel" "$unindexed_rel" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
indexed_rel = sys.argv[2]
unindexed_rel = sys.argv[3]
indexed_files = payload.get("indexed_files", [])
warnings = payload.get("warnings", [])

assert payload.get("read_only") is True
assert payload.get("indexed_latest") == indexed_rel
assert indexed_rel in indexed_files
assert unindexed_rel not in indexed_files
assert any(unindexed_rel in warning for warning in warnings)
print(
    "[probe] handoff_intake_json_semantics: "
    f"indexed_files={len(indexed_files)} warnings={len(warnings)} unindexed_only_warning=true"
)
PY
}

assert_adjudication_json_payload() {
    local output_rel="$1"
    python3 - "$JSON_STDOUT_FILE" "$TARGET_DIR" "$output_rel" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2])
output_rel = sys.argv[3]
artifact = payload.get("artifact_written", {})

assert payload.get("read_only") is False
assert artifact.get("path") == output_rel
assert (root / output_rel).is_file()
print(f"[probe] adjudication_json_semantics: artifact_written={output_rel} read_only=false")
PY
}

check_json_query_regression() {
    run_json_probe_keep "doctor_json_flag" bash "$SCRIPT_DIR/doctor.sh" --target "$TARGET_DIR" --json || return 1
    cleanup_json_probe_capture
    run_json_probe_keep "doctor_format_json" bash "$SCRIPT_DIR/doctor.sh" --target "$TARGET_DIR" --format json || return 1
    cleanup_json_probe_capture

    run_json_probe_keep "check_state_consistency_json_flag" bash "$SCRIPT_DIR/check_state_consistency.sh" --target "$TARGET_DIR" --json || return 1
    cleanup_json_probe_capture
    run_json_probe_keep "check_state_consistency_format_json" bash "$SCRIPT_DIR/check_state_consistency.sh" --target "$TARGET_DIR" --format json || return 1
    cleanup_json_probe_capture

    run_json_probe_keep "main_brain_summary_json_flag" bash "$SCRIPT_DIR/main_brain_summary.sh" --target "$TARGET_DIR" --json || return 1
    cleanup_json_probe_capture
    run_json_probe_keep "main_brain_summary_format_json" bash "$SCRIPT_DIR/main_brain_summary.sh" --target "$TARGET_DIR" --format json || return 1
    cleanup_json_probe_capture

    run_json_probe_keep "show_task_json_flag" bash "$SCRIPT_DIR/show_task.sh" --task TASK_MAIN_SYNC --target "$TARGET_DIR" --json || return 1
    cleanup_json_probe_capture
    run_json_probe_keep "show_task_format_json" bash "$SCRIPT_DIR/show_task.sh" --task TASK_MAIN_SYNC --target "$TARGET_DIR" --format json || return 1
    cleanup_json_probe_capture

    run_json_probe_keep "list_history_json_flag" bash "$SCRIPT_DIR/list_history.sh" --task TASK_MAIN_SYNC --target "$TARGET_DIR" --json || return 1
    cleanup_json_probe_capture
    run_json_probe_keep "list_history_format_json" bash "$SCRIPT_DIR/list_history.sh" --task TASK_MAIN_SYNC --target "$TARGET_DIR" --format json || return 1
    cleanup_json_probe_capture

    run_json_probe_keep "recommend_tasks_json_flag" bash "$SCRIPT_DIR/recommend_tasks.sh" --target "$TARGET_DIR" --json || return 1
    cleanup_json_probe_capture
    run_json_probe_keep "recommend_tasks_format_json" bash "$SCRIPT_DIR/recommend_tasks.sh" --target "$TARGET_DIR" --format json || return 1
    cleanup_json_probe_capture

    run_json_probe_keep "check_handoff_intake_json_flag" bash "$SCRIPT_DIR/check_handoff_intake.sh" --target "$HANDOFF_INTAKE_PROBE_DIR" --json || return 1
    assert_handoff_intake_json_payload "$HANDOFF_INTAKE_PROBE_INDEXED_REL" "$HANDOFF_INTAKE_PROBE_UNINDEXED_REL" || return 1
    cleanup_json_probe_capture
    run_json_probe_keep "check_handoff_intake_format_json" bash "$SCRIPT_DIR/check_handoff_intake.sh" --target "$HANDOFF_INTAKE_PROBE_DIR" --format json || return 1
    assert_handoff_intake_json_payload "$HANDOFF_INTAKE_PROBE_INDEXED_REL" "$HANDOFF_INTAKE_PROBE_UNINDEXED_REL" || return 1
    cleanup_json_probe_capture

    local adjudication_json_rel="project/output/review/TASK_MAIN_SYNC_adjudication_json_flag.md"
    run_json_probe_keep "adjudicate_task_json_flag" bash "$SCRIPT_DIR/adjudicate_task.sh" --task TASK_MAIN_SYNC --target "$TARGET_DIR" --output "$adjudication_json_rel" --note "smoke json flag regression" --json || return 1
    assert_adjudication_json_payload "$adjudication_json_rel" || return 1
    cleanup_json_probe_capture

    local adjudication_format_rel="project/output/review/TASK_MAIN_SYNC_adjudication_format_json.md"
    run_json_probe_keep "adjudicate_task_format_json" bash "$SCRIPT_DIR/adjudicate_task.sh" --task TASK_MAIN_SYNC --target "$TARGET_DIR" --output "$adjudication_format_rel" --note "smoke format json regression" --format json || return 1
    assert_adjudication_json_payload "$adjudication_format_rel" || return 1
    cleanup_json_probe_capture

    JSON_QUERY_REGRESSION_VERIFIED=true
}

finish_report() {
    local ready_count="unavailable"
    local policy_hints_generated="false"
    local reset_validate_passed="false"
    local handoff_index_updated="false"
    local handoff_event_recorded="false"
    if [[ -f "$TARGET_DIR/project/runtime/task_registry.json" ]]; then
        ready_count="$(ready_task_count 2>/dev/null || echo unavailable)"
    fi
    if [[ -f "$TARGET_DIR/project/output/review/policy_hints_candidate.md" ]]; then
        policy_hints_generated="true"
    fi
    if grep -q "reset_validate_after" "$REPORT_PATH" && grep -A4 "reset_validate_after" "$REPORT_PATH" | grep -q "result: PASS"; then
        reset_validate_passed="true"
    fi
    if [[ "$HANDOFF_INDEX_VERIFIED" == true ]]; then
        handoff_index_updated="true"
    fi
    if [[ "$HANDOFF_EVENT_VERIFIED" == true ]]; then
        handoff_event_recorded="true"
    fi
    {
        echo "## Key Observations"
        echo ""
        echo "- ready_task_count_current: $ready_count"
        echo "- policy_hints_generated: $policy_hints_generated"
        echo "- handoff_index_updated: $handoff_index_updated"
        echo "- handoff_event_recorded: $handoff_event_recorded"
        echo "- handoff_intake_probe_verified: $HANDOFF_INTAKE_PROBE_VERIFIED"
        echo "- json_query_regression_verified: $JSON_QUERY_REGRESSION_VERIFIED"
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
run_required "write_minimal_handoff" write_minimal_handoff
run_required "submit_handoff" bash "$SCRIPT_DIR/submit_handoff.sh" --task TASK_CODE_MODEL_SLOT --handoff "$TARGET_DIR/$HANDOFF_REL" --target "$TARGET_DIR" --actor smoke_instance
run_required "handoff_validate_after_submit" bash "$SCRIPT_DIR/validate_agent_docs.sh" --root "$TARGET_DIR"
run_required "handoff_consistency_after_submit" bash "$SCRIPT_DIR/check_state_consistency.sh" --target "$TARGET_DIR"
run_required "handoff_memory_index_check" check_handoff_index
run_required "handoff_event_check" check_handoff_event
run_required "handoff_intake_probe_setup" prepare_handoff_intake_probe
run_required "handoff_intake_default_report" check_handoff_intake_default_probe
run_required "handoff_intake_latest_shortcut" check_handoff_intake_shortcut_probe latest
run_required "handoff_intake_files_shortcut" check_handoff_intake_shortcut_probe files
run_required "handoff_intake_latest_json_rejected" check_handoff_intake_shortcut_json_rejection latest
run_required "handoff_intake_files_json_rejected" check_handoff_intake_shortcut_json_rejection files
run_required "json_query_regression" check_json_query_regression
run_required "handoff_intake_missing_indexed_failure" check_handoff_intake_missing_indexed_failure
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
