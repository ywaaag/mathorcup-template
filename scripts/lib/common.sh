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

instance_id_for_root() {
    local root_dir
    root_dir="$(abs_path "$1")"
    python3 - "$root_dir" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:8])
PY
}

container_slug() {
    python3 - "$1" <<'PY'
import re
import sys

value = re.sub(r"[^a-z0-9_.-]+", "-", sys.argv[1].lower()).strip("-_.")
print((value or "mathorcup")[:40])
PY
}

default_container_name() {
    local competition_name="$1"
    local instance_id="$2"
    printf '%s-%s-dev\n' "$(container_slug "$competition_name")" "$instance_id"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

workflow_root_kind() {
    local scripts_dir="$1"
    local target_dir="$2"
    python3 "$scripts_dir/lib/workflow_state.py" root-kind --root "$target_dir"
}

workflow_run_with_lock() {
    local scripts_dir="$1"
    local target_dir="$2"
    shift 2

    if [[ "${WORKFLOW_LOCK_HELD:-}" == "1" ]]; then
        "$@"
        return
    fi

    require_cmd flock

    local root_kind
    root_kind="$(workflow_root_kind "$scripts_dir" "$target_dir")"
    if [[ "$root_kind" != "instance" ]]; then
        die "workflow write lock requires a rendered instance root: $target_dir"
    fi

    local runtime_dir="$target_dir/project/runtime"
    if [[ ! -d "$runtime_dir" ]]; then
        die "workflow write lock missing runtime directory: $runtime_dir"
    fi

    local lock_file="$runtime_dir/.workflow.lock"
    (
        flock -x 200 || die "failed to acquire workflow write lock: $lock_file"
        WORKFLOW_LOCK_HELD=1 "$@"
    ) 200>"$lock_file"
}

workflow_post_change_consistency() {
    local scripts_dir="$1"
    local target_dir="$2"

    if [[ "$(workflow_root_kind "$scripts_dir" "$target_dir")" != "instance" ]]; then
        return 0
    fi

    local output_file
    output_file="$(mktemp)"
    set +e
    bash "$scripts_dir/check_state_consistency.sh" --target "$target_dir" > "$output_file" 2>&1
    local exit_code=$?
    set -e
    if [[ "$exit_code" -ne 0 ]]; then
        echo "[workflow] post-change consistency check failed for $target_dir" >&2
        cat "$output_file" >&2
        rm -f "$output_file"
        return "$exit_code"
    fi
    rm -f "$output_file"
}

workflow_task_field() {
    local scripts_dir="$1"
    local target_dir="$2"
    local task_id="$3"
    local field="$4"
    python3 "$scripts_dir/lib/workflow_state.py" task-field --root "$target_dir" --task "$task_id" --field "$field"
}

_emit_workflow_event_unlocked() {
    local scripts_dir="$1"
    local target_dir="$2"
    shift 2

    local event_id
    event_id="$(python3 "$scripts_dir/lib/workflow_events.py" emit --root "$target_dir" "$@")"
    bash "$scripts_dir/process_callbacks.sh" --target "$target_dir" --event-id "$event_id" >/dev/null
    printf '%s\n' "$event_id"
}

_emit_workflow_event_and_check() {
    local scripts_dir="$1"
    local target_dir="$2"
    shift 2

    _emit_workflow_event_unlocked "$scripts_dir" "$target_dir" "$@"
    workflow_post_change_consistency "$scripts_dir" "$target_dir"
}

emit_workflow_event() {
    local scripts_dir="$1"
    local target_dir="$2"
    shift 2

    if [[ "${WORKFLOW_LOCK_HELD:-}" == "1" ]]; then
        _emit_workflow_event_unlocked "$scripts_dir" "$target_dir" "$@"
    else
        workflow_run_with_lock "$scripts_dir" "$target_dir" _emit_workflow_event_and_check "$scripts_dir" "$target_dir" "$@"
    fi
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
    : "${INSTANCE_ID:=$(instance_id_for_root "$HOST_DIR")}"
    : "${CONTAINER_NAME:=$(default_container_name "$COMPETITION_NAME" "$INSTANCE_ID")}"
    : "${JUPYTER_PORT:=8888}"
    : "${RSTUDIO_PORT:=8787}"
    : "${JUPYTER_PORT_MODE:=fixed}"
    : "${RSTUDIO_PORT_MODE:=fixed}"
    : "${JUPYTER_TOKEN:=mathorcup}"
    : "${CONTAINER_RUNTIME:=nvidia}"
    : "${CONTAINER_GPUS:=all}"
    : "${CONTAINER_PRIVILEGED:=true}"
    : "${CONTAINER_USER:=root}"
    : "${CONTAINER_GRANT_SUDO:=yes}"
    : "${PROJECT_CONTAINER_DIR:=/workspace/mathorcup}"
    : "${HOST_PROJECT_DIR:=$HOST_DIR/project}"

    export HOST_DIR IMAGE_NAME COMPETITION_NAME INSTANCE_ID CONTAINER_NAME
    export JUPYTER_PORT RSTUDIO_PORT JUPYTER_PORT_MODE RSTUDIO_PORT_MODE JUPYTER_TOKEN
    export CONTAINER_RUNTIME CONTAINER_GPUS CONTAINER_PRIVILEGED
    export CONTAINER_USER CONTAINER_GRANT_SUDO
    export PROJECT_CONTAINER_DIR HOST_PROJECT_DIR
}

validate_port_mode() {
    local name="$1"
    local mode="$2"
    case "$mode" in
        auto|fixed) ;;
        *) die "$name must be auto or fixed, got: $mode" ;;
    esac
}

