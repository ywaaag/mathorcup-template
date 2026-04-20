#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

MODE="all"
TARGET_ROOT="$ROOT_DIR"

usage() {
    echo "Usage: $0 [--root <dir>] [--memory-only|--handoff-only|--contracts-only|--paper-config-only|--roles-only|--tasks-only|--queue-only|--feedback-only|--retrospective-only|--events-only|--callbacks-only|--harness-only|--template-source-only]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            TARGET_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")"
            shift 2
            ;;
        --memory-only)
            MODE="memory"
            shift
            ;;
        --handoff-only)
            MODE="handoff"
            shift
            ;;
        --contracts-only)
            MODE="contracts"
            shift
            ;;
        --paper-config-only)
            MODE="paper"
            shift
            ;;
        --roles-only)
            MODE="roles"
            shift
            ;;
        --tasks-only)
            MODE="tasks"
            shift
            ;;
        --queue-only)
            MODE="queue"
            shift
            ;;
        --feedback-only)
            MODE="feedback"
            shift
            ;;
        --retrospective-only)
            MODE="retrospective"
            shift
            ;;
        --events-only)
            MODE="events"
            shift
            ;;
        --callbacks-only)
            MODE="callbacks"
            shift
            ;;
        --harness-only)
            MODE="harness"
            shift
            ;;
        --template-source-only|--source-only)
            MODE="template_source"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            echo "[validate_agent_docs] ERROR: unknown option: $1" >&2
            exit 2
            ;;
    esac
done

ROOT_KIND="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" root-kind --root "$TARGET_ROOT")"

if [[ "$ROOT_KIND" == "template_source" && "$MODE" != "template_source" ]]; then
    cat <<EOF
[validate_agent_docs] NOTICE: detected template-source repository at $TARGET_ROOT
[validate_agent_docs] This repo keeps source-of-truth under scaffold/ and does not keep rendered live instance files like project/spec/agent_roles.yaml at repo root.
[validate_agent_docs] Requested mode '$MODE' is instance-oriented, so it was not executed against the template source tree.
[validate_agent_docs] Next steps:
  1. run: bash scripts/validate_agent_docs.sh --template-source-only
  2. or render a temp instance:
     tmpdir="\$(mktemp -d)"
     bash scripts/setup.sh demo --render-only --target "\$tmpdir"
     bash scripts/validate_agent_docs.sh --root "\$tmpdir"
EOF
    python3 "$SCRIPT_DIR/lib/workflow_state.py" validate --root "$TARGET_ROOT" --mode "template_source"
    exit 0
fi

run_workflow_validation() {
    python3 "$SCRIPT_DIR/lib/workflow_state.py" validate --root "$TARGET_ROOT" --mode "$1"
}

run_events_validation() {
    python3 "$SCRIPT_DIR/lib/workflow_events.py" validate-events --root "$TARGET_ROOT"
}

run_callbacks_validation() {
    python3 "$SCRIPT_DIR/lib/workflow_events.py" validate-callbacks --root "$TARGET_ROOT"
}

run_harness_validation() {
    [[ -f "$SCRIPT_DIR/process_callbacks.sh" ]] || { echo "missing script: $SCRIPT_DIR/process_callbacks.sh" >&2; exit 1; }
    [[ -f "$SCRIPT_DIR/run_exec_batch.sh" ]] || { echo "missing script: $SCRIPT_DIR/run_exec_batch.sh" >&2; exit 1; }
    run_events_validation
    run_callbacks_validation
    echo "[validate_agent_docs] OK (harness)"
}

case "$MODE" in
    all)
        run_workflow_validation all
        run_events_validation
        run_callbacks_validation
        ;;
    memory|handoff|contracts|paper|roles|tasks|queue|feedback|retrospective)
        run_workflow_validation "$MODE"
        ;;
    events)
        run_events_validation
        ;;
    callbacks)
        run_callbacks_validation
        ;;
    harness)
        run_harness_validation
        ;;
    template_source)
        run_workflow_validation template_source
        ;;
    *)
        echo "[validate_agent_docs] ERROR: unknown mode $MODE" >&2
        exit 2
        ;;
esac
