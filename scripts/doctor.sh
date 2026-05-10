#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
OUTPUT_FORMAT="text"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root|--target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --format)
            case "$2" in
                text|json)
                    OUTPUT_FORMAT="$2"
                    shift 2
                    ;;
                *)
                    die "unknown format: $2"
                    ;;
            esac
            ;;
        -h|--help)
            echo "Usage: bash scripts/doctor.sh [--root <dir>|--target <dir>] [--json|--format text|json]"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    python3 - "$TARGET_DIR" "$SCRIPT_DIR" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[2]) / "lib"))
from workflow_kernel.doctor import doctor_payload

print(json.dumps(doctor_payload(Path(sys.argv[1]), Path(sys.argv[2])), ensure_ascii=True, indent=2))
PY
    exit 0
fi

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
echo "== Acceptance Helpers =="
if [[ -f "$SCRIPT_DIR/paper_acceptance_check.sh" ]]; then
    status_ok "paper acceptance checker available via bash scripts/paper_acceptance_check.sh"
    if [[ "$ROOT_KIND" == "template_source" ]]; then
        status_info "render an instance first, then run bash scripts/paper_acceptance_check.sh --target <rendered-instance> after paper build"
    else
        status_info "run bash scripts/paper_acceptance_check.sh --target $TARGET_DIR after paper build to verify host-visible PDF/log artifacts"
    fi
else
    status_warn "paper acceptance checker script missing"
fi
if [[ -f "$SCRIPT_DIR/artifact_index.sh" ]]; then
    status_ok "artifact index helper available via bash scripts/artifact_index.sh"
    if [[ "$ROOT_KIND" == "template_source" ]]; then
        status_info "render an instance first, then run bash scripts/artifact_index.sh --target <rendered-instance>"
    else
        status_info "run bash scripts/artifact_index.sh --target $TARGET_DIR to index packets, feedback, retrospectives, exec/callback runs, handoffs, and acceptance reports"
    fi
else
    status_warn "artifact index helper script missing"
fi
if [[ "$ROOT_KIND" == "template_source" ]]; then
    [[ -f "$TARGET_DIR/scaffold/project/output/MODEL_MANIFEST_TEMPLATE.json" ]] && status_ok "model manifest template detected" || status_warn "model manifest template missing"
    [[ -f "$TARGET_DIR/scaffold/project/output/review/PAPER_ACCEPTANCE_CHECKLIST.md" ]] && status_ok "paper acceptance checklist scaffold detected" || status_warn "paper acceptance checklist scaffold missing"
else
    [[ -f "$TARGET_DIR/project/output/MODEL_MANIFEST_TEMPLATE.json" ]] && status_ok "model manifest template detected" || status_warn "model manifest template missing"
    [[ -f "$TARGET_DIR/project/output/review/PAPER_ACCEPTANCE_CHECKLIST.md" ]] && status_ok "paper acceptance checklist detected" || status_warn "paper acceptance checklist missing"
fi

echo ""
echo "== Codex Native Bridge =="
if [[ "$ROOT_KIND" == "template_source" ]]; then
    [[ -f "$TARGET_DIR/.codex/requirements.toml" ]] && status_ok "template-source .codex requirements detected" || status_warn "template-source .codex requirements missing"
    root_skill_count="$(find "$TARGET_DIR/.codex/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${root_skill_count:-0}" -gt 0 ]] && status_ok "template-source .codex skills detected (${root_skill_count})" || status_warn "template-source .codex skills missing"
    [[ -f "$TARGET_DIR/scaffold/.codex/requirements.toml.template" ]] && status_ok "instance scaffold .codex requirements template detected" || status_warn "instance scaffold .codex requirements template missing"
    scaffold_skill_count="$(find "$TARGET_DIR/scaffold/.codex/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${scaffold_skill_count:-0}" -gt 0 ]] && status_ok "instance scaffold .codex skills detected (${scaffold_skill_count})" || status_warn "instance scaffold .codex skills missing"
    if [[ -f "$TARGET_DIR/.codex/hooks.json" || -f "$TARGET_DIR/scaffold/.codex/hooks.json.template" ]]; then
        status_warn "native hooks file present; review whether it is still intentionally optional"
    else
        status_info "native hooks not enabled; requirements + skills bridge only"
    fi
else
    [[ -f "$TARGET_DIR/.codex/requirements.toml" ]] && status_ok "rendered instance .codex requirements detected" || status_warn "rendered instance .codex requirements missing"
    instance_skill_count="$(find "$TARGET_DIR/.codex/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${instance_skill_count:-0}" -gt 0 ]] && status_ok "rendered instance .codex skills detected (${instance_skill_count})" || status_warn "rendered instance .codex skills missing"
    if [[ -f "$TARGET_DIR/.codex/hooks.json" ]]; then
        status_warn "rendered instance native hooks file present; review whether it is still intentionally optional"
    else
        status_info "rendered instance native hooks not enabled; repo harness remains the only required workflow engine"
    fi
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
    tool_report="$(docker exec -w / "$CONTAINER_NAME" bash -lc '
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
python3 - <<'PY'
modules = [
    "numpy",
    "pandas",
    "polars",
    "scipy",
    "sklearn",
    "matplotlib",
    "seaborn",
    "plotly",
    "ortools",
    "pulp",
    "deap",
    "pygmo",
    "sympy",
    "statsmodels",
    "openpyxl",
    "docx",
    "pptx",
    "rich",
    "tqdm",
]
for module in modules:
    try:
        __import__(module)
        print(f"OK py:{module}")
    except Exception:
        print(f"MISS py:{module}")
PY
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
