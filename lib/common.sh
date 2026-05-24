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

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

build_path_map_flags() {
    local mapped_root

    mapped_root="$(sanitized_root_path)"

    printf '%s' "-ffile-prefix-map=${ROOT_DIR}=${mapped_root} -fdebug-prefix-map=${ROOT_DIR}=${mapped_root} -fmacro-prefix-map=${ROOT_DIR}=${mapped_root}"
}

sanitized_root_path() {
    local base_root=/usr/src/build-toolchain
    local fallback_prefix=/usr/src/
    local target_length=${#ROOT_DIR}
    local padding

    if (( target_length < 2 )); then
        die "cannot derive sanitized root path for ROOT_DIR=${ROOT_DIR}"
    fi

    if (( ${#base_root} == target_length )); then
        printf '%s' "${base_root}"
        return 0
    fi

    if (( ${#base_root} < target_length )); then
        padding=$(printf '%*s' "$((target_length - ${#base_root}))" '' | tr ' ' '/')
        printf '%s%s' "${base_root}" "${padding}"
        return 0
    fi

    if (( ${#fallback_prefix} < target_length )); then
        padding=$(printf '%*s' "$((target_length - ${#fallback_prefix}))" '' | tr ' ' 'x')
        printf '%s%s' "${fallback_prefix}" "${padding}"
        return 0
    fi

    padding=$(printf '%*s' "$((target_length - 1))" '' | tr ' ' 'x')
    printf '/%s' "${padding}"
}

escape_sed_pattern() {
    printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

refresh_symlink() {
    local link_path=$1
    local target_path=$2

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] ln -sfn ${target_path} ${link_path}"
        return 0
    fi

    rm -rf "${link_path}"
    ln -s "${target_path}" "${link_path}"
}

rewrite_internal_absolute_symlinks() {
    local tree_root=$1
    local link_path link_target resolved_target relative_target

    command_exists realpath || die "realpath is required to rewrite internal symlinks"

    while IFS= read -r -d '' link_path; do
        link_target="$(readlink "${link_path}")"
        [[ "${link_target}" == /* ]] || continue

        resolved_target="${tree_root}${link_target}"
        if ! path_exists "${resolved_target}"; then
            continue
        fi

        relative_target="$(realpath --no-symlinks --relative-to="$(dirname "${link_path}")" "${resolved_target}")"

        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log "[dry-run] ln -sfn ${relative_target} ${link_path}"
            continue
        fi

        rm -f "${link_path}"
        ln -s "${relative_target}" "${link_path}"
    done < <(find "${tree_root}" -type l -print0)
}

remove_path() {
    local target_path=$1

    if ! path_exists "${target_path}"; then
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] rm -rf ${target_path}"
        return 0
    fi

    rm -rf "${target_path}"
}

strip_debug_symbols_in_tree() {
    local tree_root=$1
    local candidate file_info target_strip strip_status

    target_strip="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-strip"

    while IFS= read -r -d '' candidate; do
        file_info="$(file -b "${candidate}" 2>/dev/null || true)"
        case "${file_info}" in
            ELF*|current\ ar\ archive*)
                if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
                    log "[dry-run] strip --strip-debug ${candidate}"
                    continue
                fi

                strip_status=0
                if ! strip --strip-debug "${candidate}" >/dev/null 2>&1; then
                    strip_status=$?

                    if [[ -x "${target_strip}" ]]; then
                        if "${target_strip}" --strip-debug "${candidate}" >/dev/null 2>&1; then
                            strip_status=0
                        fi
                    fi
                fi

                if [[ "${strip_status}" -ne 0 ]]; then
                    warn "unable to strip debug info from ${candidate}"
                fi
                ;;
        esac
    done < <(find "${tree_root}" -type f -print0)
}

sanitize_text_paths_in_tree() {
    local tree_root=$1
    local logical_work_dir="/build/${BUILD_NAME}"
    local logical_source_dir=/sources
    local logical_root=/workspace
    local logical_sysroot="${CONFIGURE_PREFIX}/${TARGET_TRIPLE}/sysroot"
    local -a replacements=(
        "${SYSROOT_DIR}|${logical_sysroot}"
        "${PREFIX_DIR}|${CONFIGURE_PREFIX}"
        "${WORK_DIR}|${logical_work_dir}"
        "${SOURCE_CACHE_DIR}|${logical_source_dir}"
        "${ROOT_DIR}|${logical_root}"
    )
    local replacement old_path new_path sed_pattern sed_replacement candidate

    for replacement in "${replacements[@]}"; do
        old_path=${replacement%%|*}
        new_path=${replacement#*|}
        sed_pattern="$(escape_sed_pattern "${old_path}")"
        sed_replacement="$(escape_sed_replacement "${new_path}")"

        while IFS= read -r candidate; do
            [[ -n "${candidate}" ]] || continue

            if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
                log "[dry-run] sanitize ${candidate}: ${old_path} -> ${new_path}"
                continue
            fi

            sed -i "s|${sed_pattern}|${sed_replacement}|g" "${candidate}"
        done < <(grep --binary-files=without-match -RIl -- "${old_path}" "${tree_root}" || true)
    done
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

build_name_cxx_runtime_tag() {
    case "$1" in
        libc++)
            printf 'libcxx'
            ;;
        libstdc++)
            printf 'libstdcxx'
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
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

resolve_build_paths() {
    local cxx_runtime_tag

    cxx_runtime_tag="$(build_name_cxx_runtime_tag "${CXX_RUNTIME}")"
    BUILD_NAME="$(slugify "${TARGET_TRIPLE}-${LIBC_VARIANT}-${cxx_runtime_tag}-gcc-${GCC_VERSION}-binutils-${BINUTILS_VERSION}-linux-${LINUX_HEADERS_VERSION}")"
    WORK_DIR="${BUILD_DIR}/${BUILD_NAME}"
    CONFIGURE_PREFIX="/${BUILD_NAME}"
    CONFIGURE_SYSROOT="${CONFIGURE_PREFIX}/${TARGET_TRIPLE}/sysroot"
    PREFIX_DIR="${INSTALL_DIR}/${BUILD_NAME}"
    SYSROOT_DIR="${PREFIX_DIR}/${TARGET_TRIPLE}/sysroot"
    SYSROOT_COMPAT_DIR="${SYSROOTS_DIR}/${BUILD_NAME}"
    MANIFEST_PATH="${ARTIFACTS_DIR}/${BUILD_NAME}.manifest"
}

prepare_build_context() {
    resolve_build_paths

    ensure_dir "${WORK_DIR}"
    ensure_dir "${PREFIX_DIR}"
    ensure_dir "${SYSROOT_DIR}"
    refresh_symlink "${SYSROOT_COMPAT_DIR}" "../install/${BUILD_NAME}/${TARGET_TRIPLE}/sysroot"
}

clean_build_outputs() {
    local log_path
    local -a log_paths=()

    shopt -s nullglob
    log_paths=("${LOGS_DIR}/${BUILD_NAME}."*.log)
    shopt -u nullglob

    remove_path "${WORK_DIR}"
    remove_path "${PREFIX_DIR}"
    remove_path "${SYSROOT_COMPAT_DIR}"
    remove_path "${MANIFEST_PATH}"
    remove_path "${ARTIFACTS_DIR}/${BUILD_NAME}.tar.xz"

    for log_path in "${log_paths[@]}"; do
        remove_path "${log_path}"
    done
}

write_manifest() {
    local key
    local -a manifest_keys=(
        BUILD_NAME
        HOST_TRIPLE
        TARGET_TRIPLE
        LIBC_VARIANT
        CXX_RUNTIME
        JOBS
        GCC_VERSION
        BINUTILS_VERSION
        LINUX_HEADERS_VERSION
        GLIBC_VERSION
        MUSL_VERSION
        LLVM_PROJECT_VERSION
        GCC_ARCHIVE
        GCC_URL
        GCC_SHA256
        BINUTILS_ARCHIVE
        BINUTILS_URL
        BINUTILS_SHA256
        LINUX_HEADERS_ARCHIVE
        LINUX_HEADERS_URL
        LINUX_HEADERS_SHA256
        GLIBC_ARCHIVE
        GLIBC_URL
        GLIBC_SHA256
        MUSL_ARCHIVE
        MUSL_URL
        MUSL_SHA256
        LLVM_PROJECT_ARCHIVE
        LLVM_PROJECT_URL
        LLVM_PROJECT_SHA256
        COMBO_STATUS
        COMBO_NOTE
    )

    : >"${MANIFEST_PATH}"

    for key in "${manifest_keys[@]}"; do
        printf '%s=%q\n' "${key}" "${!key}" >>"${MANIFEST_PATH}"
    done

    printf 'WORK_DIR=%q\n' "build/${BUILD_NAME}" >>"${MANIFEST_PATH}"
    printf 'PREFIX_DIR=%q\n' "${CONFIGURE_PREFIX}" >>"${MANIFEST_PATH}"
    printf 'SYSROOT_DIR=%q\n' "${CONFIGURE_PREFIX}/${TARGET_TRIPLE}/sysroot" >>"${MANIFEST_PATH}"
    printf 'SOURCE_CACHE_DIR=%q\n' 'build/sources' >>"${MANIFEST_PATH}"
}