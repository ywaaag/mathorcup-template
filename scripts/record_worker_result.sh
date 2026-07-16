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

usage() {
    echo "Usage: bash scripts/record_worker_result.sh --task <id> --actor <name> --backend <relay|codex_exec|subagent|human> --result <started|completed|failed|partial> [--artifact <path>]... [--note <text>] [--target <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK_ID="$2"; shift 2 ;;
        --actor) ACTOR="$2"; shift 2 ;;
        --backend) BACKEND="$2"; shift 2 ;;
        --result) RESULT="$2"; shift 2 ;;
        --artifact) ARTIFACT_ARGS+=(--artifact "$2"); shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --target|--root) TARGET_DIR="$(abs_path "$2")"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

[[ -n "$TASK_ID" && -n "$ACTOR" && -n "$BACKEND" && -n "$RESULT" ]] || { usage; exit 2; }
case "$BACKEND" in relay|codex_exec|subagent|human) ;; *) die "invalid backend: $BACKEND" ;; esac
case "$RESULT" in started|completed|failed|partial) ;; *) die "invalid result: $RESULT" ;; esac

OWNER="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" owner)"
STATUS="$(workflow_task_field "$SCRIPT_DIR" "$TARGET_DIR" "$TASK_ID" status)"
emit_workflow_event "$SCRIPT_DIR" "$TARGET_DIR" \
    --event-type "worker.$RESULT" \
    --task "$TASK_ID" \
    --actor "$ACTOR" \
    --owner "$OWNER" \
    --from-status "$STATUS" \
    --to-status "$STATUS" \
    --metadata "backend=$BACKEND" \
    "${ARTIFACT_ARGS[@]}" \
    --note "$NOTE"
