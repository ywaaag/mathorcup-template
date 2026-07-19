#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
TASK_ID=""
OWNER=""
ACTOR="main_brain"
PACKET_OUT=""
NO_CLAIM=false
PRINT_ONLY=false
LOCK_ARGS=()
BACKEND="relay"
POOL_WORKER=""
SESSION_ID=""
DELTA_FILE=""
DELTA_FROM=""

usage() {
    echo "Usage: bash scripts/dispatch_task.sh --task <task_id> [--owner <owner>] [--actor <actor>] [--backend <relay|codex_exec|subagent|human>] [--pool-worker <key> --session-id <id>] [--delta-file <path> --delta-from <ref>] [--lock <path>]... [--packet-out <path>] [--print-only] [--no-claim] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK_ID="$2"
            shift 2
            ;;
        --owner)
            OWNER="$2"
            shift 2
            ;;
        --actor)
            ACTOR="$2"
            shift 2
            ;;
        --backend)
            BACKEND="$2"
            case "$BACKEND" in relay|codex_exec|subagent|human) ;; *) die "invalid backend: $BACKEND" ;; esac
            shift 2
            ;;
        --pool-worker)
            POOL_WORKER="$2"
            shift 2
            ;;
        --session-id)
            SESSION_ID="$2"
            shift 2
            ;;
        --delta-file)
            DELTA_FILE="$(abs_path "$2")"
            shift 2
            ;;
        --delta-from)
            DELTA_FROM="$2"
            shift 2
            ;;
        --lock)
            LOCK_ARGS+=(--lock "$2")
            shift 2
            ;;
        --packet-out)
            PACKET_OUT="$2"
            shift 2
            ;;
        --print-only)
            PRINT_ONLY=true
            shift
            ;;
        --no-claim)
            NO_CLAIM=true
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
if [[ "$NO_CLAIM" == false && -z "$OWNER" ]]; then
    echo "--owner is required unless --no-claim is used" >&2
    exit 2
fi
if [[ -n "$POOL_WORKER" || -n "$SESSION_ID" ]]; then
    [[ -n "$POOL_WORKER" && -n "$SESSION_ID" ]] || die "--pool-worker and --session-id must be provided together"
fi
if [[ -n "$DELTA_FILE" ]]; then
    [[ -f "$DELTA_FILE" ]] || die "delta file not found: $DELTA_FILE"
    [[ "$NO_CLAIM" == true ]] || die "--delta-file is only valid with --no-claim on an already active task"
    [[ -n "$POOL_WORKER" ]] || die "--delta-file requires --pool-worker and --session-id"
fi

main() {
    python3 "$SCRIPT_DIR/lib/workflow_state.py" check-task-contract --root "$TARGET_DIR" --task "$TASK_ID" --for-dispatch >/dev/null
    ROLE_NAME="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" role)"
    if [[ -n "$POOL_WORKER" ]]; then
        bash "$SCRIPT_DIR/worker_pool.sh" check-worker \
            --worker-key "$POOL_WORKER" \
            --role "$ROLE_NAME" \
            --task "$TASK_ID" \
            --session-id "$SESSION_ID" \
            --target "$TARGET_DIR" >/dev/null
    fi
    if [[ "$NO_CLAIM" == false ]]; then
        bash "$SCRIPT_DIR/claim_task.sh" \
            --task "$TASK_ID" \
            --owner "$OWNER" \
            --actor "$ACTOR" \
            "${LOCK_ARGS[@]}" \
            --target "$TARGET_DIR"
    fi

    python3 "$SCRIPT_DIR/lib/workflow_state.py" render-queue --root "$TARGET_DIR" >/dev/null
    CURRENT_OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
    CYCLE_ID="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" cycle_id)"
    if [[ -z "$OWNER" ]]; then
        OWNER="$CURRENT_OWNER"
    fi
    if [[ -n "$POOL_WORKER" ]]; then
        bash "$SCRIPT_DIR/worker_pool.sh" assign \
            --worker-key "$POOL_WORKER" \
            --task "$TASK_ID" \
            --session-id "$SESSION_ID" \
            --actor "$ACTOR" \
            --target "$TARGET_DIR" >/dev/null
    fi

    if [[ -n "$DELTA_FILE" ]]; then
        TASK_TITLE="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" title)"
        ALLOWED_PATHS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" allowed_paths)"
        FEEDBACK_PATH="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" feedback_path)"
        DELTA_CONTENT="$(cat "$DELTA_FILE")"
        packet="$(cat <<EOF
你正在复用已有的 $ROLE_NAME worker session。不要重新执行完整仓库 intake；只读取本轮 delta 明确要求的变化和直接依赖。

