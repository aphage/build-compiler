#!/usr/bin/env bash

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

ensure_dir() {
    mkdir -p "$1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

load_os_release() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        CURRENT_DISTRO_ID="${ID:-unknown}"
        CURRENT_DISTRO_VERSION_ID="${VERSION_ID:-unknown}"
        return 0
    fi

    CURRENT_DISTRO_ID="unknown"
    CURRENT_DISTRO_VERSION_ID="unknown"
    return 1
}

assert_host_supported() {
    local current_os current_arch

    current_os="$(uname -s)"
    current_arch="$(uname -m)"

    if [[ "${current_os}" != "Linux" ]]; then
        die "unsupported host OS: ${current_os}; only Linux is supported"
    fi

    if [[ "${current_arch}" != "x86_64" ]]; then
        die "unsupported host architecture: ${current_arch}; only x86_64 is supported"
    fi

    load_os_release || die "failed to read /etc/os-release"

    if [[ "${CURRENT_DISTRO_ID}" != "ubuntu" || "${CURRENT_DISTRO_VERSION_ID}" != "24.04" ]]; then
        die "unsupported host distro: ${CURRENT_DISTRO_ID} ${CURRENT_DISTRO_VERSION_ID}; only Ubuntu 24.04 is supported"
    fi
}

ensure_layout() {
    ensure_dir "${DOWNLOADS_DIR}"
    ensure_dir "${BUILD_DIR}"
    ensure_dir "${INSTALL_DIR}"
    ensure_dir "${SYSROOTS_DIR}"
    ensure_dir "${LOGS_DIR}"
    ensure_dir "${ARTIFACTS_DIR}"
    ensure_dir "${SOURCE_CACHE_DIR}"
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

format_command() {
    printf '%q ' "$@"
}

run_cmd() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] $(format_command "$@")"
        return 0
    fi

    log "run: $(format_command "$@")"
    if [[ -n "${CURRENT_STAGE_LOG:-}" ]]; then
        "$@" 2>&1 | tee -a "${CURRENT_STAGE_LOG}"
    else
        "$@"
    fi
}

run_in_dir() {
    local dir=$1
    shift

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] (cd ${dir} && $(format_command "$@"))"
        return 0
    fi

    ensure_dir "${dir}"
    log "run in ${dir}: $(format_command "$@")"
    if [[ -n "${CURRENT_STAGE_LOG:-}" ]]; then
        (
            cd "${dir}"
            "$@"
        ) 2>&1 | tee -a "${CURRENT_STAGE_LOG}"
    else
        (
            cd "${dir}"
            "$@"
        )
    fi
}

prepare_clean_dir() {
    local dir=$1

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] rm -rf ${dir}"
        log "[dry-run] mkdir -p ${dir}"
        return 0
    fi

    rm -rf "${dir}"
    mkdir -p "${dir}"
}

install_text_file() {
    local file_path=$1
    local file_mode=${2:-0644}
    local file_content=$3

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] write ${file_path}"
        return 0
    fi

    mkdir -p "$(dirname "${file_path}")"
    printf '%s' "${file_content}" >"${file_path}"
    chmod "${file_mode}" "${file_path}"
}

