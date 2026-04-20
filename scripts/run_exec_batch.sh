#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASKS_CSV=""
TASKS_FILE=""
OWNERS_CSV=""
OWNER_PREFIX="batch_worker"
MAX_CONCURRENCY=2
WITH_RETROSPECTIVE=false
GOAL=""
MODEL=""
LOCK_SPECS=()

usage() {
    cat <<'EOF'
Usage: bash scripts/run_exec_batch.sh [options]

Options:
  --tasks <task1,task2,...>        Comma-separated task ids
  --tasks-file <path>              File containing one task id per line
  --owners <owner1,owner2,...>     Explicit owner names matching the task list
  --owner-prefix <prefix>          Auto-generate owners like <prefix>_1
  --max-concurrency <n>            Max parallel exec workers. Default: 2
  --with-retrospective             Initialize retrospective skeletons too
  --goal <text>                    Shared scoped goal appended to every worker packet
  --model <model>                  Pass through model to each exec worker
  --lock <task_id:path>            Narrow the claim scope for one task. Repeatable.
  --target <dir>                   Instance root
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tasks)
            TASKS_CSV="$2"
            shift 2
            ;;
        --tasks-file)
            TASKS_FILE="$2"
            shift 2
            ;;
        --owners)
            OWNERS_CSV="$2"
            shift 2
            ;;
        --owner-prefix)
            OWNER_PREFIX="$2"
            shift 2
            ;;
        --max-concurrency)
            MAX_CONCURRENCY="$2"
            shift 2
            ;;
        --with-retrospective)
            WITH_RETROSPECTIVE=true
            shift
            ;;
        --goal)
            GOAL="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --lock)
            LOCK_SPECS+=("$2")
            shift 2
            ;;
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
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

[[ -n "$TASKS_CSV" || -n "$TASKS_FILE" ]] || die "either --tasks or --tasks-file is required"
[[ -z "$TASKS_CSV" || -z "$TASKS_FILE" ]] || die "use only one of --tasks or --tasks-file"
[[ "$MAX_CONCURRENCY" =~ ^[0-9]+$ ]] || die "--max-concurrency must be a positive integer"
(( MAX_CONCURRENCY > 0 )) || die "--max-concurrency must be greater than 0"

declare -a TASKS=()
declare -a OWNERS=()

if [[ -n "$TASKS_CSV" ]]; then
    IFS=',' read -r -a raw_tasks <<< "$TASKS_CSV"
    for task in "${raw_tasks[@]}"; do
        task="${task//[[:space:]]/}"
        [[ -n "$task" ]] && TASKS+=("$task")
    done
else
    [[ -f "$TASKS_FILE" ]] || die "tasks file not found: $TASKS_FILE"
    while IFS= read -r line; do
        task="${line%%#*}"
        task="${task//[[:space:]]/}"
        [[ -n "$task" ]] && TASKS+=("$task")
    done < "$TASKS_FILE"
fi

