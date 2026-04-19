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
