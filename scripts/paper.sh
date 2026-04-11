#!/bin/bash
# ============================================================
# MathorCup 数模模板 — LaTeX 编译脚本
#
# 用法:
#   bash scripts/paper.sh                            # 默认容器 + build
#   bash scripts/paper.sh mathorcup-dev build        # 完整编译 main.tex（xelatex + biber + xelatex x2）
#   bash scripts/paper.sh mathorcup-dev biber        # 仅编译参考文献
#   bash scripts/paper.sh mathorcup-dev clean        # 清理辅助文件
#   bash scripts/paper.sh mathorcup-dev open         # 打开 PDF
# ============================================================
CONTAINER_NAME="${1:-mathorcup-dev}"
COMMAND="${2:-build}"

PAPER_DIR="/workspace/mathorcup/paper"
HOST_PAPER_DIR="${HOST_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/project/paper"

case "$COMMAND" in
    build)
        echo "→ 编译论文: $PAPER_DIR/main.tex"
        docker exec "$CONTAINER_NAME" bash -c "
            cd $PAPER_DIR && \
            echo '=== 第1次 xelatex ===' && \
            xelatex -interaction=nonstopmode main.tex 2>&1 | tail -20 && \
            echo '=== biber 编译参考文献 ===' && \
            biber main 2>&1 | tail -10 && \
            echo '=== 第2次 xelatex ===' && \
            xelatex -interaction=nonstopmode main.tex 2>&1 | tail -20 && \
            echo '=== 第3次 xelatex ===' && \
            xelatex -interaction=nonstopmode main.tex 2>&1 | tail -10 && \
            echo '=== 编译完成 ===' && \
            ls -lh main.pdf 2>/dev/null || echo '警告: main.pdf 未生成'
        "
        echo "→ PDF 输出位置: $HOST_PAPER_DIR/main.pdf"
        ;;

    biber)
        echo "→ 编译参考文献..."
        docker exec "$CONTAINER_NAME" bash -c "cd $PAPER_DIR && biber main" 2>&1 | tail -20
        ;;

    clean)
        echo "→ 清理辅助文件..."
        docker exec "$CONTAINER_NAME" bash -c "
            cd $PAPER_DIR && \
            rm -f main.aux main.bbl main.blg main.log main.out main.run.xml \
                  *.bcf *.synctex.gz backup/ 2>/dev/null; \
            echo '清理完成'
        "
        ;;

    open)
        echo "→ 打开 PDF（宿主机）..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            open "$HOST_PAPER_DIR/main.pdf" 2>/dev/null
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            xdg-open "$HOST_PAPER_DIR/main.pdf" 2>/dev/null || echo "请手动打开: $HOST_PAPER_DIR/main.pdf"
        fi
        ;;

    *)
        echo "用法: $0 [容器名] [build|biber|clean|open]"
        echo "  build   — 完整编译（默认）"
        echo "  biber   — 仅编译参考文献"
        echo "  clean   — 清理辅助文件"
        echo "  open    — 打开生成的 PDF"
        ;;
esac
