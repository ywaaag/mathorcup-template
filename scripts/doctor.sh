#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root|--target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        -h|--help)
            echo "Usage: bash scripts/doctor.sh [--root <dir>]"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

ROOT_KIND="$(python3 "$SCRIPT_DIR/lib/workflow_state.py" root-kind --root "$TARGET_DIR")"

load_root_env "$TARGET_DIR"
load_paper_env "$TARGET_DIR"

if [[ "$ROOT_KIND" == "template_source" ]]; then
    echo "== Repo Mode =="
    echo "template-source"
    echo "- This root is the template source tree."
    echo "- scaffold/ contains source-of-truth templates."
    echo "- Rendered instance validation should target a generated directory, not this repo root."
    echo ""
fi

echo "== Runtime Config =="
echo "root:            $TARGET_DIR"
echo "competition:     $COMPETITION_NAME"
echo "image:           $IMAGE_NAME"
echo "container:       $CONTAINER_NAME"
echo "host project:    $HOST_PROJECT_DIR"
echo "runtime:         ${CONTAINER_RUNTIME:-default}"
echo "gpus:            ${CONTAINER_GPUS:-none}"
echo "privileged:      $CONTAINER_PRIVILEGED"
echo "container user:  ${CONTAINER_USER:-<image default>}"
echo "grant sudo:      ${CONTAINER_GRANT_SUDO:-<image default>}"
echo "paper entry:     $PAPER_ACTIVE_ENTRYPOINT"
echo "paper build dir: ${PAPER_BUILD_DIR:-<same as paper dir>}"
echo "accept pdf:      $PAPER_ACCEPT_PDF"
echo "truth source:    .env + project/paper/runtime/paper.env"
echo "rendered mirror: project/spec/runtime_contract.md + project/paper/spec/paper_runtime_contract.md"
if [[ "$ROOT_KIND" == "template_source" ]]; then
    echo "note:            template-source preview values; render an instance for live runtime facts"
fi

echo ""
echo "== Tooling =="
for cmd in python3 docker codex; do
    if command -v "$cmd" >/dev/null 2>&1; then
        status_ok "$cmd"
    else
        status_warn "$cmd not found"
    fi
done

echo ""
echo "== Exec Worker Mode =="
if command -v codex >/dev/null 2>&1; then
    if codex exec --help >/dev/null 2>&1; then
        status_ok "codex exec CLI detected"
        status_ok "exec wrapper available via bash scripts/run_exec_worker.sh"
        status_info "run bash scripts/exec_healthcheck.sh --target $TARGET_DIR for a real non-interactive probe"
    else
        status_warn "codex exec subcommand unavailable"
    fi
else
    status_warn "codex not found; exec worker mode unavailable"
fi

echo ""
echo "== Event Harness =="
if [[ "$ROOT_KIND" == "template_source" ]]; then
    [[ -f "$TARGET_DIR/scaffold/project/runtime/event_log.jsonl.template" ]] && status_ok "template event log scaffold detected"
    [[ -f "$TARGET_DIR/scaffold/project/spec/callback_hooks.json.template" ]] && status_ok "template callback hooks scaffold detected"
else
    if [[ -f "$TARGET_DIR/project/runtime/event_log.jsonl" ]]; then
        event_count="$(python3 - <<'PY' "$TARGET_DIR/project/runtime/event_log.jsonl"
from pathlib import Path
import sys
count = sum(1 for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip())
print(count)
PY
)"
        status_ok "event log detected (${event_count} event(s))"
    else
        status_warn "event log missing"
    fi
    if [[ -f "$TARGET_DIR/project/spec/callback_hooks.json" ]]; then
        status_ok "callback hooks detected"
    else
        status_warn "callback hooks missing"
    fi
fi
if [[ -f "$SCRIPT_DIR/process_callbacks.sh" ]]; then
    status_ok "callback processor available via bash scripts/process_callbacks.sh"
else
    status_warn "callback processor script missing"
fi
if [[ -f "$SCRIPT_DIR/run_exec_batch.sh" ]]; then
    status_ok "batch supervisor available via bash scripts/run_exec_batch.sh"
else
    status_warn "batch supervisor script missing"
fi

echo ""
echo "== Validation =="
bash "$SCRIPT_DIR/validate_agent_docs.sh" --root "$TARGET_DIR"

echo ""
echo "== Container State =="
if command -v docker >/dev/null 2>&1; then
    if container_running; then
        status_ok "container is running"
    elif container_exists; then
        status_warn "container exists but is stopped"
    else
        status_warn "container does not exist"
    fi
fi

echo ""
echo "== Container Tool Baseline =="
if command -v docker >/dev/null 2>&1 && container_running; then
    tool_report="$(docker exec "$CONTAINER_NAME" bash -lc '
check() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "OK %s %s\n" "$cmd" "$(command -v "$cmd")"
    else
        printf "MISS %s\n" "$cmd"
    fi
}
check biber
check tree
check yq
if command -v fd >/dev/null 2>&1; then
    printf "OK fd %s\n" "$(command -v fd)"
elif command -v fdfind >/dev/null 2>&1; then
    printf "WARN fd %s\n" "$(command -v fdfind)"
else
    printf "MISS fd\n"
fi
' 2>/dev/null || true)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            "OK "*)
                status_ok "${line#OK }"
                ;;
            "WARN "*)
                status_warn "${line#WARN } (fdfind only; reference image should expose fd)"
                ;;
            "MISS "*)
                status_warn "${line#MISS } missing"
                ;;
        esac
    done <<< "$tool_report"
else
    status_warn "container baseline skipped"
fi
