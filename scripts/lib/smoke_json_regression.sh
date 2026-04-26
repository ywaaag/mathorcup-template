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
