#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

CONTAINER_NAME="mathorcup_v1-dev"
IMAGE_NAME="mathorcup-runtime:$(date +%Y%m%d)"
TAG_LATEST=false
CHECK_ONLY=false
SKIP_INSTALL=false

usage() {
    cat <<'EOF'
Usage: bash scripts/export_reference_image.sh [options]

Options:
  --container <name>   Source container to inspect and export
  --image <repo:tag>   Output image tag
  --tag-latest         Also tag <repo>:latest
  --check-only         Only inspect baseline; exit non-zero if missing tools remain
  --skip-install       Do not install missing packages before export
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --image)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --tag-latest)
            TAG_LATEST=true
            shift
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --skip-install)
            SKIP_INSTALL=true
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

require_cmd docker

container_running_name() {
    docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -Fx "$CONTAINER_NAME" >/dev/null 2>&1
}

container_exec() {
    docker exec -u 0 "$CONTAINER_NAME" bash -euo pipefail -c "$1"
}

check_report() {
    container_exec '
check_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "OK %s %s\n" "$cmd" "$(command -v "$cmd")"
    else
        printf "MISS %s\n" "$cmd"
    fi
}

check_cmd biber
check_cmd tree
check_cmd yq

if command -v fd >/dev/null 2>&1; then
    printf "OK fd %s\n" "$(command -v fd)"
elif command -v fdfind >/dev/null 2>&1; then
    printf "WARN fd %s\n" "$(command -v fdfind)"
else
    printf "MISS fd\n"
fi

for cmd in python3 pip latexmk xelatex pandoc R rg jq tmux rsync nvidia-smi; do
    check_cmd "$cmd"
done
'
}

missing_required() {
    local report="$1"
    while IFS= read -r line; do
        case "$line" in
            "MISS biber"|\
            "MISS tree"|\
            "MISS yq"|\
            "MISS fd"|\
            "WARN fd "*)
                return 0
                ;;
        esac
    done <<< "$report"
    return 1
}

install_baseline() {
    status_info "installing thick reference image baseline into $CONTAINER_NAME"
    source_fix="$(container_exec '
os_codename="$(
    . /etc/os-release
    printf "%s" "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
)"
ubuntu_codename="$(awk '\''/^deb / && $2 ~ /ubuntu/ {print $3; exit}'\'' /etc/apt/sources.list 2>/dev/null || true)"
if [[ -n "$os_codename" && -n "$ubuntu_codename" && "$ubuntu_codename" != "$os_codename" ]]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.reference-image.bak
    sed -i "s/${ubuntu_codename}/${os_codename}/g" /etc/apt/sources.list
    printf "UPDATED %s %s\n" "$ubuntu_codename" "$os_codename"
else
    printf "UNCHANGED %s\n" "${ubuntu_codename:-unknown}"
fi
')"
    case "$source_fix" in
        UPDATED\ *)
            status_warn "normalized Ubuntu apt sources: ${source_fix#UPDATED }"
            ;;
        *)
            status_ok "Ubuntu apt sources already match container codename"
            ;;
    esac
    container_exec '
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get -y --fix-broken install >/dev/null
apt-get install -y --no-install-recommends biber fd-find tree >/dev/null
if ! command -v yq >/dev/null 2>&1; then
    python3 -m pip install --no-cache-dir --root-user-action=ignore yq >/dev/null
fi
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd
fi
apt-get clean >/dev/null
rm -rf /var/lib/apt/lists/*
'
    status_ok "reference baseline packages installed"
}

print_report() {
    local report="$1"
    while IFS= read -r line; do
        case "$line" in
            "OK "*)
                status_ok "${line#OK }"
                ;;
            "WARN "*)
                status_warn "${line#WARN }"
                ;;
            "MISS "*)
                status_warn "${line#MISS } missing"
                ;;
        esac
    done <<< "$report"
}

if ! container_running_name; then
    die "container is not running: $CONTAINER_NAME"
fi

status_info "reference container: $CONTAINER_NAME"
status_info "target image: $IMAGE_NAME"

report="$(check_report)"
echo "== Baseline Check =="
print_report "$report"

if missing_required "$report"; then
    if [[ "$CHECK_ONLY" == true ]]; then
        die "reference image baseline is incomplete"
    fi
    if [[ "$SKIP_INSTALL" == true ]]; then
        die "missing required baseline tools and --skip-install was set"
    fi
    install_baseline
    report="$(check_report)"
    echo ""
    echo "== Baseline Check After Install =="
    print_report "$report"
    missing_required "$report" && die "reference image baseline is still incomplete after install"
fi

if [[ "$CHECK_ONLY" == true ]]; then
    status_ok "reference image baseline complete"
    exit 0
fi

status_info "committing $CONTAINER_NAME to $IMAGE_NAME"
docker commit -a "Codex" -m "Refresh thick reference runtime from $CONTAINER_NAME on $(date +%F)" "$CONTAINER_NAME" "$IMAGE_NAME" >/dev/null
status_ok "image exported"

if [[ "$TAG_LATEST" == true ]]; then
    repo="${IMAGE_NAME%%:*}"
    docker tag "$IMAGE_NAME" "$repo:latest"
    status_ok "tagged $repo:latest"
fi

docker image inspect "$IMAGE_NAME" --format 'image={{index .RepoTags 0}} id={{.Id}} size={{.Size}}'
