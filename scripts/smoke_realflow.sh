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
    set -e
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
Act as code_brain. Create project/output/realflow_metrics.csv with three sample metric rows. Create project/output/handoff/P0_realflow_smoke_${DATE_STAMP}.md using exactly the six HANDOFF_TEMPLATE headings: Problem, Inputs, Method, Outputs, For Paper Brain, Risks. Update MEMORY.md -> Handoff Index with that handoff. Fill the feedback body content. Fill the retrospective body content. Do not modify project/paper. Do not close the task.
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