update_env_values() {
    local env_file="$1"
    shift
    [[ -f "$env_file" ]] || die "runtime config not found: $env_file"
    (( $# % 2 == 0 )) || die "update_env_values requires KEY VALUE pairs"
    python3 - "$env_file" "$@" <<'PY'
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
pairs = dict(zip(sys.argv[2::2], sys.argv[3::2]))
lines = path.read_text(encoding="utf-8").splitlines()
seen = set()
output = []
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else ""
    if key in pairs:
        output.append(f"{key}={pairs[key]}")
        seen.add(key)
    else:
        output.append(line)
for key, value in pairs.items():
    if key not in seen:
        output.append(f"{key}={value}")

fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(output) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp_name, path.stat().st_mode)
    os.replace(temp_name, path)
finally:
    if os.path.exists(temp_name):
        os.unlink(temp_name)
PY
}

validate_tcp_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || die "invalid TCP port: $port"
    (( port >= 1 && port <= 65535 )) || die "TCP port out of range: $port"
}

port_available() {
    local port="$1"
    validate_tcp_port "$port"
    python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])

checks = [
    (socket.AF_INET, ("0.0.0.0", port)),
    (socket.AF_INET, ("127.0.0.1", port)),
]

if socket.has_ipv6:
    checks.append((socket.AF_INET6, ("::", port)))

for family, address in checks:
    sock = socket.socket(family, socket.SOCK_STREAM)
    try:
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind(address)
    except OSError:
        sys.exit(1)
    finally:
        sock.close()
sys.exit(0)
PY
}

find_available_port() {
    local start_port="$1"
    local avoid_csv="${2:-}"
    validate_tcp_port "$start_port"
    python3 - "$start_port" "$avoid_csv" <<'PY'
import socket
import sys

start = int(sys.argv[1])
avoid = {int(item) for item in sys.argv[2].split(",") if item.strip()}

def available(port: int) -> bool:
    checks = [
        (socket.AF_INET, ("0.0.0.0", port)),
        (socket.AF_INET, ("127.0.0.1", port)),
    ]
    if socket.has_ipv6:
        checks.append((socket.AF_INET6, ("::", port)))
    for family, address in checks:
        sock = socket.socket(family, socket.SOCK_STREAM)
        try:
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.bind(address)
        except OSError:
            return False
        finally:
            sock.close()
    return True

for port in range(start, 65536):
    if port in avoid:
        continue
    if available(port):
        print(port)
        sys.exit(0)

print(f"no available TCP port found at or above {start}", file=sys.stderr)
sys.exit(1)
PY
}

port_usage_report() {
    local port="$1"
    validate_tcp_port "$port"
    echo "port: $port"
    if command -v ss >/dev/null 2>&1; then
        local ss_output
        ss_output="$(ss -H -ltnp "( sport = :$port )" 2>/dev/null || true)"
        if [[ -n "$ss_output" ]]; then
            echo "ss:"
            echo "$ss_output"
        else
            echo "ss: no listener details visible"
        fi
    fi
    if command -v docker >/dev/null 2>&1; then
        local docker_output
        docker_output="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -F ":$port->" || true)"
        if [[ -n "$docker_output" ]]; then
            echo "docker:"
            echo "$docker_output"
        fi
    fi
}

preflight_host_ports() {
    local target_dir="$1"
    validate_tcp_port "$JUPYTER_PORT"
    validate_tcp_port "$RSTUDIO_PORT"
    if [[ "$JUPYTER_PORT" == "$RSTUDIO_PORT" ]]; then
        die "JUPYTER_PORT and RSTUDIO_PORT must be different; both are $JUPYTER_PORT"
    fi

    local spec env_name host_port container_port
    for spec in "JUPYTER_PORT:$JUPYTER_PORT:8888" "RSTUDIO_PORT:$RSTUDIO_PORT:8787"; do
        IFS=: read -r env_name host_port container_port <<< "$spec"
        if ! port_available "$host_port"; then
            status_err "$env_name=$host_port is already occupied before Docker startup." >&2
            port_usage_report "$host_port" >&2
            {
                echo "hint: choose a free host port, then either edit $target_dir/.env or run with an explicit override."
                echo "hint: example: JUPYTER_PORT=18888 RSTUDIO_PORT=18787 bash scripts/bootstrap_container.sh --target \"$target_dir\""
                echo "hint: container-side port remains $container_port; only the host port changes."
            } >&2
            exit 1
        fi
    done
}

