#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

COMPETITION_ARG=""
MODE="full"
REWRITE_CONFIG=false
SKIP_DEPS=false
FULL_LATEX=false

usage() {
    cat <<'EOF'
Usage: bash scripts/instantiate.sh <competition_name> [options]

Convert this template-source clone into a rendered instance in place.

Modes:
  --render-only       Render instance files and run validation/doctor only

Options:
  --force-render      Accepted for setup.sh symmetry; instantiation always rewrites non-state/non-config files
  --rewrite-config    Also rewrite .env and paper.env
  --skip-deps         After rendering, bootstrap container but skip deps install
  --full-latex        Pass through to install_deps.sh for full LaTeX install
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --render-only)
            MODE="render"
            shift
            ;;
        --force-render)
            shift
            ;;
        --rewrite-config)
            REWRITE_CONFIG=true
            shift
            ;;
        --skip-deps)
            SKIP_DEPS=true
            shift
            ;;
        --full-latex)
            FULL_LATEX=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            die "unknown option: $1"
            ;;
        *)
            [[ -z "$COMPETITION_ARG" ]] || die "competition name specified more than once"
            COMPETITION_ARG="$1"
            shift
            ;;
    esac
done

[[ -n "$COMPETITION_ARG" ]] || { usage >&2; die "missing competition_name"; }

ROOT_KIND="$(workflow_root_kind "$SCRIPT_DIR" "$ROOT_DIR")"
if [[ "$ROOT_KIND" != "template_source" ]]; then
    die "instantiate.sh must be run from a template-source clone before it has live instance state. Current root kind: $ROOT_KIND"
fi

export COMPETITION_NAME="$COMPETITION_ARG"
export CONTAINER_NAME="${CONTAINER_NAME:-${COMPETITION_ARG}-dev}"

render_args=(--target "$ROOT_DIR" --force)
[[ "$REWRITE_CONFIG" == true ]] && render_args+=(--include-config)

status_info "rendering scaffold into this clone: $ROOT_DIR"
bash "$SCRIPT_DIR/render_templates.sh" "${render_args[@]}"

if [[ -f "$ROOT_DIR/project/runtime/task_registry.json" && -f "$ROOT_DIR/project/runtime/work_queue.json" ]]; then
    bash "$SCRIPT_DIR/render_task_registry.sh" --target "$ROOT_DIR" >/dev/null
fi

status_info "validating rendered instance"
bash "$SCRIPT_DIR/validate_agent_docs.sh" --root "$ROOT_DIR"

if [[ "$MODE" == "render" ]]; then
    bash "$SCRIPT_DIR/doctor.sh" --root "$ROOT_DIR"
    status_ok "instance rendered in place. Bootstrap later with: bash scripts/setup.sh $COMPETITION_ARG"
    exit 0
fi

setup_args=("$COMPETITION_ARG")
[[ "$SKIP_DEPS" == true ]] && setup_args+=(--skip-deps)
[[ "$FULL_LATEX" == true ]] && setup_args+=(--full-latex)

status_info "continuing with container bootstrap/deps via setup.sh"
bash "$SCRIPT_DIR/setup.sh" "${setup_args[@]}"