## Session Routing
- task_id: $TASK_ID
- title: $TASK_TITLE
- cycle_id: $CYCLE_ID
- pool_worker_key: $POOL_WORKER
- worker_session_id: $SESSION_ID
- delta_from: ${DELTA_FROM:-previous accepted worker turn}
- active_owner: ${OWNER:-$CURRENT_OWNER}

## Locked Scope
- allowed_paths: $ALLOWED_PATHS
- feedback_path: $FEEDBACK_PATH
- 不得修改 task registry、work queue、event log 或未授权路径。
- 如果本轮要求改变 canonical numbers、算法边界或顶层 task contract，立即停止并要求主脑升级为完整 dispatch。

## Task Delta
$DELTA_CONTENT

## Return
- 完成本轮 delta 的最小修改与局部验证。
- 将本轮事实追加/合并到现有 feedback，不创建新的顶层 task。
- 返回 changed files、validation、remaining risk；不要自行 close task。
EOF
)"
    else
        packet="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" task-packet --root "$TARGET_DIR" --task "$TASK_ID")"
        if [[ -n "$POOL_WORKER" ]]; then
            packet+=$'\n\n## Worker Session Routing\n'
            packet+="- cycle_id: \`$CYCLE_ID\`"$'\n'
            packet+="- pool_worker_key: \`$POOL_WORKER\`"$'\n'
            packet+="- worker_session_id: \`$SESSION_ID\`"$'\n'
            packet+="- Reuse this worker thread after completion; return to idle instead of closing the session."
        fi
    fi

    if [[ -z "$PACKET_OUT" && "$PRINT_ONLY" == false ]]; then
        stamp="$(date +%Y%m%d_%H%M%S)"
        PACKET_OUT="$TARGET_DIR/project/workflow/packets/${TASK_ID}_${stamp}.md"
    fi

    if [[ -n "$PACKET_OUT" ]]; then
        mkdir -p "$(dirname "$PACKET_OUT")"
        printf '%s' "$packet" > "$PACKET_OUT"
    fi

    dispatch_event_args=(
        --event-type task.dispatched
        --task "$TASK_ID"
        --actor "$ACTOR"
        --owner "$OWNER"
        --from-status in_progress
        --to-status in_progress
        --metadata "role=$ROLE_NAME"
        --metadata "backend=$BACKEND"
        --metadata "cycle_id=$CYCLE_ID"
        --note "task dispatched and packet ready for worker handoff"
    )
    if [[ -n "$POOL_WORKER" ]]; then
        dispatch_event_args+=(--metadata "pool_worker_key=$POOL_WORKER" --metadata "session_id=$SESSION_ID")
    fi
    if [[ -n "$DELTA_FILE" ]]; then
        dispatch_event_args+=(--metadata "packet_kind=delta" --metadata "delta_from=${DELTA_FROM:-previous_turn}")
    else
        dispatch_event_args+=(--metadata "packet_kind=full")
    fi
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${dispatch_event_args[@]}" >/dev/null

    packet_event_args=(
        --event-type task.packet_generated
        --task "$TASK_ID"
        --actor "$ACTOR"
        --owner "$OWNER"
        --metadata "role=$ROLE_NAME"
        --metadata "backend=$BACKEND"
        --metadata "cycle_id=$CYCLE_ID"
    )
    if [[ -n "$POOL_WORKER" ]]; then
        packet_event_args+=(--metadata "pool_worker_key=$POOL_WORKER" --metadata "session_id=$SESSION_ID")
    fi
    [[ -n "$DELTA_FILE" ]] && packet_event_args+=(--metadata "packet_kind=delta")
    if [[ -n "$PACKET_OUT" ]]; then
        packet_sha256="$(sha256sum "$PACKET_OUT" | awk '{print $1}')"
        packet_event_args+=(--metadata "packet_sha256=$packet_sha256")
        packet_event_args+=(--artifact "$PACKET_OUT")
    else
        packet_event_args+=(--note "packet generated to stdout only")
    fi
    emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" "${packet_event_args[@]}" >/dev/null
    workflow_post_change_consistency "$SCRIPT_DIR" "$TARGET_DIR"

    if [[ "$NO_CLAIM" == true ]]; then
        echo "[dispatch] claim skipped for task $TASK_ID"
    else
        echo "[dispatch] claimed task $TASK_ID for owner $OWNER"
    fi
    echo "[dispatch] queue board refreshed"
    echo "[dispatch] canonical feedback skeleton path: ensured via task.dispatched callback when missing"
    if [[ -n "$PACKET_OUT" ]]; then
        echo "[dispatch] packet written to $PACKET_OUT"
    else
        echo "[dispatch] packet printed only; no packet artifact was written"
    fi
    echo ""
    printf '%s' "$packet"
}

workflow_run_with_lock "$SCRIPT_DIR" "$TARGET_DIR" main
