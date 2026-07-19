#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
ACTOR=""
BACKEND=""
RESULT=""
NOTE=""
ARTIFACT_ARGS=()
POOL_WORKER=""
SESSION_ID=""
MODEL=""
PROVIDER=""
DURATION_SECONDS=""

usage() {
    echo "Usage: bash scripts/record_worker_result.sh --task <id> --actor <name> --backend <relay|codex_exec|subagent|human> --result <started|completed|failed|partial> [--pool-worker <key> --session-id <id>] [--model <name>] [--provider <name>] [--duration-seconds <n>] [--artifact <path>]... [--note <text>] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK_ID="$2"; shift 2 ;;
        --actor) ACTOR="$2"; shift 2 ;;
        --backend) BACKEND="$2"; shift 2 ;;
        --result) RESULT="$2"; shift 2 ;;
        --artifact) ARTIFACT_ARGS+=(--artifact "$2"); shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --pool-worker) POOL_WORKER="$2"; shift 2 ;;
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --provider) PROVIDER="$2"; shift 2 ;;
        --duration-seconds) DURATION_SECONDS="$2"; shift 2 ;;
        --target|--root) TARGET_DIR="$(abs_path "$2")"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

[[ -n "$TASK_ID" && -n "$ACTOR" && -n "$BACKEND" && -n "$RESULT" ]] || { usage; exit 2; }
case "$BACKEND" in relay|codex_exec|subagent|human) ;; *) die "invalid backend: $BACKEND" ;; esac
case "$RESULT" in started|completed|failed|partial) ;; *) die "invalid result: $RESULT" ;; esac
if [[ -n "$POOL_WORKER" || -n "$SESSION_ID" ]]; then
    [[ -n "$POOL_WORKER" && -n "$SESSION_ID" ]] || die "--pool-worker and --session-id must be provided together"
fi

OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
STATUS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" status)"
CYCLE_ID="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" cycle_id)"
metadata_args=(--metadata "backend=$BACKEND")
[[ -n "$CYCLE_ID" ]] && metadata_args+=(--metadata "cycle_id=$CYCLE_ID")
[[ -n "$POOL_WORKER" ]] && metadata_args+=(--metadata "pool_worker_key=$POOL_WORKER" --metadata "session_id=$SESSION_ID")
[[ -n "$MODEL" ]] && metadata_args+=(--metadata "model=$MODEL")
[[ -n "$PROVIDER" ]] && metadata_args+=(--metadata "provider=$PROVIDER")
[[ -n "$DURATION_SECONDS" ]] && metadata_args+=(--metadata "duration_seconds=$DURATION_SECONDS")

emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" \
    --event-type "worker.$RESULT" \
    --task "$TASK_ID" \
    --actor "$ACTOR" \
    --owner "$OWNER" \
    --from-status "$STATUS" \
    --to-status "$STATUS" \
    "${metadata_args[@]}" \
    "${ARTIFACT_ARGS[@]}" \
    --note "$NOTE"

if [[ -n "$POOL_WORKER" && "$RESULT" != "started" ]]; then
    bash "$SCRIPT_DIR/worker_pool.sh" mark-idle \
        --worker-key "$POOL_WORKER" \
        --task "$TASK_ID" \
        --actor "$ACTOR" \
        --target "$TARGET_DIR" >/dev/null
fi
