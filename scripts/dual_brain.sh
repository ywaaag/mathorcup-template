#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ROLE="${1:-menu}"
TARGET_DIR="$ROOT_DIR"

while [[ $# -gt 0 ]]; do
    case "$1" in
        main|code|paper|utility|both|menu)
            ROLE="$1"
            shift
            ;;
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        -h|--help)
            echo "Usage: bash scripts/dual_brain.sh [main|code|paper|utility|both]"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

load_root_env "$TARGET_DIR"
load_paper_env "$TARGET_DIR"

check_codex() {
    require_cmd codex
}

check_instance_ready() {
    [[ -f "$TARGET_DIR/AGENTS.md" ]] || die "instance files not rendered yet; run: bash scripts/setup.sh --render-only"
    [[ -f "$TARGET_DIR/MEMORY.md" ]] || die "MEMORY.md missing; run: bash scripts/setup.sh --render-only"
    [[ -f "$TARGET_DIR/project/paper/AGENTS.md" ]] || die "paper AGENTS missing; run: bash scripts/setup.sh --render-only"
}

check_docs() {
    bash "$SCRIPT_DIR/validate_agent_docs.sh" --root "$TARGET_DIR" >/dev/null
}

print_runtime_banner() {
    echo "============================================"
    echo "  MathorCup Multi-Agent Launcher"
    echo "============================================"
    echo "  root:            $TARGET_DIR"
    echo "  container:       $CONTAINER_NAME"
    echo "  paper entry:     $PAPER_ACTIVE_ENTRYPOINT"
    echo "  paper accept pdf: $PAPER_ACCEPT_PDF"
    echo "============================================"
}

start_session() {
    local role="$1"
    local cwd="$2"
    print_runtime_banner
    echo "role: $role"
    echo "cwd:  $cwd"
    echo "task packet helper: bash scripts/make_task_packet.sh $role"
    echo "press Enter to launch codex"
    read -r
    cd "$cwd"
    exec codex
}

check_instance_ready
check_docs
check_codex

case "$ROLE" in
    main)
        start_session "main" "$TARGET_DIR"
        ;;
    code)
        start_session "code" "$TARGET_DIR"
        ;;
    paper)
        start_session "paper" "$TARGET_DIR/project/paper"
        ;;
    utility)
        start_session "utility" "$TARGET_DIR"
        ;;
    both)
        print_runtime_banner
        cat <<EOF
Open two terminals:

Terminal A (代码脑)
  cd $TARGET_DIR
  codex

Terminal B (论文脑)
  cd $TARGET_DIR/project/paper
  codex

Useful helper:
  bash scripts/make_task_packet.sh code
  bash scripts/make_task_packet.sh paper
EOF
        ;;
    menu|*)
        print_runtime_banner
        echo "1) 主脑"
        echo "2) 代码脑"
        echo "3) 论文脑"
        echo "4) 杂务 Agent"
        echo "5) 代码脑 + 论文脑"
        read -r -p "请选择 (1/2/3/4/5): " choice
        case "$choice" in
            1) start_session "main" "$TARGET_DIR" ;;
            2) start_session "code" "$TARGET_DIR" ;;
            3) start_session "paper" "$TARGET_DIR/project/paper" ;;
            4) start_session "utility" "$TARGET_DIR" ;;
            5) ROLE="both"; print_runtime_banner; exec bash "$0" both --target "$TARGET_DIR" ;;
            *) die "invalid choice" ;;
        esac
        ;;
esac