apt_install_hint() {
    local package_list=()
    local -A seen_packages=()
    local package_name

    for package_name in "$@"; do
        if [[ -n "${package_name}" && -z "${seen_packages[${package_name}]:-}" ]]; then
            package_list+=("${package_name}")
            seen_packages["${package_name}"]=1
        fi
    done

    if [[ ${#package_list[@]} -eq 0 ]]; then
        return 0
    fi

    printf 'sudo apt install %s' "${package_list[*]}"
}

check_host_dependencies() {
    local deps_file
    local -a missing_commands=()
    local -a missing_packages=()
    local command_name package_name scope note
    local should_check=0

    deps_file="${HOST_DEPS_FILE}"
    [[ -r "${deps_file}" ]] || die "missing host dependency config: ${deps_file}"

    while IFS='|' read -r command_name package_name scope note || [[ -n "${command_name:-}" ]]; do
        [[ -n "${command_name}" ]] || continue
        [[ "${command_name}" =~ ^# ]] && continue

        should_check=0
        case "${scope}" in
            base)
                should_check=1
                ;;
            llvm)
                if [[ "${USE_LLVM_RUNTIMES:-0}" -eq 1 || "${USE_LLVM_LIBC:-0}" -eq 1 ]]; then
                    should_check=1
                fi
                ;;
        esac

        if [[ "${should_check}" -eq 1 ]] && ! command_exists "${command_name}"; then
            missing_commands+=("${command_name}")
            missing_packages+=("${package_name}")
        fi
    done <"${deps_file}"

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        die "missing host tools: ${missing_commands[*]}; install with $(apt_install_hint "${missing_packages[@]}")"
    fi
}

prepare_build_context() {
    BUILD_NAME="$(slugify "${TARGET_TRIPLE}-${LIBC_VARIANT}-${CXX_RUNTIME}-gcc-${GCC_VERSION}-binutils-${BINUTILS_VERSION}-linux-${LINUX_HEADERS_VERSION}")"
    WORK_DIR="${BUILD_DIR}/${BUILD_NAME}"
    PREFIX_DIR="${INSTALL_DIR}/${BUILD_NAME}"
    SYSROOT_DIR="${SYSROOTS_DIR}/${BUILD_NAME}"
    MANIFEST_PATH="${ARTIFACTS_DIR}/${BUILD_NAME}.manifest"

    ensure_dir "${WORK_DIR}"
    ensure_dir "${PREFIX_DIR}"
    ensure_dir "${SYSROOT_DIR}"
}

write_manifest() {
    cat >"${MANIFEST_PATH}" <<EOF
BUILD_NAME=${BUILD_NAME}
HOST_TRIPLE=${HOST_TRIPLE}
TARGET_TRIPLE=${TARGET_TRIPLE}
LIBC_VARIANT=${LIBC_VARIANT}
CXX_RUNTIME=${CXX_RUNTIME}
JOBS=${JOBS}
GCC_VERSION=${GCC_VERSION}
BINUTILS_VERSION=${BINUTILS_VERSION}
LINUX_HEADERS_VERSION=${LINUX_HEADERS_VERSION}
GLIBC_VERSION=${GLIBC_VERSION}
MUSL_VERSION=${MUSL_VERSION}
LLVM_PROJECT_VERSION=${LLVM_PROJECT_VERSION}
WORK_DIR=${WORK_DIR}
PREFIX_DIR=${PREFIX_DIR}
SYSROOT_DIR=${SYSROOT_DIR}
SOURCE_CACHE_DIR=${SOURCE_CACHE_DIR}
GCC_ARCHIVE=${GCC_ARCHIVE}
GCC_URL=${GCC_URL}
GCC_SHA256=${GCC_SHA256}
BINUTILS_ARCHIVE=${BINUTILS_ARCHIVE}
BINUTILS_URL=${BINUTILS_URL}
BINUTILS_SHA256=${BINUTILS_SHA256}
LINUX_HEADERS_ARCHIVE=${LINUX_HEADERS_ARCHIVE}
LINUX_HEADERS_URL=${LINUX_HEADERS_URL}
LINUX_HEADERS_SHA256=${LINUX_HEADERS_SHA256}
GLIBC_ARCHIVE=${GLIBC_ARCHIVE}
GLIBC_URL=${GLIBC_URL}
GLIBC_SHA256=${GLIBC_SHA256}
MUSL_ARCHIVE=${MUSL_ARCHIVE}
MUSL_URL=${MUSL_URL}
MUSL_SHA256=${MUSL_SHA256}
LLVM_PROJECT_ARCHIVE=${LLVM_PROJECT_ARCHIVE}
LLVM_PROJECT_URL=${LLVM_PROJECT_URL}
LLVM_PROJECT_SHA256=${LLVM_PROJECT_SHA256}
COMBO_STATUS=${COMBO_STATUS}
COMBO_NOTE=${COMBO_NOTE}
EOF
}