allocate_host_ports() {
    local target_dir="$1"
    local env_file="$target_dir/.env"
    validate_tcp_port "$JUPYTER_PORT"
    validate_tcp_port "$RSTUDIO_PORT"
    validate_port_mode JUPYTER_PORT_MODE "$JUPYTER_PORT_MODE"
    validate_port_mode RSTUDIO_PORT_MODE "$RSTUDIO_PORT_MODE"

    PORTS_CHANGED=false
    local old_jupyter="$JUPYTER_PORT"
    local old_rstudio="$RSTUDIO_PORT"
    if ! port_available "$JUPYTER_PORT"; then
        if [[ "$JUPYTER_PORT_MODE" == "fixed" ]]; then
            preflight_host_ports "$target_dir"
        fi
        JUPYTER_PORT="$(find_available_port "$JUPYTER_PORT" "$RSTUDIO_PORT")"
        status_info "auto-selected JUPYTER_PORT=$JUPYTER_PORT because $old_jupyter is occupied"
    fi
    if [[ "$RSTUDIO_PORT" == "$JUPYTER_PORT" ]] || ! port_available "$RSTUDIO_PORT"; then
        if [[ "$RSTUDIO_PORT_MODE" == "fixed" ]]; then
            preflight_host_ports "$target_dir"
        fi
        RSTUDIO_PORT="$(find_available_port "$RSTUDIO_PORT" "$JUPYTER_PORT")"
        status_info "auto-selected RSTUDIO_PORT=$RSTUDIO_PORT because $old_rstudio is occupied or reserved"
    fi

    if [[ "$JUPYTER_PORT" != "$old_jupyter" || "$RSTUDIO_PORT" != "$old_rstudio" ]]; then
        update_env_values "$env_file" JUPYTER_PORT "$JUPYTER_PORT" RSTUDIO_PORT "$RSTUDIO_PORT"
        export JUPYTER_PORT RSTUDIO_PORT
        status_ok "updated auto-managed host ports in $env_file"
        PORTS_CHANGED=true
    fi
    export PORTS_CHANGED
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

container_label_value() {
    local label="$1"
    docker inspect --format "{{ index .Config.Labels \"$label\" }}" "$CONTAINER_NAME" 2>/dev/null || true
}

container_mount_source() {
    docker inspect --format "{{ range .Mounts }}{{ if eq .Destination \"$PROJECT_CONTAINER_DIR\" }}{{ .Source }}{{ end }}{{ end }}" "$CONTAINER_NAME" 2>/dev/null || true
}

container_host_port() {
    local container_port="$1"
    docker inspect --format "{{ with (index .HostConfig.PortBindings \"${container_port}/tcp\") }}{{ (index . 0).HostPort }}{{ end }}" "$CONTAINER_NAME" 2>/dev/null || true
}

verify_container_port_bindings() {
    local actual_jupyter actual_rstudio
    actual_jupyter="$(container_host_port 8888)"
    actual_rstudio="$(container_host_port 8787)"
    if [[ "$actual_jupyter" == "$JUPYTER_PORT" && "$actual_rstudio" == "$RSTUDIO_PORT" ]]; then
        return 0
    fi
    status_err "container port bindings do not match .env for $CONTAINER_NAME" >&2
    echo "expected Jupyter/RStudio: $JUPYTER_PORT | $RSTUDIO_PORT" >&2
    echo "actual Jupyter/RStudio:   ${actual_jupyter:-<missing>} | ${actual_rstudio:-<missing>}" >&2
    return 1
}

verify_container_ownership() {
    local expected_root expected_project label_instance label_root mount_source
    expected_root="$(abs_path "$HOST_DIR")"
    expected_project="$(abs_path "$HOST_PROJECT_DIR")"
    label_instance="$(container_label_value io.mathorcup.instance.id)"
    label_root="$(container_label_value io.mathorcup.instance.root)"
    mount_source="$(container_mount_source)"
    [[ -n "$mount_source" ]] && mount_source="$(abs_path "$mount_source")"

    if [[ -n "$label_instance" || -n "$label_root" ]]; then
        if [[ "$label_instance" == "$INSTANCE_ID" && "$label_root" == "$expected_root" && "$mount_source" == "$expected_project" ]]; then
            return 0
        fi
        status_err "container name collision: $CONTAINER_NAME belongs to another instance" >&2
        echo "expected instance/root/mount: $INSTANCE_ID | $expected_root | $expected_project" >&2
        echo "actual instance/root/mount:   ${label_instance:-<missing>} | ${label_root:-<missing>} | ${mount_source:-<missing>}" >&2
        return 1
    fi

    if [[ "$mount_source" == "$expected_project" ]]; then
        status_warn "legacy container $CONTAINER_NAME has no instance labels; accepting its matching project mount"
        return 0
    fi
    status_err "legacy container name collision: $CONTAINER_NAME is mounted from another project" >&2
    echo "expected mount: $expected_project" >&2
    echo "actual mount:   ${mount_source:-<missing>}" >&2
    return 1
}
