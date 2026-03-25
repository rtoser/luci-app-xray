#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage:
  build-openwrt-sdk-local.sh [options]

Options:
  --openwrt-version <version>  OpenWrt release version (default: 25.12.1)
  --target <target>            OpenWrt target (default: x86)
  --subtarget <subtarget>      OpenWrt subtarget (default: 64)
  --cache-dir <path>           Cache root directory
  --output-dir <path>          Directory for generated packages
  --jobs <n>                   Parallel make jobs
  --skip-clean                 Skip the package clean step and resume from cache
  --refresh-sdk                Re-extract SDK from cached archive
  --refresh-feeds              Clear cached feeds before update
  --help                       Show this help

Environment:
  OPENWRT_VERSION              Same as --openwrt-version
  OPENWRT_TARGET               Same as --target
  OPENWRT_SUBTARGET            Same as --subtarget
  OPENWRT_CACHE_DIR            Same as --cache-dir
  OUTPUT_DIR                   Same as --output-dir
  JOBS                         Same as --jobs

Examples:
  ./scripts/build-openwrt-sdk-local.sh
  ./scripts/build-openwrt-sdk-local.sh --cache-dir "$HOME/.cache/luci-app-xray"
  ./scripts/build-openwrt-sdk-local.sh --refresh-sdk --refresh-feeds
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

abs_path() {
    path="$1"
    mkdir -p "$path"
    CDPATH= cd -- "$path" && pwd
}

extract_makefile_block() {
    block_name="$1"
    awk -v block_name="$block_name" '
        $0 == "define " block_name { in_block = 1; next }
        in_block && $0 == "endef" { exit }
        in_block { print }
    ' "$REPO_ROOT/core/Makefile"
}

strip_xattrs_tree() {
    target_path="$1"
    [ -e "$target_path" ] || return 0
    python3 - "$target_path" <<'PY'
import os
import sys

root = sys.argv[1]

def strip(path):
    try:
        attrs = os.listxattr(path, follow_symlinks=False)
    except Exception:
        return
    for attr in attrs:
        try:
            os.removexattr(path, attr, follow_symlinks=False)
        except Exception:
            pass

strip(root)
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    strip(dirpath)
    for name in dirnames:
        strip(os.path.join(dirpath, name))
    for name in filenames:
        strip(os.path.join(dirpath, name))
PY
}

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.1}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-64}"
CACHE_ROOT="${OPENWRT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/luci-app-xray}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}"
REFRESH_SDK=0
REFRESH_FEEDS=0
SKIP_CLEAN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --openwrt-version)
            [ "$#" -ge 2 ] || die "--openwrt-version requires a value"
            OPENWRT_VERSION="$2"
            shift 2
            ;;
        --target)
            [ "$#" -ge 2 ] || die "--target requires a value"
            OPENWRT_TARGET="$2"
            shift 2
            ;;
        --subtarget)
            [ "$#" -ge 2 ] || die "--subtarget requires a value"
            OPENWRT_SUBTARGET="$2"
            shift 2
            ;;
        --cache-dir)
            [ "$#" -ge 2 ] || die "--cache-dir requires a value"
            CACHE_ROOT="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || die "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --jobs)
            [ "$#" -ge 2 ] || die "--jobs requires a value"
            JOBS="$2"
            shift 2
            ;;
        --skip-clean)
            SKIP_CLEAN=1
            shift
            ;;
        --refresh-sdk)
            REFRESH_SDK=1
            shift
            ;;
        --refresh-feeds)
            REFRESH_FEEDS=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

need_cmd wget
need_cmd tar
need_cmd sha256sum
need_cmd sed
need_cmd make
need_cmd find
need_cmd python3

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
CACHE_ROOT="$(abs_path "$CACHE_ROOT")"

SDK_KEY="${OPENWRT_VERSION}-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}"
SDK_URL_PATH="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
SDK_NAME="-sdk-${OPENWRT_VERSION}-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}_"
ARCHIVE_DIR="${CACHE_ROOT}/archives/${SDK_KEY}"
SDK_HOME="${CACHE_ROOT}/sdk/${SDK_KEY}"
DL_DIR="${CACHE_ROOT}/dl"
FEEDS_DIR="${CACHE_ROOT}/feeds/${SDK_KEY}"
CCACHE_DIR="${CACHE_ROOT}/ccache"
OUTPUT_DIR="${OUTPUT_DIR:-${CACHE_ROOT}/out/${SDK_KEY}}"

