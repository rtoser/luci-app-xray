#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  build-openwrt-sdk-docker.sh [docker-wrapper-options] [build-options]

Docker wrapper options:
  --cache-dir <path>   Host cache root (default: ~/.cache/luci-app-xray)
  --output-dir <path>  Host output directory for generated packages
  --image <image>      Container image (default: ubuntu:24.04)
  --platform <value>   Docker platform (default: linux/amd64)
  --pull               Pull container image before build
  --help               Show this help

Build options:
  All remaining arguments are passed to build-openwrt-sdk-local.sh.
  Common examples:
    --openwrt-version 25.12.1
    --refresh-sdk
    --refresh-feeds
    --jobs 8

Examples:
  ./scripts/build-openwrt-sdk-docker.sh
  ./scripts/build-openwrt-sdk-docker.sh --refresh-feeds
  ./scripts/build-openwrt-sdk-docker.sh --cache-dir "$HOME/.cache/luci-app-xray" --output-dir "$PWD/dist"
EOF
}

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

strip_host_xattrs() {
    if ! command -v xattr >/dev/null 2>&1; then
        return 0
    fi

    for path in "$REPO_ROOT/core" "$REPO_ROOT/status" "$REPO_ROOT/geodata"; do
        [ -e "$path" ] || continue
        xattr -cr "$path" 2>/dev/null || true
    done
}

abs_path() {
    local path
    path="$1"
    mkdir -p "$path"
    CDPATH= cd -- "$path" && pwd
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"

CACHE_ROOT="${OPENWRT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/luci-app-xray}"
OUTPUT_HOST_DIR=""
CONTAINER_IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
PULL_IMAGE=0
INNER_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache-dir)
            [[ $# -ge 2 ]] || die "--cache-dir requires a value"
            CACHE_ROOT="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || die "--output-dir requires a value"
            OUTPUT_HOST_DIR="$2"
            shift 2
            ;;
        --image)
            [[ $# -ge 2 ]] || die "--image requires a value"
            CONTAINER_IMAGE="$2"
            shift 2
            ;;
        --platform)
            [[ $# -ge 2 ]] || die "--platform requires a value"
            DOCKER_PLATFORM="$2"
            shift 2
            ;;
        --pull)
            PULL_IMAGE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            INNER_ARGS+=("$1")
            shift
            ;;
    esac
done

need_cmd docker
docker info >/dev/null 2>&1 || die "docker daemon is not running"
strip_host_xattrs

CACHE_ROOT="$(abs_path "$CACHE_ROOT")"
APT_CACHE_DIR="$(abs_path "${CACHE_ROOT}/docker/apt/cache")"
APT_LISTS_DIR="$(abs_path "${CACHE_ROOT}/docker/apt/lists")"

OUTPUT_DIR_IN_CONTAINER=""
if [[ -n "$OUTPUT_HOST_DIR" ]]; then
    OUTPUT_HOST_DIR="$(abs_path "$OUTPUT_HOST_DIR")"
    OUTPUT_DIR_IN_CONTAINER="/output"
fi

if [[ "$PULL_IMAGE" -eq 1 ]]; then
    log "Pulling image: ${CONTAINER_IMAGE}"
    docker pull --platform "$DOCKER_PLATFORM" "$CONTAINER_IMAGE"
fi

log "Using host cache: $CACHE_ROOT"
if [[ -n "$OUTPUT_HOST_DIR" ]]; then
    log "Using host output: $OUTPUT_HOST_DIR"
fi

DOCKER_CMD=(docker run --rm)

if [[ -t 0 && -t 1 ]]; then
    DOCKER_CMD+=(-it)
fi

DOCKER_CMD+=(
    --platform "$DOCKER_PLATFORM"
    -v "${REPO_ROOT}:/work"
    -v "${CACHE_ROOT}:/cache"
    -v "${APT_CACHE_DIR}:/var/cache/apt"
    -v "${APT_LISTS_DIR}:/var/lib/apt/lists"
)

if [[ -n "$OUTPUT_HOST_DIR" ]]; then
    DOCKER_CMD+=(-v "${OUTPUT_HOST_DIR}:/output")
fi

DOCKER_CMD+=(
    -w /work
    -e OUTPUT_DIR_IN_CONTAINER="$OUTPUT_DIR_IN_CONTAINER"
    "$CONTAINER_IMAGE"
    bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# Replace APT sources with Chinese mirror (supports both legacy and DEB822 formats)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i "s|http://archive.ubuntu.com|http://mirrors.aliyun.com|g; s|http://security.ubuntu.com|http://mirrors.aliyun.com|g" /etc/apt/sources.list.d/ubuntu.sources
else
  sed -i "s|http://archive.ubuntu.com|http://mirrors.aliyun.com|g; s|http://security.ubuntu.com|http://mirrors.aliyun.com|g" /etc/apt/sources.list 2>/dev/null || true
fi
apt-get update
apt-get install -y build-essential ccache file gawk gettext git libncurses-dev p7zip-full python3 rsync unzip wget xsltproc zstd

cmd=(/work/scripts/build-openwrt-sdk-local.sh --cache-dir /cache)
if [[ -n "${OUTPUT_DIR_IN_CONTAINER:-}" ]]; then
    cmd+=(--output-dir "$OUTPUT_DIR_IN_CONTAINER")
fi
cmd+=("$@")
"${cmd[@]}"
' bash
)

if [[ "${#INNER_ARGS[@]}" -gt 0 ]]; then
    DOCKER_CMD+=("${INNER_ARGS[@]}")
fi

"${DOCKER_CMD[@]}"
