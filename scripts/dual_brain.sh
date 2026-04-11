#!/bin/bash
# ============================================================
# MathorCup 数模模板 — 双脑协作启动脚本
#
# 同时启动代码脑和论文脑两个 Codex 实例
# 代码脑: 根目录
# 论文脑: paper/ 目录
#
# 用法:
#   bash scripts/dual_brain.sh                     # 交互式选择
#   bash scripts/dual_brain.sh code                # 仅启动代码脑
#   bash scripts/dual_brain.sh paper               # 仅启动论文脑
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# 优先级：显式环境变量 > .env 配置 > 默认值
if [[ -z "${CONTAINER_NAME:-}" && -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi
CONTAINER_NAME="${CONTAINER_NAME:-mathorcup-dev}"

echo "============================================"
echo "  MathorCup 双脑协作系统"
echo "============================================"
echo "  项目目录: $PROJECT_DIR"
echo "  容器:     $CONTAINER_NAME"
echo "============================================"
echo ""

check_container() {
    if ! docker ps --filter "name=$CONTAINER_NAME" | grep -q "$CONTAINER_NAME"; then
        echo "❌ 容器 $CONTAINER_NAME 未运行"
        echo "   请先: docker start $CONTAINER_NAME"
        exit 1
    fi
}

check_codex() {
    if ! command -v codex >/dev/null 2>&1; then
        echo "❌ 未检测到 codex 命令"
        echo "   请先安装 Codex CLI，并确保 'codex' 在 PATH 中"
        exit 1
    fi
}

check_agent_docs() {
    if ! bash "$SCRIPT_DIR/validate_agent_docs.sh"; then
        echo "❌ Agent 协议校验失败，已阻止启动"
        echo "   请先修复 MEMORY.md 或 handoff 文档格式"
        exit 1
    fi
}

start_code_brain() {
    echo "→ 启动代码脑..."
    echo ""
    echo "  【代码脑】将在以下目录运行:"
    echo "    $PROJECT_DIR"
    echo ""
    echo "  常用指令:"
    echo "    • 建模分析: '帮我分析 data/ 下的赛题'"
    echo "    • 生成结果: '求解问题一，图表存到 figures/'"
    echo "    • 更新记忆: '将问题一的核心公式记录到 MEMORY.md'"
    echo ""
    echo "  按 Enter 在当前终端启动代码脑..."
    read
    cd "$PROJECT_DIR" && codex
}

start_paper_brain() {
    echo "→ 启动论文脑..."
    echo ""
    echo "  【论文脑】将在以下目录运行:"
    echo "    $PROJECT_DIR/project/paper"
    echo ""
    echo "  常用指令:"
    echo "    • 读取进度: '去 MEMORY.md 读取问题一的建模结果'"
    echo "    • 写章节:   '根据 figures/problem1.png 写问题一的求解章节'"
    echo "    • 转表格:   '将 output/result1.csv 转为 LaTeX 三线表'"
    echo "    • 编译检查: '运行 xelatex 检查编译错误'"
    echo ""
    echo "  按 Enter 在当前终端启动论文脑..."
    read
    cd "$PROJECT_DIR/project/paper" && codex
}

case "${1:-menu}" in
    code)
        check_agent_docs
        check_container
        check_codex
        start_code_brain
        ;;
    paper)
        check_agent_docs
        check_container
        check_codex
        start_paper_brain
        ;;
    both)
        check_agent_docs
        check_container
        check_codex
        echo "⚠️  双脑需要两个终端窗口，请执行以下操作:"
        echo ""
        echo "  【终端 A - 代码脑】"
        echo "    cd $PROJECT_DIR"
        echo "    codex"
        echo ""
        echo "  【终端 B - 论文脑】"
        echo "    cd $PROJECT_DIR/project/paper"
        echo "    codex"
        echo ""
        read -p "按 Enter 启动代码脑（论文脑请手动开另一个终端）..."
        start_code_brain
        ;;
    menu|*)
        echo "请选择:"
        echo "  1) 同时启动双脑（需两个终端）"
        echo "  2) 仅启动代码脑（建模 + 代码）"
        echo "  3) 仅启动论文脑（LaTeX + 写作）"
        echo ""
        read -p "请输入 (1/2/3): " choice
        case "$choice" in
            1) bash "$0" both ;;
            2) check_agent_docs && check_container && check_codex && start_code_brain ;;
            3) check_agent_docs && check_container && check_codex && start_paper_brain ;;
            *) echo "无效选择" ;;
        esac
        ;;
esac
