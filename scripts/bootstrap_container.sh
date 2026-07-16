#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
RECREATE=false
JUPYTER_PORT_WAS_SET=false
RSTUDIO_PORT_WAS_SET=false
[[ -n "${JUPYTER_PORT+x}" ]] && JUPYTER_PORT_WAS_SET=true
[[ -n "${RSTUDIO_PORT+x}" ]] && RSTUDIO_PORT_WAS_SET=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --recreate)
            RECREATE=true
            shift
            ;;
        -h|--help)
            echo "Usage: bash scripts/bootstrap_container.sh [--target <dir>] [--recreate]"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

require_cmd docker
require_cmd flock
load_root_env "$TARGET_DIR"
mkdir -p "$HOST_PROJECT_DIR"

if [[ "$JUPYTER_PORT_WAS_SET" == true ]]; then
    JUPYTER_PORT_MODE="fixed"
    update_env_values "$TARGET_DIR/.env" JUPYTER_PORT "$JUPYTER_PORT" JUPYTER_PORT_MODE fixed
fi
if [[ "$RSTUDIO_PORT_WAS_SET" == true ]]; then
    RSTUDIO_PORT_MODE="fixed"
    update_env_values "$TARGET_DIR/.env" RSTUDIO_PORT "$RSTUDIO_PORT" RSTUDIO_PORT_MODE fixed
fi
export JUPYTER_PORT_MODE RSTUDIO_PORT_MODE

print_runtime_config() {
    status_info "instance: $INSTANCE_ID"
    status_info "container: $CONTAINER_NAME"
    status_info "image: $IMAGE_NAME"
    status_info "host project dir: $HOST_PROJECT_DIR"
    status_info "jupyter host port: $JUPYTER_PORT ($JUPYTER_PORT_MODE) -> 8888"
    status_info "rstudio host port: $RSTUDIO_PORT ($RSTUDIO_PORT_MODE) -> 8787"
    status_info "runtime: ${CONTAINER_RUNTIME:-default}"
    status_info "gpus: ${CONTAINER_GPUS:-none}"
    status_info "privileged: $CONTAINER_PRIVILEGED"
    status_info "user: ${CONTAINER_USER:-<image default>}"
    status_info "grant sudo: ${CONTAINER_GRANT_SUDO:-<image default>}"
}

docker_run_once() {
    local error_file="$1"
    local run_args=(
        -d
        --name "$CONTAINER_NAME"
        --label "io.mathorcup.instance.id=$INSTANCE_ID"
        --label "io.mathorcup.instance.root=$(abs_path "$HOST_DIR")"
        --label "io.mathorcup.instance.project=$(abs_path "$HOST_PROJECT_DIR")"
        --label "io.mathorcup.competition=$COMPETITION_NAME"
        -p "$JUPYTER_PORT:8888"
        -p "$RSTUDIO_PORT:8787"
        --mount "type=bind,src=$(abs_path "$HOST_PROJECT_DIR"),dst=$PROJECT_CONTAINER_DIR"
        -e JUPYTER_TOKEN="$JUPYTER_TOKEN"
        -e GRANT_SUDO="$CONTAINER_GRANT_SUDO"
        --restart unless-stopped
    )

    if [[ -n "$CONTAINER_GPUS" && "$CONTAINER_GPUS" != "none" ]]; then
        run_args+=(--gpus "$CONTAINER_GPUS" -e NVIDIA_VISIBLE_DEVICES="$CONTAINER_GPUS")
    fi
    if [[ -n "$CONTAINER_RUNTIME" && "$CONTAINER_RUNTIME" != "default" ]]; then
        run_args+=(--runtime="$CONTAINER_RUNTIME")
    fi
    [[ "$CONTAINER_PRIVILEGED" == "true" ]] && run_args+=(--privileged)
    [[ -n "$CONTAINER_USER" ]] && run_args+=(--user "$CONTAINER_USER")

    docker run "${run_args[@]}" "$IMAGE_NAME" \
        /usr/bin/env bash -lc "while true; do sleep 86400; done" \
        >/dev/null 2>"$error_file"
}

bootstrap_locked() {
    docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 || die "image not found: $IMAGE_NAME"

    if container_exists; then
        verify_container_ownership || die "refusing to reuse or remove a container owned by another instance"
        if [[ "$RECREATE" != "true" ]]; then
            verify_container_port_bindings || die "rerun with --recreate to apply the .env port bindings to this instance's container"
        fi
    fi

    if container_exists && [[ "$RECREATE" == true ]]; then
        status_info "removing existing container $CONTAINER_NAME"
        docker rm -f "$CONTAINER_NAME" >/dev/null
    fi

    if container_running; then
        print_runtime_config
        status_skip "container already exists and is running"
        return 0
    fi

    allocate_host_ports "$TARGET_DIR"
    if container_exists && [[ "$PORTS_CHANGED" == true ]]; then
        status_warn "auto-managed ports changed; recreating the stopped container with the new bindings"
        docker rm "$CONTAINER_NAME" >/dev/null
    fi

    print_runtime_config
    if container_exists; then
        docker start "$CONTAINER_NAME" >/dev/null
        status_ok "container running"
        return 0
    fi

    local attempt error_file
    error_file="$(mktemp)"
    trap 'rm -f "$error_file"' RETURN
    for attempt in 1 2 3; do
        status_info "creating container $CONTAINER_NAME"
        if docker_run_once "$error_file"; then
            status_ok "container created"
            status_ok "container running"
            return 0
        fi

        if ! grep -Eqi 'port is already allocated|address already in use|bind.*failed' "$error_file"; then
            cat "$error_file" >&2
            die "docker run failed"
        fi
        if [[ "$JUPYTER_PORT_MODE" != "auto" && "$RSTUDIO_PORT_MODE" != "auto" ]]; then
            cat "$error_file" >&2
            die "docker port allocation failed for fixed host ports"
        fi

        status_warn "host port was claimed during container creation; retrying with fresh auto-managed ports ($attempt/3)"
        if container_exists; then
            verify_container_ownership || die "failed container identity changed during retry"
            docker rm -f "$CONTAINER_NAME" >/dev/null
        fi
        allocate_host_ports "$TARGET_DIR"
        : >"$error_file"
    done
    cat "$error_file" >&2
    die "docker run failed after 3 port-allocation attempts"
}

lock_file="${XDG_RUNTIME_DIR:-/tmp}/mathorcup-bootstrap-${UID}.lock"
(
    flock -x 200 || die "failed to acquire bootstrap allocation lock: $lock_file"
    bootstrap_locked
) 200>"$lock_file"
