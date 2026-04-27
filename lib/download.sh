#!/usr/bin/env bash

ensure_checksums_loaded() {
    if [[ ${#SOURCE_ARCHIVES[@]} -eq 0 ]]; then
        load_checksums
    fi
}

resolved_archive_name() {
    local component=$1

    case "${component}" in
        gcc)
            printf '%s' "${GCC_ARCHIVE:-}"
            ;;
        binutils)
            printf '%s' "${BINUTILS_ARCHIVE:-}"
            ;;
        linux)
            printf '%s' "${LINUX_HEADERS_ARCHIVE:-}"
            ;;
        glibc)
            printf '%s' "${GLIBC_ARCHIVE:-}"
            ;;
        musl)
            printf '%s' "${MUSL_ARCHIVE:-}"
            ;;
        llvm-project)
            printf '%s' "${LLVM_PROJECT_ARCHIVE:-}"
            ;;
    esac
}

resolved_url() {
    local component=$1

    case "${component}" in
        gcc)
            printf '%s' "${GCC_URL:-}"
            ;;
        binutils)
            printf '%s' "${BINUTILS_URL:-}"
            ;;
        linux)
            printf '%s' "${LINUX_HEADERS_URL:-}"
            ;;
        glibc)
            printf '%s' "${GLIBC_URL:-}"
            ;;
        musl)
            printf '%s' "${MUSL_URL:-}"
            ;;
        llvm-project)
            printf '%s' "${LLVM_PROJECT_URL:-}"
            ;;
    esac
}

resolved_sha256() {
    local component=$1

    case "${component}" in
        gcc)
            printf '%s' "${GCC_SHA256:-}"
            ;;
        binutils)
            printf '%s' "${BINUTILS_SHA256:-}"
            ;;
        linux)
            printf '%s' "${LINUX_HEADERS_SHA256:-}"
            ;;
        glibc)
            printf '%s' "${GLIBC_SHA256:-}"
            ;;
        musl)
            printf '%s' "${MUSL_SHA256:-}"
            ;;
        llvm-project)
            printf '%s' "${LLVM_PROJECT_SHA256:-}"
            ;;
    esac
}

source_archive_path() {
    local archive_name=$1

    printf '%s' "${DOWNLOADS_DIR}/${archive_name}"
}

source_tree_path() {
    local component=$1
    local version=$2

    printf '%s' "${SOURCE_CACHE_DIR}/${component}-${version}"
}

verify_archive_checksum() {
    local archive_path=$1
    local expected_sha256=$2

    if [[ ! -f "${archive_path}" ]]; then
        return 1
    fi

    local actual_sha256
    actual_sha256="$(sha256sum "${archive_path}" | awk '{print $1}')"
    [[ "${actual_sha256}" == "${expected_sha256}" ]]
}

download_archive() {
    local component=$1
    local version=$2
    local out_var_name=$3
    local archive_name url sha256 resolved_archive_path temp_path

    archive_name="$(resolved_archive_name "${component}")"
    url="$(resolved_url "${component}")"
    sha256="$(resolved_sha256 "${component}")"

    if [[ -z "${archive_name}" || -z "${url}" || -z "${sha256}" ]]; then
        ensure_checksums_loaded
        archive_name="$(lookup_source_field archive "${component}" "${version}")"
        url="$(lookup_source_field url "${component}" "${version}")"
        sha256="$(lookup_source_field sha256 "${component}" "${version}")"
    fi

    resolved_archive_path="$(source_archive_path "${archive_name}")"
    temp_path="${resolved_archive_path}.tmp"

    if verify_archive_checksum "${resolved_archive_path}" "${sha256}"; then
        log "using cached archive ${archive_name}"
        printf -v "${out_var_name}" '%s' "${resolved_archive_path}"
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] would download ${url} -> ${resolved_archive_path}"
        printf -v "${out_var_name}" '%s' "${resolved_archive_path}"
        return 0
    fi

    ensure_dir "$(dirname "${resolved_archive_path}")"
    rm -f "${temp_path}"
    run_cmd curl -L --fail --retry 3 --output "${temp_path}" "${url}"

    if ! verify_archive_checksum "${temp_path}" "${sha256}"; then
        rm -f "${temp_path}"
        die "checksum mismatch for ${component} ${version}"
    fi

    mv "${temp_path}" "${resolved_archive_path}"
    printf -v "${out_var_name}" '%s' "${resolved_archive_path}"
}

extract_archive() {
    local archive_path=$1
    local destination_dir=$2
    local temp_dir root_entry
    local -a archive_entries=()

    if [[ -d "${destination_dir}" ]]; then
        log "using cached source tree $(basename "${destination_dir}")"
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] would extract ${archive_path} -> ${destination_dir}"
        return 0
    fi

    temp_dir="${destination_dir}.tmp"
    prepare_clean_dir "${temp_dir}"
    run_cmd tar -xf "${archive_path}" -C "${temp_dir}"
    mapfile -t archive_entries < <(tar -tf "${archive_path}")
    root_entry="${archive_entries[0]%%/*}"

    if [[ -n "${root_entry}" && -d "${temp_dir}/${root_entry}" ]]; then
        mv "${temp_dir}/${root_entry}" "${destination_dir}"
        rm -rf "${temp_dir}"
    else
        mv "${temp_dir}" "${destination_dir}"
    fi
}

ensure_source_tree() {
    local component=$1
    local version=$2
    local out_var_name=$3
    local archive_path source_dir

    download_archive "${component}" "${version}" archive_path
    source_dir="$(source_tree_path "${component}" "${version}")"
    extract_archive "${archive_path}" "${source_dir}"

    printf -v "${out_var_name}" '%s' "${source_dir}"
}

ensure_gcc_prerequisites() {
    local gcc_source_dir=$1
    local marker_file="${gcc_source_dir}/.prerequisites-ready"

    if [[ -f "${marker_file}" ]]; then
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] would run ${gcc_source_dir}/contrib/download_prerequisites"
        return 0
    fi

    run_in_dir "${gcc_source_dir}" ./contrib/download_prerequisites
    : >"${marker_file}"
}