mkdir -p "$ARCHIVE_DIR" "$DL_DIR" "$CCACHE_DIR" "$OUTPUT_DIR"

log "Using cache root: $CACHE_ROOT"
log "OpenWrt SDK target: ${OPENWRT_VERSION} ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"

SHA256SUMS_PATH="${ARCHIVE_DIR}/sha256sums"
SHA256SUMS_SMALL_PATH="${ARCHIVE_DIR}/sha256sums.small"

log "Refreshing sha256sums metadata"
wget -q -O "${SHA256SUMS_PATH}.tmp" "${SDK_URL_PATH}/sha256sums"
mv "${SHA256SUMS_PATH}.tmp" "$SHA256SUMS_PATH"

grep -- "$SDK_NAME" "$SHA256SUMS_PATH" > "$SHA256SUMS_SMALL_PATH" || \
    die "cannot find SDK entry matching ${SDK_NAME} under ${SDK_URL_PATH}/sha256sums"

SDK_FILE="$(awk '{print $2}' "$SHA256SUMS_SMALL_PATH" | tr -d '*')"
[ -n "$SDK_FILE" ] || die "failed to resolve SDK archive name"

if ! (cd "$ARCHIVE_DIR" && sha256sum -c "sha256sums.small" >/dev/null 2>&1); then
    log "Downloading SDK archive: $SDK_FILE"
    rm -f "${ARCHIVE_DIR}/${SDK_FILE}"
    wget -q -O "${ARCHIVE_DIR}/${SDK_FILE}" "${SDK_URL_PATH}/${SDK_FILE}"
    (cd "$ARCHIVE_DIR" && sha256sum -c "sha256sums.small" >/dev/null 2>&1) || \
        die "downloaded SDK archive failed sha256 verification"
else
    log "Reusing cached SDK archive: $SDK_FILE"
fi

if [ "$REFRESH_SDK" -eq 1 ] || [ ! -x "${SDK_HOME}/scripts/feeds" ]; then
    log "Extracting SDK into: $SDK_HOME"
    rm -rf "$SDK_HOME"
    mkdir -p "$SDK_HOME"
    tar --zstd -xf "${ARCHIVE_DIR}/${SDK_FILE}" -C "$SDK_HOME" --strip=1
else
    log "Reusing extracted SDK: $SDK_HOME"
fi

if [ "$REFRESH_FEEDS" -eq 1 ]; then
    log "Clearing cached feeds: $FEEDS_DIR"
    rm -rf "$FEEDS_DIR"
fi

mkdir -p "$FEEDS_DIR"

cd "$SDK_HOME"
rm -rf dl feeds
ln -sfn "$DL_DIR" dl
ln -sfn "$FEEDS_DIR" feeds

# No feeds needed — luci-app-xray has no build-time dependencies
log "Skipping feeds (no build-time deps)"

# Copy package source (not symlink) so we can patch Makefile without touching the repo
rm -rf "package/luci-app-xray"
mkdir -p "package/luci-app-xray"
cp -a "$REPO_ROOT/core" "package/luci-app-xray/core"
strip_xattrs_tree "package/luci-app-xray/core"

# Save original DEPENDS, then clear it to prevent any dependency compilation.
# We inject deps back into the .apk metadata after the build.
ORIG_DEPENDS="$(sed -n 's/.*DEPENDS:=//p' "$REPO_ROOT/core/Makefile" | head -1)"
log "Original DEPENDS: $ORIG_DEPENDS"
sed -i 's/DEPENDS:=.*/DEPENDS:=/' "package/luci-app-xray/core/Makefile"

PKG_NAME="$(sed -n 's/^PKG_NAME:=//p' "$REPO_ROOT/core/Makefile" | head -1)"
PKG_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$REPO_ROOT/core/Makefile" | head -1)"
PKG_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$REPO_ROOT/core/Makefile" | head -1)"
PKG_LICENSE="$(sed -n 's/^PKG_LICENSE:=//p' "$REPO_ROOT/core/Makefile" | head -1)"
PKG_MAINTAINER="$(sed -n 's/^PKG_MAINTAINER:=//p' "$REPO_ROOT/core/Makefile" | head -1)"
PKG_DESCRIPTION="$(extract_makefile_block 'Package/$(PKG_NAME)/description' | head -1)"
PKG_CONFFILES="$(extract_makefile_block 'Package/$(PKG_NAME)/conffiles')"
PKG_POSTINST="$(extract_makefile_block 'Package/$(PKG_NAME)/postinst' | sed 's/\$\$/\$/g')"