(( ${#TASKS[@]} > 0 )) || die "no tasks provided"

if [[ -n "$OWNERS_CSV" ]]; then
    IFS=',' read -r -a raw_owners <<< "$OWNERS_CSV"
    for owner in "${raw_owners[@]}"; do
        owner="${owner//[[:space:]]/}"
        [[ -n "$owner" ]] && OWNERS+=("$owner")
    done
    (( ${#OWNERS[@]} == ${#TASKS[@]} )) || die "--owners count must match task count"
else
    for idx in "${!TASKS[@]}"; do
        OWNERS+=("${OWNER_PREFIX}_$((idx + 1))")
    done
fi

batch_stamp="$(date +%Y%m%d_%H%M%S)"
batch_dir="$TARGET_DIR/project/output/review/exec_runs/batch_$batch_stamp"
mkdir -p "$batch_dir"
plan_file="$batch_dir/batch_plan.json"
summary_json="$batch_dir/batch_summary.json"
summary_md="$batch_dir/batch_summary.md"

rel_to_target() {
    python3 - <<'PY' "$TARGET_DIR" "$1"
from pathlib import Path
import sys
print(Path(sys.argv[2]).resolve().relative_to(Path(sys.argv[1]).resolve()).as_posix())
PY
}

batch_check_args=(batch-check --root "$TARGET_DIR")
for task in "${TASKS[@]}"; do
    batch_check_args+=(--task "$task")
done
for lock_spec in "${LOCK_SPECS[@]}"; do
    batch_check_args+=(--lock "$lock_spec")
done
python3 "$SCRIPT_DIR/lib/workflow_state.py" "${batch_check_args[@]}" > "$plan_file"

declare -a PIDS=()
declare -a PID_TASKS=()
declare -a PID_OWNERS=()
declare -a PID_LOGS=()
declare -a PID_LAST_MESSAGES=()
declare -a PID_PACKETS=()
declare -a SUCCESS_TASKS=()
declare -a FAILED_TASKS=()
declare -a FAILED_DETAILS=()

running=0

collect_finished() {
    local idx pid exit_code task owner log_path
    for idx in "${!PIDS[@]}"; do
        pid="${PIDS[$idx]}"
        [[ -z "$pid" ]] && continue
        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        task="${PID_TASKS[$idx]}"
        owner="${PID_OWNERS[$idx]}"
        log_path="${PID_LOGS[$idx]}"
        set +e
        wait "$pid"
        exit_code=$?
        set -e
        if [[ $exit_code -eq 0 ]]; then
            SUCCESS_TASKS+=("$task")
        else
            FAILED_TASKS+=("$task")
            FAILED_DETAILS+=("$task|$owner|$log_path|$exit_code")
        fi
        PIDS[$idx]=""
        running=$((running - 1))
        return 0
    done
    return 1
}

wait_for_slot() {
    while (( running >= MAX_CONCURRENCY )); do
        if ! collect_finished; then
            sleep 1
        fi
    done
}

launch_worker() {
    local task="$1"
    local owner="$2"
    local packet_path="$batch_dir/${task}_packet.md"
    local last_message_path="$batch_dir/${task}_last_message.md"
    local stdout_log="$batch_dir/${task}_stdout.log"
    local args=(
        --task "$task"
        --owner "$owner"
        --target "$TARGET_DIR"
        --packet-out "$packet_path"
        --last-message-out "$last_message_path"
    )
    [[ "$WITH_RETROSPECTIVE" == true ]] && args+=(--with-retrospective)
    [[ -n "$GOAL" ]] && args+=(--goal "$GOAL")
    [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
    for lock_spec in "${LOCK_SPECS[@]}"; do
        [[ "$lock_spec" == "$task:"* ]] || continue
        args+=(--lock "${lock_spec#*:}")
    done

    bash "$SCRIPT_DIR/run_exec_worker.sh" "${args[@]}" > "$stdout_log" 2>&1 &
    PIDS+=("$!")
    PID_TASKS+=("$task")
    PID_OWNERS+=("$owner")
    PID_LOGS+=("$stdout_log")
    PID_LAST_MESSAGES+=("$last_message_path")
    PID_PACKETS+=("$packet_path")
    running=$((running + 1))
}

for idx in "${!TASKS[@]}"; do
    wait_for_slot
    launch_worker "${TASKS[$idx]}" "${OWNERS[$idx]}"
done

while (( running > 0 )); do
    if ! collect_finished; then
        sleep 1
    fi
done

{
    echo "{"
    echo "  \"batch_dir\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$batch_dir"),"
    echo "  \"plan_file\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$plan_file"),"
    echo "  \"successful_tasks\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${SUCCESS_TASKS[@]}"),"
    echo "  \"failed_tasks\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${FAILED_TASKS[@]}")"
    echo "}"
} > "$summary_json"

{
    echo "# Exec Batch Summary"
    echo ""
    echo "- batch_dir: \`$(rel_to_target "$batch_dir")\`"
    echo "- plan_file: \`$(rel_to_target "$plan_file")\`"
    echo "- max_concurrency: \`$MAX_CONCURRENCY\`"
    if [[ -n "$MODEL" ]]; then
        echo "- model: \`$MODEL\`"
    fi
    echo ""
    echo "## Success"
    if (( ${#SUCCESS_TASKS[@]} == 0 )); then
        echo "- none"
    else
        for task in "${SUCCESS_TASKS[@]}"; do
            echo "- \`$task\`"
            echo "  next: \`bash scripts/check_worker_feedback.sh --task $task --target $TARGET_DIR\`"
        done
    fi
    echo ""
    echo "## Failures"
    if (( ${#FAILED_DETAILS[@]} == 0 )); then
        echo "- none"
    else
        for detail in "${FAILED_DETAILS[@]}"; do
            IFS='|' read -r task owner log_path exit_code <<< "$detail"
            rel_log="$(rel_to_target "$log_path")"
            echo "- \`$task\` | owner=\`$owner\` | exit=\`$exit_code\` | log=\`$rel_log\`"
            echo "  next: inspect log, then decide whether to \`cancel_task.sh\` or \`reopen_task.sh\`"
        done
    fi
} > "$summary_md"

echo "[run_exec_batch] batch_dir: $batch_dir"
echo "[run_exec_batch] plan_file: $plan_file"
echo "[run_exec_batch] summary_json: $summary_json"
echo "[run_exec_batch] summary_md: $summary_md"

if (( ${#SUCCESS_TASKS[@]} > 0 )); then
    echo "[run_exec_batch] success: ${SUCCESS_TASKS[*]}"
fi
if (( ${#FAILED_TASKS[@]} > 0 )); then
    echo "[run_exec_batch] failed: ${FAILED_TASKS[*]}"
    exit 1
fi

echo "[run_exec_batch] OK"
