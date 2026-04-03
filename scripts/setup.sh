#!/bin/bash
# ============================================================
# MathorCup 数模模板 — 一键初始化脚本
#
# 用法: bash scripts/setup.sh [比赛名称] [--full-latex] [--skip-deps]
#
# 示例:
#   bash scripts/setup.sh mathorcup2025
#   bash scripts/setup.sh 华为杯2025 --full-latex
#   bash scripts/setup.sh mathorcup2025 --skip-deps
# ============================================================
set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 状态函数
status_ok() { echo -e "${GREEN}  ✓ $1${NC}"; }
status_skip() { echo -e "${YELLOW}  ↻ $1${NC}"; }
status_info() { echo -e "${BLUE}  → $1${NC}"; }
status_err() { echo -e "${RED}  ✗ $1${NC}"; }

# 参数初始化
HOST_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FULL_LATEX=false
SKIP_DEPS=false

# 解析参数
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --full-latex)
            FULL_LATEX=true
            ;;
        --skip-deps)
            SKIP_DEPS=true
            ;;
        -*)
            echo "未知选项: $arg"
            exit 1
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

# 第一个非选项参数作为比赛名称
if [ ${#ARGS[@]} -gt 0 ]; then
    COMPETITION_NAME="${ARGS[0]}"
else
    COMPETITION_NAME="mathorcup"
fi
CONTAINER_NAME="${COMPETITION_NAME}-dev"

echo "============================================"
echo "  MathorCup 数模竞赛模板 — 初始化"
echo "============================================"
echo "  比赛名称: $COMPETITION_NAME"
echo "  容器名:   $CONTAINER_NAME"
echo "  项目目录: $HOST_DIR"
echo "  LaTeX:    $([ "$FULL_LATEX" = true ] && echo "完整版 (~4GB)" || echo "精简版 (~500MB)")"
echo "  依赖安装: $([ "$SKIP_DEPS" = true ] && echo "跳过 (假定镜像已预装)" || echo "正常安装")"
echo "============================================"

# 1. 检查镜像
echo "[1/8] 检查镜像..."
if docker images | grep -q "math-modeling-competition"; then
    status_ok "镜像 'math-modeling-competition' 已存在，跳过拉取"
else
    status_err "镜像 'math-modeling-competition' 不存在"
    echo "  请先拉取或构建镜像："
    echo "    docker pull math-modeling-competition:latest"
    echo "  或使用版本标签：math-modeling-competition:20260403"
    echo "  若需从基础镜像构建，请参考项目文档。"
    exit 1
fi

# 2. 检查容器
echo "[2/8] 检查容器..."
if docker ps -a --filter "name=$CONTAINER_NAME" | grep -q "$CONTAINER_NAME"; then
    status_ok "容器 '$CONTAINER_NAME' 已存在"
    read -p "  是否删除旧容器重新创建？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        status_info "删除旧容器..."
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    else
        echo "  使用现有容器，继续..."
    fi
fi

# 3. 创建容器
echo "[3/8] 创建容器..."
if ! docker ps -a --filter "name=$CONTAINER_NAME" | grep -q "$CONTAINER_NAME"; then
    status_info "docker run ..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --gpus all \
        --runtime=nvidia \
        --privileged \
        -p 8888:8888 \
        -p 8787:8787 \
        -v "$HOST_DIR/project:/workspace/mathorcup" \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e JUPYTER_TOKEN=mathorcup \
        --restart unless-stopped \
        math-modeling-competition:latest \
        /usr/bin/env bash -c "while true; do sleep 86400; done"
    status_ok "容器 '$CONTAINER_NAME' 创建成功"
else
    status_ok "复用已有容器"
fi

# 4. 启动容器
echo "[4/8] 确保容器运行中..."
docker start "$CONTAINER_NAME" 2>/dev/null || true

# 5. 安装 Python 竞赛库
echo "[5/8] 安装 Python 竞赛常用库..."
if [ "$SKIP_DEPS" = true ]; then
    status_skip "跳过 Python 依赖安装 (假定镜像已预装)"
else
    status_info "安装 Python 竞赛常用库..."
    docker exec "$CONTAINER_NAME" pip install --no-cache-dir \
        polars==1.25.2 \
        lightgbm \
        xgboost \
        ortools \
        pulp \
        deap \
        pygmo \
        scipy \
        statsmodels \
        sympy \
        matplotlib \
        seaborn \
        plotly \
        openpyxl \
        xlrd \
        python-docx \
        python-pptx \
        tqdm \
        rich \
        2>&1 | grep -E "(Successfully|already satisfied|ERROR|Requirement)" || true
    status_ok "Python 依赖安装完成"
fi

# 6. 安装 LaTeX 环境
echo "[6/8] 安装 LaTeX 编译环境..."
if [ "$SKIP_DEPS" = true ]; then
    status_skip "跳过 LaTeX 安装 (假定镜像已预装)"
else
    if docker exec "$CONTAINER_NAME" which xelatex &>/dev/null; then
        status_ok "LaTeX 已存在，跳过"
    else
        status_info "安装 TeX Live 精简版（可能需要 3-5 分钟）..."
        docker exec "$CONTAINER_NAME" bash -c "apt-get update && apt-get install -y --no-install-recommends \
            texlive-latex-base \
            texlive-latex-extra \
            texlive-xetex \
            texlive-bibtex-extra \
            texlive-fonts-recommended \
            fonts-wqy-microhei \
            fonts-wqy-zenhei \
            latexmk \
            2>&1 | tail -5"
        status_ok "LaTeX 安装完成"
    fi
fi

# 7. 生成配置文件
echo "[7/8] 生成 Claude Code 配置文件..."

python3 << 'PYEOF'
import os, datetime

HOST_DIR = os.environ.get('HOST_DIR', '/home/ywag/mathorcup-template')
COMPETITION_NAME = os.environ.get('COMPETITION_NAME', 'mathorcup')
CONTAINER_NAME = os.environ.get('CONTAINER_NAME', 'mathorcup-dev')

replacements = {
    '{{COMPETITION_NAME}}': COMPETITION_NAME,
    '{{CONTAINER_NAME}}': CONTAINER_NAME,
    '{{HOST_DIR}}': HOST_DIR,
    '{{JUPYTER_PORT}}': '8888',
    '{{RSTUDIO_PORT}}': '8787',
    '{{JUPYTER_TOKEN}}': 'mathorcup',
}

def fill_template(src_path):
    with open(src_path, 'r', encoding='utf-8') as f:
        content = f.read()
    for old, new in replacements.items():
        content = content.replace(old, new)
    dst_path = src_path.replace('.template', '')
    with open(dst_path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f'  ✓ {os.path.relpath(dst_path, HOST_DIR)}')

# 根目录模板
for t in ['CLAUDE.md.template', 'MEMORY.md.template']:
    fill_template(os.path.join(HOST_DIR, t))

# 论文脑模板
paper_src = os.path.join(HOST_DIR, 'project', 'paper', 'CLAUDE.md.template')
if os.path.exists(paper_src):
    fill_template(paper_src)

# 创建论文章节空文件
sections_dir = os.path.join(HOST_DIR, 'project', 'paper', 'sections')
os.makedirs(sections_dir, exist_ok=True)
for sec in ['00_abstract', '01_intro', '02_symbols', '03_model_1', '04_model_2',
            '05_model_3', '06_model_4', '07_validation', '08_conclusion', '09_appendix']:
    fpath = os.path.join(sections_dir, f'{sec}.tex')
    if not os.path.exists(fpath):
        with open(fpath, 'w', encoding='utf-8') as f:
            sec_name = sec.replace('_', ' ').replace('0', '').title()
            f.write(f'%% {sec_name}\n')
            f.write(f'%% 更新时间: {datetime.datetime.now().strftime("%Y-%m-%d %H:%M")}\n\n')
            f.write(f'%% \\section{{{sec_name}}}\n')
            f.write(f'%% \\label{{sec:{sec}}}\n\n')
            f.write('%% 在此填写内容\n')
PYEOF

# 8. 生成 .env
echo "[8/8] 生成环境配置..."
cat > "$HOST_DIR/.env" << EOF
IMAGE_NAME=math-modeling-competition:latest
COMPETITION_NAME=$COMPETITION_NAME
CONTAINER_NAME=$CONTAINER_NAME
JUPYTER_PORT=8888
RSTUDIO_PORT=8787
JUPYTER_TOKEN=mathorcup
HOST_PROJECT_DIR=$HOST_DIR/project
HOST_DIR=$HOST_DIR
EOF
status_ok ".env 已生成"

echo ""
echo "============================================"
echo "  初始化完成！"
echo "============================================"
echo ""
echo "  启动容器: docker start $CONTAINER_NAME"
echo "  进入容器: docker exec -it $CONTAINER_NAME bash"
echo "  Jupyter:   http://localhost:8888  (密码: mathorcup)"
echo ""
echo "  ┌─────────────────────────────────────┐"
echo "  │  双脑协作启动方式：                  │"
echo "  │                                     │"
echo "  │  终端 A (代码脑):                   │"
echo "  │    cd $HOST_DIR                    │"
echo "  │    claude code .                    │"
echo "  │                                     │"
echo "  │  终端 B (论文脑):                   │"
echo "  │    cd $HOST_DIR/project/paper      │"
echo "  │    claude code .                    │"
echo "  │                                     │"
echo "  │  或用脚本（自动分配终端）:          │"
echo "  │    bash scripts/dual_brain.sh both  │"
echo "  └─────────────────────────────────────┘"
echo ""
echo "  LaTeX 编译: bash scripts/paper.sh build"
echo "============================================"