export CCACHE_DIR
export CONFIG_CCACHE=y

log "Running make defconfig (no feeds needed)"
make defconfig

log "Stripping config to absolute minimum"
sed -i 's/^CONFIG_ALL_KMODS=.*/# CONFIG_ALL_KMODS is not set/' .config
sed -i 's/^CONFIG_ALL_NONSHARED=.*/# CONFIG_ALL_NONSHARED is not set/' .config
sed -i 's/^CONFIG_DEVEL=.*/# CONFIG_DEVEL is not set/' .config
make defconfig

log "Building package/luci-app-xray/core with ${JOBS} jobs"
if [ "$SKIP_CLEAN" -eq 0 ]; then
    make -j"$JOBS" package/luci-app-xray/core/clean V=s 2>&1 || true
fi
make -j"$JOBS" package/luci-app-xray/core/compile V=s

# Inject runtime DEPENDS back into the final APK by re-running apk mkpkg
# against the package staging directories created by OpenWrt.
log "Injecting runtime dependencies into APK with apk mkpkg"
CLEAN_DEPS="$(echo "$ORIG_DEPENDS" | sed 's/+//g; s/^ *//; s/ *$//')"
APK_DEPENDS="libc$(if [ -n "$CLEAN_DEPS" ]; then printf ' %s' "$CLEAN_DEPS"; fi)"
PKG_BUILD_DIR="$(find "${SDK_HOME}/build_dir" -type d -name "${PKG_NAME}-${PKG_VERSION}" | head -1)"
APK_OUTPUT="$(find "${SDK_HOME}/bin/" -type f -name "${PKG_NAME}*.apk" | head -1)"
APK_TOOL="${SDK_HOME}/staging_dir/host/bin/apk"
FAKEROOT_TOOL="${SDK_HOME}/staging_dir/host/bin/fakeroot"
MKHASH_TOOL="${SDK_HOME}/staging_dir/host/bin/mkhash"

