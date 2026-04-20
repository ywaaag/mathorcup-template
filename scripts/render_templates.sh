#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
FORCE=false
INCLUDE_STATE=false
INCLUDE_CONFIG=false
DRY_RUN=false
ONLY_PATHS=()

usage() {
    cat <<'EOF'
Usage: bash scripts/render_templates.sh [options]

Options:
  --target <dir>        Render into the given directory
  --force               Overwrite existing rendered files (except state/config unless enabled)
  --include-state       Allow overwriting runtime state files such as MEMORY.md
  --include-config      Allow overwriting runtime config files such as .env and paper.env
  --only <relpath>      Render only one scaffold-relative file (repeatable)
  --dry-run             Print planned actions without writing files
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --include-state)
            INCLUDE_STATE=true
            shift
            ;;
        --include-config)
            INCLUDE_CONFIG=true
            shift
            ;;
        --only)
            ONLY_PATHS+=("$2")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

mkdir -p "$TARGET_DIR"
load_root_env "$TARGET_DIR"
load_paper_env "$TARGET_DIR"

export TARGET_DIR ROOT_DIR FORCE INCLUDE_STATE INCLUDE_CONFIG DRY_RUN
export PAPER_HOST_DIR="$(paper_host_dir)"
export PAPER_CONTAINER_BUILD_DIR="$(paper_container_build_dir)"
export PAPER_HOST_BUILD_DIR="$(paper_host_build_dir)"

if (( ${#ONLY_PATHS[@]} > 0 )); then
    export ONLY_PATHS_JOINED
    ONLY_PATHS_JOINED="$(printf '%s\n' "${ONLY_PATHS[@]}")"
else
    export ONLY_PATHS_JOINED=""
fi

python3 - "$ROOT_DIR/scaffold" "$TARGET_DIR" <<'PY'
import os
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])

force = os.environ["FORCE"] == "true"
include_state = os.environ["INCLUDE_STATE"] == "true"
include_config = os.environ["INCLUDE_CONFIG"] == "true"
dry_run = os.environ["DRY_RUN"] == "true"

only_paths = {
    line.strip()
    for line in os.environ.get("ONLY_PATHS_JOINED", "").splitlines()
    if line.strip()
}

stateful_templates = {
    "MEMORY.md.template",
    "project/runtime/task_registry.yaml.template",
    "project/runtime/work_queue.yaml.template",
    "project/runtime/event_log.jsonl.template",
    "project/workflow/MAIN_BRAIN_QUEUE.md.template",
}
config_templates = {".env.template", "project/paper/runtime/paper.env.template"}

replacements = {
    "{{HOST_DIR}}": os.environ["HOST_DIR"],
    "{{HOST_PROJECT_DIR}}": os.environ["HOST_PROJECT_DIR"],
    "{{COMPETITION_NAME}}": os.environ["COMPETITION_NAME"],
    "{{CONTAINER_NAME}}": os.environ["CONTAINER_NAME"],
    "{{IMAGE_NAME}}": os.environ["IMAGE_NAME"],
    "{{JUPYTER_PORT}}": os.environ["JUPYTER_PORT"],
    "{{RSTUDIO_PORT}}": os.environ["RSTUDIO_PORT"],
    "{{JUPYTER_TOKEN}}": os.environ["JUPYTER_TOKEN"],
    "{{CONTAINER_RUNTIME}}": os.environ["CONTAINER_RUNTIME"],
    "{{CONTAINER_GPUS}}": os.environ["CONTAINER_GPUS"],
    "{{CONTAINER_PRIVILEGED}}": os.environ["CONTAINER_PRIVILEGED"],
    "{{CONTAINER_USER}}": os.environ["CONTAINER_USER"],
    "{{CONTAINER_GRANT_SUDO}}": os.environ["CONTAINER_GRANT_SUDO"],
    "{{PAPER_HOST_REL_DIR}}": os.environ["PAPER_HOST_REL_DIR"],
    "{{PAPER_HOST_DIR}}": os.environ["PAPER_HOST_DIR"],
    "{{PAPER_CONTAINER_DIR}}": os.environ["PAPER_CONTAINER_DIR"],
    "{{PAPER_CONTAINER_BUILD_DIR}}": os.environ["PAPER_CONTAINER_BUILD_DIR"],
    "{{PAPER_BUILD_DIR}}": os.environ["PAPER_BUILD_DIR"],
    "{{PAPER_ACTIVE_ENTRYPOINT}}": os.environ["PAPER_ACTIVE_ENTRYPOINT"],
    "{{PAPER_LATEX_ENGINE}}": os.environ["PAPER_LATEX_ENGINE"],
    "{{PAPER_RUN_BIBER}}": os.environ["PAPER_RUN_BIBER"],
    "{{PAPER_BUILD_PASSES}}": os.environ["PAPER_BUILD_PASSES"],
    "{{PAPER_TEXINPUTS}}": os.environ["PAPER_TEXINPUTS"],
    "{{PAPER_ACCEPT_PDF}}": os.environ["PAPER_ACCEPT_PDF"],
    "{{PAPER_ACCEPT_LOG}}": os.environ["PAPER_ACCEPT_LOG"],
    "{{PAPER_ACCEPT_AUX}}": os.environ["PAPER_ACCEPT_AUX"],
}

actions = []

for src in sorted(source.rglob("*")):
    if src.is_dir():
        continue

    rel = src.relative_to(source).as_posix()
    if only_paths and rel not in only_paths:
        continue

    is_template = rel.endswith(".template")
    dst_rel = rel[:-9] if is_template else rel
    dst = target / dst_rel

    if rel in stateful_templates and dst.exists() and not include_state:
        actions.append(("skip-state", dst_rel))
        continue

    if rel in config_templates and dst.exists() and not include_config:
        actions.append(("skip-config", dst_rel))
        continue

    if dst.exists() and not force:
        actions.append(("skip-existing", dst_rel))
        continue

    if rel in stateful_templates and dst.exists() and force and not include_state:
        actions.append(("skip-state", dst_rel))
        continue

    if rel in config_templates and dst.exists() and force and not include_config:
        actions.append(("skip-config", dst_rel))
        continue

    actions.append(("write", dst_rel))
    if dry_run:
        continue

    dst.parent.mkdir(parents=True, exist_ok=True)
    if is_template:
        content = src.read_text(encoding="utf-8")
        for old, new in replacements.items():
            content = content.replace(old, new)
        dst.write_text(content, encoding="utf-8")
    else:
        shutil.copyfile(src, dst)

for action, rel in actions:
    print(f"{action}: {rel}")
PY
