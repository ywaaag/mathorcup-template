#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
MODE="full"
COMPETITION_ARG=""
FORCE_RENDER=false
REWRITE_CONFIG=false
SKIP_DEPS=false
FULL_LATEX=false

usage() {
    cat <<'EOF'
Usage: bash scripts/setup.sh [competition_name] [options]

Modes:
  --render-only
  --bootstrap-only
  --deps-only
  --reset-state
  --doctor-only

Options:
  --target <dir>
  --force-render
  --rewrite-config
  --skip-deps
  --full-latex
EOF
}

set_mode() {
    [[ "$MODE" == "full" ]] || die "only one mode flag may be used"
    MODE="$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --render-only)
            set_mode "render"
            shift
            ;;
        --bootstrap-only)
            set_mode "bootstrap"
            shift
            ;;
        --deps-only)
            set_mode "deps"
            shift
            ;;
        --reset-state)
            set_mode "reset"
            shift
            ;;
        --doctor-only)
            set_mode "doctor"
            shift
            ;;
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --force-render)
            FORCE_RENDER=true
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

if [[ -n "$COMPETITION_ARG" ]]; then
    export COMPETITION_NAME="$COMPETITION_ARG"
    export CONTAINER_NAME="${CONTAINER_NAME:-${COMPETITION_ARG}-dev}"
fi

if [[ -f "$TARGET_DIR/.env" && -n "$COMPETITION_ARG" && "$REWRITE_CONFIG" == false ]]; then
    current_name="$(grep -E '^COMPETITION_NAME=' "$TARGET_DIR/.env" | head -n1 | cut -d= -f2- || true)"
    if [[ -n "$current_name" && "$current_name" != "$COMPETITION_ARG" ]]; then
        status_warn ".env already defines competition '$current_name'; keeping it. Use --rewrite-config to replace."
    fi
fi

render_args=(--target "$TARGET_DIR")
[[ "$FORCE_RENDER" == true ]] && render_args+=(--force)
[[ "$REWRITE_CONFIG" == true ]] && render_args+=(--force --include-config)

run_render() {
    status_info "rendering scaffold into $TARGET_DIR"
    bash "$SCRIPT_DIR/render_templates.sh" "${render_args[@]}"
    if [[ -f "$TARGET_DIR/project/runtime/task_registry.json" && -f "$TARGET_DIR/project/runtime/work_queue.json" ]]; then
        bash "$SCRIPT_DIR/render_task_registry.sh" --target "$TARGET_DIR" >/dev/null
    fi
}

run_doctor() {
    status_info "running doctor checks"
    bash "$SCRIPT_DIR/doctor.sh" --root "$TARGET_DIR"
}

case "$MODE" in
    render)
        run_render
        run_doctor
        ;;
    bootstrap)
        run_render
        bash "$SCRIPT_DIR/bootstrap_container.sh" --target "$TARGET_DIR"
        run_doctor
        ;;
    deps)
        run_render
        bash "$SCRIPT_DIR/bootstrap_container.sh" --target "$TARGET_DIR"
        deps_args=(--target "$TARGET_DIR")
        [[ "$FULL_LATEX" == true ]] && deps_args+=(--full-latex)
        bash "$SCRIPT_DIR/install_deps.sh" "${deps_args[@]}"
        run_doctor
        ;;
    reset)
        run_render
        bash "$SCRIPT_DIR/reset_state.sh" --target "$TARGET_DIR"
        run_doctor
        ;;
    doctor)
        run_doctor
        ;;
    full)
        run_render
        bash "$SCRIPT_DIR/bootstrap_container.sh" --target "$TARGET_DIR"
        if [[ "$SKIP_DEPS" == false ]]; then
            deps_args=(--target "$TARGET_DIR")
            [[ "$FULL_LATEX" == true ]] && deps_args+=(--full-latex)
            bash "$SCRIPT_DIR/install_deps.sh" "${deps_args[@]}"
        else
            status_skip "dependency installation skipped"
        fi
        run_doctor
        ;;
    *)
        die "unknown mode: $MODE"
        ;;
esac
