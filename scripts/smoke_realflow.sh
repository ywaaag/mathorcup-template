#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

COMPETITION_NAME_ARG="realflow"
TARGET_DIR=""
TARGET_PROVIDED=false
KEEP_TEMP=false
WITH_DOCKER=false
WITH_EXEC=false
KEEP_CONTAINER=false
STAMP="$(date +%Y%m%d_%H%M%S)"
DATE_STAMP="$(date +%Y%m%d)"
CONTAINER_NAME_ARG="realflow-${STAMP}"
REPORT_DIR="$ROOT_DIR/reports"
REPORT_PATH="$REPORT_DIR/smoke_realflow_${STAMP}.md"
STEP_INDEX=0
OVERALL_STATUS=0
CLEANUP_RESULT="skipped"
PAPER_BUILD_RESULT="skipped"
GATE_RESULT="skipped"
HANDOFF_INTAKE_PROBE_VERIFIED=false
JSON_QUERY_REGRESSION_VERIFIED=false
JSON_STDOUT_FILE=""
JSON_STDERR_FILE=""

usage() {
    cat <<'EOF'
Usage: bash scripts/smoke_realflow.sh [options]

Options:
  --with-docker            Enable bootstrap_container.sh and paper.sh build.
  --with-exec              Enable exec_healthcheck.sh and run_exec_worker.sh. Requires --with-docker.
  --competition <name>     Competition name used for render-only setup. Default: realflow
  --container-name <name>  Container name for this run. Default includes a timestamp.
  --target <dir>           Use an explicit rendered instance directory.
  --keep-temp              Keep the temporary rendered instance on success.
  --keep-container         Keep this run's container after completion.
  -h, --help               Show this help.

Default path is dry/lightweight: no Docker and no codex exec.
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
# smoke_realflow report

- test_time: $(date '+%Y-%m-%d %H:%M:%S %z')
- template_root: $ROOT_DIR
- rendered_instance: $TARGET_DIR
- competition: $COMPETITION_NAME_ARG
- container_name: $CONTAINER_NAME_ARG
- docker_enabled: $WITH_DOCKER
- exec_enabled: $WITH_EXEC
- keep_temp: $KEEP_TEMP
- keep_container: $KEEP_CONTAINER

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
        tail -n 100 "$output_file" || true
        echo '```'
        echo ""
    } >> "$REPORT_PATH"
}

append_skip() {
    local label="$1"
    local reason="$2"
    STEP_INDEX=$((STEP_INDEX + 1))
    {
        echo "### ${STEP_INDEX}. ${label}"
        echo ""
        echo "- command: skipped"
        echo "- exit_code: 0"
        echo "- result: SKIPPED"
        echo "- reason: $reason"
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

cleanup_container_if_needed() {
    if [[ "$WITH_DOCKER" != true || "$KEEP_CONTAINER" == true ]]; then
        CLEANUP_RESULT="skipped"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        CLEANUP_RESULT="failed: docker not found"
        return 1
    fi
    if ! docker ps -a --filter "name=^/${CONTAINER_NAME_ARG}$" --format '{{.Names}}' | grep -Fx "$CONTAINER_NAME_ARG" >/dev/null 2>&1; then
        append_skip "cleanup_container" "container was not present"
        CLEANUP_RESULT="skipped: container not present"
        return 0
    fi
    set +e
    run_step "cleanup_container" docker rm -f "$CONTAINER_NAME_ARG"
    local cleanup_exit=$?
    set -e
    if [[ "$cleanup_exit" -eq 0 ]]; then
        CLEANUP_RESULT="pass"
    else
        CLEANUP_RESULT="fail"
    fi
    return "$cleanup_exit"
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
    local feedback_rel="project/output/review/TASK_CODE_MODEL_SLOT_feedback.md"
    local retro_rel="project/output/retrospectives/TASK_CODE_MODEL_SLOT_retrospective.md"
    local metrics_rel="project/output/realflow_metrics.csv"
    local handoff_rel="project/output/handoff/P0_realflow_smoke_${DATE_STAMP}.md"
    {
        echo "## Worker Artifacts"
        echo ""
        echo "- metrics_csv: $metrics_rel"
        echo "- handoff: $handoff_rel"
        echo "- feedback: $feedback_rel"
        echo "- retrospective: $retro_rel"
        echo ""
        echo "## Results"
        echo ""
        echo "- gate_result: $GATE_RESULT"
        echo "- paper_build_result: $PAPER_BUILD_RESULT"
        echo "- cleanup_result: $CLEANUP_RESULT"
        echo "- handoff_intake_probe_verified: $HANDOFF_INTAKE_PROBE_VERIFIED"
        echo "- json_query_regression_verified: $JSON_QUERY_REGRESSION_VERIFIED"
        echo "- kept_temp_dir: $([[ "$KEEP_TEMP" == true || "$TARGET_PROVIDED" == true || "$OVERALL_STATUS" -ne 0 ]] && echo true || echo false)"
        echo "- overall_status: $([[ "$OVERALL_STATUS" -eq 0 ]] && echo PASS || echo FAIL)"
        echo ""
    } >> "$REPORT_PATH"
}

fail_now() {
    local exit_code="$1"
    OVERALL_STATUS="$exit_code"
    cleanup_container_if_needed || true
    finish_report
    echo "[smoke_realflow] FAIL"
    echo "report: $REPORT_PATH"
    echo "rendered_instance: $TARGET_DIR"
    exit "$exit_code"
}

run_required() {
    set +e
    run_step "$@"
    local exit_code=$?
    set -e
    if [[ "$exit_code" -ne 0 ]]; then
        fail_now "$exit_code"
    fi
}

run_goal_text() {
    cat <<EOF
Act as code_brain. Create project/output/realflow_metrics.csv with three sample metric rows. Create project/output/handoff/P0_realflow_smoke_${DATE_STAMP}.md using exactly the six HANDOFF_TEMPLATE headings: Problem, Inputs, Method, Outputs, For Paper Brain, Risks. Submit that handoff with bash scripts/submit_handoff.sh --task TASK_CODE_MODEL_SLOT --handoff project/output/handoff/P0_realflow_smoke_${DATE_STAMP}.md --target . so MEMORY.md -> Handoff Index and event_log.jsonl are updated by the workflow tool. Fill the feedback body content. Fill the retrospective body content. Do not modify project/paper. Do not close the task.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-docker)
            WITH_DOCKER=true
            shift
            ;;
        --with-exec)
            WITH_EXEC=true
            shift
            ;;
        --competition)
            COMPETITION_NAME_ARG="$2"
            shift 2
            ;;
        --container-name)
            CONTAINER_NAME_ARG="$2"
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
        --keep-container)
            KEEP_CONTAINER=true
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

