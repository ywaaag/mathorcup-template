#!/bin/bash

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT_DIR="$(cd "$COMMON_DIR/../.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

status_ok() { echo -e "${GREEN}  ✓ $1${NC}"; }
status_skip() { echo -e "${YELLOW}  ↻ $1${NC}"; }
status_info() { echo -e "${BLUE}  → $1${NC}"; }
status_warn() { echo -e "${YELLOW}  ! $1${NC}"; }
status_err() { echo -e "${RED}  ✗ $1${NC}"; }

die() {
    status_err "$1" >&2
    exit 1
}

abs_path() {
    python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

load_kv_env_if_unset() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [[ -z "$key" ]] && continue
        if [[ -z "${!key+x}" ]]; then
            export "$key=$value"
        fi
    done < "$file"
}

load_root_env() {
    local root_dir="${1:-$DEFAULT_ROOT_DIR}"
    root_dir="$(abs_path "$root_dir")"

    load_kv_env_if_unset "$root_dir/.env"

    : "${HOST_DIR:=$root_dir}"
    : "${IMAGE_NAME:=mathorcup-runtime:latest}"
    : "${COMPETITION_NAME:=mathorcup}"
    : "${CONTAINER_NAME:=${COMPETITION_NAME}-dev}"
    : "${JUPYTER_PORT:=8888}"
    : "${RSTUDIO_PORT:=8787}"
    : "${JUPYTER_TOKEN:=mathorcup}"
    : "${CONTAINER_RUNTIME:=nvidia}"
    : "${CONTAINER_GPUS:=all}"
    : "${CONTAINER_PRIVILEGED:=true}"
    : "${CONTAINER_USER:=root}"
    : "${CONTAINER_GRANT_SUDO:=yes}"
    : "${PROJECT_CONTAINER_DIR:=/workspace/mathorcup}"
    : "${HOST_PROJECT_DIR:=$HOST_DIR/project}"

    export HOST_DIR IMAGE_NAME COMPETITION_NAME CONTAINER_NAME
    export JUPYTER_PORT RSTUDIO_PORT JUPYTER_TOKEN
    export CONTAINER_RUNTIME CONTAINER_GPUS CONTAINER_PRIVILEGED
    export CONTAINER_USER CONTAINER_GRANT_SUDO
    export PROJECT_CONTAINER_DIR HOST_PROJECT_DIR
}

load_paper_env() {
    local root_dir="${1:-$DEFAULT_ROOT_DIR}"
    root_dir="$(abs_path "$root_dir")"

    load_kv_env_if_unset "$root_dir/project/paper/runtime/paper.env"

    : "${PAPER_HOST_REL_DIR:=project/paper}"
    : "${PAPER_CONTAINER_DIR:=$PROJECT_CONTAINER_DIR/paper}"
    : "${PAPER_ACTIVE_ENTRYPOINT:=main.tex}"
    : "${PAPER_BUILD_DIR:=}"
    : "${PAPER_LATEX_ENGINE:=xelatex}"
    : "${PAPER_RUN_BIBER:=1}"
    : "${PAPER_BUILD_PASSES:=2}"
    : "${PAPER_TEXINPUTS:=}"
    : "${PAPER_ACCEPT_PDF:=project/paper/main.pdf}"
    : "${PAPER_ACCEPT_LOG:=project/paper/main.log}"
    : "${PAPER_ACCEPT_AUX:=project/paper/main.aux}"

    export PAPER_HOST_REL_DIR PAPER_CONTAINER_DIR PAPER_ACTIVE_ENTRYPOINT
    export PAPER_BUILD_DIR PAPER_LATEX_ENGINE PAPER_RUN_BIBER PAPER_BUILD_PASSES
    export PAPER_TEXINPUTS PAPER_ACCEPT_PDF PAPER_ACCEPT_LOG PAPER_ACCEPT_AUX
}

paper_entry_stem() {
    local entry="${PAPER_ACTIVE_ENTRYPOINT##*/}"
    echo "${entry%.tex}"
}

paper_host_dir() {
    echo "$HOST_DIR/$PAPER_HOST_REL_DIR"
}

paper_container_build_dir() {
    if [[ -n "${PAPER_BUILD_DIR:-}" ]]; then
        echo "$PAPER_CONTAINER_DIR/$PAPER_BUILD_DIR"
    else
        echo "$PAPER_CONTAINER_DIR"
    fi
}

paper_host_build_dir() {
    if [[ -n "${PAPER_BUILD_DIR:-}" ]]; then
        echo "$HOST_DIR/$PAPER_HOST_REL_DIR/$PAPER_BUILD_DIR"
    else
        echo "$HOST_DIR/$PAPER_HOST_REL_DIR"
    fi
}

container_exists() {
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -Fx "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
    docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -Fx "$CONTAINER_NAME" >/dev/null 2>&1
}