if [ -n "${APK_OUTPUT}" ]; then
    [ -n "${PKG_BUILD_DIR}" ] || die "failed to locate package build directory for ${PKG_NAME}"
    [ -x "${APK_TOOL}" ] || die "missing apk tool: ${APK_TOOL}"
    [ -x "${MKHASH_TOOL}" ] || die "missing mkhash tool: ${MKHASH_TOOL}"
    [ -d "${PKG_BUILD_DIR}/.pkgdir/${PKG_NAME}" ] || die "missing package payload dir: ${PKG_BUILD_DIR}/.pkgdir/${PKG_NAME}"

    if [ "$(id -u)" -eq 0 ]; then
        set -- "${APK_TOOL}" mkpkg
    else
        [ -x "${FAKEROOT_TOOL}" ] || die "missing fakeroot tool: ${FAKEROOT_TOOL}"
        set -- "${FAKEROOT_TOOL}" "${APK_TOOL}" mkpkg
    fi

    REPACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PKG_NAME}-repack.XXXXXX")"
    APK_META_DIR="${REPACK_DIR}/apk/${PKG_NAME}"
    APK_FILES_DIR="${REPACK_DIR}/ipkg/${PKG_NAME}"
    APK_PKGINFO_DIR="${APK_FILES_DIR}/lib/apk/packages"
    APK_CONFFILES_FILE="${APK_PKGINFO_DIR}/${PKG_NAME}.conffiles"
    APK_CONFFILES_STATIC_FILE="${APK_PKGINFO_DIR}/${PKG_NAME}.conffiles_static"
    APK_LIST_FILE="${APK_PKGINFO_DIR}/${PKG_NAME}.list"
    APK_POSTINST_PKG="${APK_META_DIR}/postinst-pkg"

    mkdir -p "${APK_META_DIR}" "${APK_PKGINFO_DIR}"
    cp -a "${PKG_BUILD_DIR}/.pkgdir/${PKG_NAME}/." "${APK_FILES_DIR}/"
    strip_xattrs_tree "${APK_FILES_DIR}"

    (cd "${APK_FILES_DIR}" && find . -type f,l -printf "/%P\n" | sort > "${APK_LIST_FILE}")

    if [ -n "${PKG_CONFFILES}" ]; then
        printf '%s\n' "${PKG_CONFFILES}" > "${APK_CONFFILES_FILE}"
        sed -i '/^$/d' "${APK_CONFFILES_FILE}"
        if [ -s "${APK_CONFFILES_FILE}" ]; then
            while IFS= read -r file; do
                [ -f "${APK_FILES_DIR}/${file}" ] || continue
                csum="$("${MKHASH_TOOL}" sha256 "${APK_FILES_DIR}/${file}")"
                printf '%s %s\n' "${file}" "${csum}" >> "${APK_CONFFILES_STATIC_FILE}"
            done < "${APK_CONFFILES_FILE}"
        fi
    fi

    if [ -n "${PKG_POSTINST}" ]; then
        printf '%s\n' "${PKG_POSTINST}" > "${APK_POSTINST_PKG}"
        chmod 0755 "${APK_POSTINST_PKG}"
    fi

    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0'
        printf '%s\n' '[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0'
        printf '%s\n' '. ${IPKG_INSTROOT}/lib/functions.sh'
        printf '%s\n' 'export root="${IPKG_INSTROOT}"'
        printf 'export pkgname="%s"\n' "${PKG_NAME}"
        printf '%s\n' 'add_group_and_user'
        printf '%s\n' 'default_postinst'
        [ ! -f "${APK_POSTINST_PKG}" ] || sed '/^[[:space:]]*#!/d' "${APK_POSTINST_PKG}"
    } > "${APK_META_DIR}/post-install"
    chmod 0755 "${APK_META_DIR}/post-install"

    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'export PKG_UPGRADE=1'
        [ ! -f "${APK_META_DIR}/post-install" ] || sed '/^[[:space:]]*#!/d' "${APK_META_DIR}/post-install"
    } > "${APK_META_DIR}/post-upgrade"
    chmod 0755 "${APK_META_DIR}/post-upgrade"

    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0'
        printf '%s\n' '. ${IPKG_INSTROOT}/lib/functions.sh'
        printf '%s\n' 'export root="${IPKG_INSTROOT}"'
        printf 'export pkgname="%s"\n' "${PKG_NAME}"
        printf '%s\n' 'default_prerm'
    } > "${APK_META_DIR}/pre-deinstall"
    chmod 0755 "${APK_META_DIR}/pre-deinstall"

    set -- "$@" \
        --info "name:${PKG_NAME}" \
        --info "version:${PKG_VERSION}-r${PKG_RELEASE}" \
        --info "description:${PKG_DESCRIPTION}" \
        --info "arch:noarch" \
        --info "license:${PKG_LICENSE}" \
        --info "origin:package/luci-app-xray/core" \
        --info "url:" \
        --info "maintainer:${PKG_MAINTAINER}" \
        --info "provides:${PKG_NAME}-any"

    if [ -f "${APK_META_DIR}/post-install" ]; then
        set -- "$@" --script "post-install:${APK_META_DIR}/post-install"
    fi
    if [ -f "${APK_META_DIR}/post-upgrade" ]; then
        set -- "$@" --script "post-upgrade:${APK_META_DIR}/post-upgrade"
    fi
    if [ -f "${APK_META_DIR}/pre-deinstall" ]; then
        set -- "$@" --script "pre-deinstall:${APK_META_DIR}/pre-deinstall"
    fi

    set -- "$@" --info "depends:${APK_DEPENDS}"

    set -- "$@" --files "${APK_FILES_DIR}" --output "${APK_OUTPUT}"
    "$@"
    rm -rf "${REPACK_DIR}"
else
    log "No APK output found, skipping dependency injection"
fi

log "Copying packages to: $OUTPUT_DIR"
find "${SDK_HOME}/bin/" -type f \( -name 'luci-app-xray*.ipk' -o -name 'luci-app-xray*.apk' \) -exec cp -f {} "$OUTPUT_DIR" \;
find "$OUTPUT_DIR" -type f \( -name '*.ipk' -o -name '*.apk' \) -exec ls -lh {} \;

log "Build finished"
log "SDK dir: $SDK_HOME"
log "Download cache: $DL_DIR"
log "Feeds cache: $FEEDS_DIR"
log "Artifacts: $OUTPUT_DIR"
