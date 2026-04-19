#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
FULL_LATEX=false
SKIP_PYTHON=false
SKIP_LATEX=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --full-latex)
            FULL_LATEX=true
            shift
            ;;
        --skip-python)
            SKIP_PYTHON=true
            shift
            ;;
        --skip-latex)
            SKIP_LATEX=true
            shift
            ;;
        -h|--help)
            echo "Usage: bash scripts/install_deps.sh [--target <dir>] [--full-latex] [--skip-python] [--skip-latex]"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

require_cmd docker
load_root_env "$TARGET_DIR"

container_running || die "container is not running: $CONTAINER_NAME"

if [[ "$SKIP_PYTHON" == false ]]; then
    status_info "installing Python competition packages"
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
        rich >/dev/null
    status_ok "Python packages ready"
else
    status_skip "skipped Python packages"
fi

if [[ "$SKIP_LATEX" == false ]]; then
    if docker exec "$CONTAINER_NAME" bash -lc 'command -v xelatex >/dev/null && command -v biber >/dev/null && command -v latexmk >/dev/null'; then
        status_skip "LaTeX toolchain already present"
    else
        if [[ "$FULL_LATEX" == true ]]; then
            status_info "installing full LaTeX toolchain"
            docker exec "$CONTAINER_NAME" bash -lc 'apt-get update >/dev/null && apt-get install -y texlive-full biber >/dev/null'
        else
            status_info "installing compact LaTeX toolchain"
            docker exec "$CONTAINER_NAME" bash -lc 'apt-get update >/dev/null && apt-get install -y --no-install-recommends texlive-latex-base texlive-latex-extra texlive-xetex texlive-bibtex-extra texlive-fonts-recommended fonts-wqy-microhei fonts-wqy-zenhei latexmk biber >/dev/null'
        fi
        status_ok "LaTeX toolchain ready"
    fi
else
    status_skip "skipped LaTeX packages"
fi
