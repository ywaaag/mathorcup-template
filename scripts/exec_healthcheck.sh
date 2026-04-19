#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
MODEL=""
KEEP_ARTIFACTS=false

usage() {
    cat <<'EOF'
Usage: bash scripts/exec_healthcheck.sh [--target <dir>] [--model <model>] [--keep-artifacts]

Runs one minimal non-interactive `codex exec` probe and reports whether exec worker mode is usable.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --keep-artifacts)
            KEEP_ARTIFACTS=true
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

require_cmd codex

if ! codex exec --help >/dev/null 2>&1; then
    die "codex exec subcommand is unavailable in the current CLI"
fi

tmpdir="$(mktemp -d)"
last_message="$tmpdir/last_message.txt"
exec_log="$tmpdir/exec.log"
probe_prompt="$tmpdir/probe_prompt.txt"
printf 'Reply with exactly: EXEC_HEALTHCHECK_OK\n' > "$probe_prompt"
health_ok=false

cleanup() {
    if [[ "$KEEP_ARTIFACTS" == false && "$health_ok" == true ]]; then
        rm -rf "$tmpdir"
    fi
}
trap cleanup EXIT

exec_args=(exec --skip-git-repo-check -C "$TARGET_DIR" -o "$last_message")
[[ -n "$MODEL" ]] && exec_args+=(-m "$MODEL")
exec_args+=(--ephemeral -)

set +e
codex "${exec_args[@]}" < "$probe_prompt" > "$exec_log" 2>&1
exit_code=$?
set -e

classify_failure() {
    local log_file="$1"
    if grep -Eiq 'unknown option|unexpected argument|Usage:' "$log_file"; then
        echo "cli-argument-error"
    elif grep -Eiq 'model|provider|auth|api|quota|rate limit|401|403|429|login' "$log_file"; then
        echo "provider-or-auth-error"
    else
        echo "exec-run-error"
    fi
}

if [[ $exit_code -ne 0 ]]; then
    category="$(classify_failure "$exec_log")"
    echo "[exec_healthcheck] FAIL"
    echo "target: $TARGET_DIR"
    [[ -n "$MODEL" ]] && echo "model: $MODEL"
    echo "category: $category"
    echo "exit_code: $exit_code"
    echo "exec_log: $exec_log"
    echo "hint: run \`codex exec --help\` first if this looks like a CLI-argument issue; otherwise treat it as exec backend/provider not ready."
    exit 1
fi

if [[ ! -f "$last_message" ]]; then
    echo "[exec_healthcheck] FAIL"
    echo "target: $TARGET_DIR"
    echo "category: exec-output-missing"
    echo "reason: codex exec returned success but did not write the last-message file"
    exit 1
fi

message="$(tr -d '\r' < "$last_message" | sed -e 's/[[:space:]]*$//')"
if [[ "$message" != "EXEC_HEALTHCHECK_OK" ]]; then
    echo "[exec_healthcheck] FAIL"
    echo "target: $TARGET_DIR"
    [[ -n "$MODEL" ]] && echo "model: $MODEL"
    echo "category: exec-output-mismatch"
    echo "last_message: $last_message"
    echo "received: $message"
    exit 1
fi

echo "[exec_healthcheck] OK"
echo "target: $TARGET_DIR"
[[ -n "$MODEL" ]] && echo "model: $MODEL"
echo "codex_exec: available"
echo "probe_reply: $message"
health_ok=true
if [[ "$KEEP_ARTIFACTS" == true ]]; then
    echo "artifact_dir: $tmpdir"
fi