if [[ "$WITH_EXEC" == true && "$WITH_DOCKER" != true ]]; then
    if [[ -z "$TARGET_DIR" ]]; then
        TARGET_DIR="<not-created>"
    fi
    append_report_header
    append_skip "configuration" "--with-exec requires --with-docker"
    OVERALL_STATUS=2
    finish_report
    echo "[smoke_realflow] FAIL"
    echo "report: $REPORT_PATH"
    exit 2
fi

if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="$(mktemp -d)"
else
    mkdir -p "$TARGET_DIR"
fi

append_report_header

export CONTAINER_NAME="$CONTAINER_NAME_ARG"
run_required "render_only" bash "$SCRIPT_DIR/setup.sh" "$COMPETITION_NAME_ARG" --render-only --target "$TARGET_DIR"
run_required "rendered_validate_all" bash "$SCRIPT_DIR/validate_agent_docs.sh" --root "$TARGET_DIR"
run_required "doctor" bash "$SCRIPT_DIR/doctor.sh" --root "$TARGET_DIR"
run_required "main_brain_summary" bash "$SCRIPT_DIR/main_brain_summary.sh" --target "$TARGET_DIR"
run_required "recommend_tasks" bash "$SCRIPT_DIR/recommend_tasks.sh" --target "$TARGET_DIR"
run_required "check_state_consistency_initial" bash "$SCRIPT_DIR/check_state_consistency.sh" --target "$TARGET_DIR"
run_required "handoff_intake_probe_setup" prepare_handoff_intake_probe
run_required "handoff_intake_default_report" check_handoff_intake_default_probe
run_required "handoff_intake_latest_shortcut" check_handoff_intake_shortcut_probe latest
run_required "handoff_intake_files_shortcut" check_handoff_intake_shortcut_probe files
run_required "handoff_intake_latest_json_rejected" check_handoff_intake_shortcut_json_rejection latest
run_required "handoff_intake_files_json_rejected" check_handoff_intake_shortcut_json_rejection files
run_required "json_query_regression" check_json_query_regression
run_required "handoff_intake_missing_indexed_failure" check_handoff_intake_missing_indexed_failure

if [[ "$WITH_DOCKER" == true ]]; then
    run_required "bootstrap_container" bash "$SCRIPT_DIR/bootstrap_container.sh" --target "$TARGET_DIR"
else
    append_skip "bootstrap_container" "docker_enabled=false"
fi

if [[ "$WITH_EXEC" == true ]]; then
    run_required "exec_healthcheck" bash "$SCRIPT_DIR/exec_healthcheck.sh" --target "$TARGET_DIR"
    run_required "run_exec_worker" bash "$SCRIPT_DIR/run_exec_worker.sh" --task TASK_CODE_MODEL_SLOT --owner realflow_code --target "$TARGET_DIR" --with-retrospective --goal "$(run_goal_text)"
    run_required "check_worker_feedback" bash "$SCRIPT_DIR/check_worker_feedback.sh" --task TASK_CODE_MODEL_SLOT --target "$TARGET_DIR"
    run_required "check_retrospective" bash "$SCRIPT_DIR/check_retrospective.sh" --task TASK_CODE_MODEL_SLOT --target "$TARGET_DIR"
    GATE_RESULT="pass"
    run_required "close_task_review" bash "$SCRIPT_DIR/close_task.sh" --task TASK_CODE_MODEL_SLOT --to review --target "$TARGET_DIR"
else
    append_skip "exec_healthcheck" "exec_enabled=false"
    append_skip "run_exec_worker" "exec_enabled=false"
    append_skip "worker_gates" "exec_enabled=false"
fi

run_required "check_state_consistency_final" bash "$SCRIPT_DIR/check_state_consistency.sh" --target "$TARGET_DIR"

if [[ "$WITH_DOCKER" == true ]]; then
    run_required "paper_build" bash "$SCRIPT_DIR/paper.sh" --target "$TARGET_DIR" build
    PAPER_BUILD_RESULT="pass"
else
    append_skip "paper_build" "docker_enabled=false"
fi

if [[ "$WITH_DOCKER" == true && "$KEEP_CONTAINER" == false ]]; then
    cleanup_container_if_needed || fail_now 1
else
    append_skip "cleanup_container" "$([[ "$WITH_DOCKER" == true ]] && echo keep_container=true || echo docker_enabled=false)"
fi

finish_report

if [[ "$KEEP_TEMP" == false && "$TARGET_PROVIDED" == false ]]; then
    rm -rf "$TARGET_DIR"
fi

echo "[smoke_realflow] OK"
echo "report: $REPORT_PATH"
echo "rendered_instance: $TARGET_DIR"
echo "container_name: $CONTAINER_NAME_ARG"
