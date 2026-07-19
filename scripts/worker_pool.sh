#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
ARGS=()

usage() {
    cat <<'EOF'
Usage: bash scripts/worker_pool.sh <command> [options] [--target <dir>]

Commands:
  status [--json]
  register --worker-key <role:name> --role <role> --backend <native_subagent|codex_exec> --session-id <id>
  select --role <role> [--backend <backend>] [--json]
  check-worker --worker-key <key> [--role <role>] [--session-id <id>]
  check-assignment --worker-key <key> --task <task_id> [--session-id <id>]
  assign --worker-key <key> --task <task_id> [--session-id <id>]
  mark-idle --worker-key <key> [--task <task_id>]
  mark-stale --worker-key <key> --reason <text> [--force]
  close --worker-key <key> --reason <text> [--force]
  close-all --reason <text> [--force]

This script manages session routing only. It cannot spawn, steer, resume, or close
native Codex sub-agents; the interactive main brain performs those native actions.
EOF
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

python3 "$SCRIPT_DIR/lib/worker_pool.py" --root "$TARGET_DIR" "${ARGS[@]}"
