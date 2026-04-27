#!/usr/bin/env bash

declare -Ag SOURCE_ARCHIVES=()
declare -Ag SOURCE_URLS=()
declare -Ag SOURCE_SHA256=()

resolve_target_triple() {
    local default_target_triple

    case "${LIBC_VARIANT}" in
        glibc)
            default_target_triple="${TARGET_GLIBC_TRIPLE}"
            ;;
        musl)
            default_target_triple="${TARGET_MUSL_TRIPLE}"
            ;;
        llvm-libc)
            default_target_triple="${TARGET_LLVM_LIBC_TRIPLE}"
            ;;
        *)
            die "unsupported libc variant while resolving target triple: ${LIBC_VARIANT}"
            ;;
    esac

    if [[ "${TARGET_TRIPLE_EXPLICIT:-0}" -eq 0 ]]; then
        TARGET_TRIPLE="${default_target_triple}"
    fi
}

load_checksums() {
    local checksum_file

    checksum_file="${ROOT_DIR}/config/checksums.txt"
    [[ -r "${checksum_file}" ]] || die "missing checksum config: ${checksum_file}"

    while IFS='|' read -r component version archive sha256 url || [[ -n "${component:-}" ]]; do
        [[ -n "${component}" ]] || continue
        [[ "${component}" =~ ^# ]] && continue
        SOURCE_ARCHIVES["${component}@${version}"]="${archive}"
        SOURCE_URLS["${component}@${version}"]="${url}"
        SOURCE_SHA256["${component}@${version}"]="${sha256}"
    done <"${checksum_file}"
}

lookup_source_field() {
    local table_name=$1
    local component=$2
    local version=$3
    local key="${component}@${version}"

    case "${table_name}" in
        archive)
            printf '%s' "${SOURCE_ARCHIVES[${key}]:-}"
            ;;
        url)
            printf '%s' "${SOURCE_URLS[${key}]:-}"
            ;;
        sha256)
            printf '%s' "${SOURCE_SHA256[${key}]:-}"
            ;;
        *)
            die "unknown source field lookup: ${table_name}"
            ;;
    esac
}

require_source_metadata() {
    local component=$1
    local version=$2
    local archive_var_name=$3
    local url_var_name=$4
    local sha_var_name=$5
    local archive url sha256

    archive="$(lookup_source_field archive "${component}" "${version}")"
    url="$(lookup_source_field url "${component}" "${version}")"
    sha256="$(lookup_source_field sha256 "${component}" "${version}")"

    [[ -n "${archive}" ]] || die "missing archive metadata for ${component} ${version}"
    [[ -n "${url}" ]] || die "missing source URL metadata for ${component} ${version}"
    [[ -n "${sha256}" ]] || die "missing checksum metadata for ${component} ${version}"

    printf -v "${archive_var_name}" '%s' "${archive}"
    printf -v "${url_var_name}" '%s' "${url}"
    printf -v "${sha_var_name}" '%s' "${sha256}"
}

resolve_versions() {
    [[ -n "${ROOT_DIR:-}" ]] || die "ROOT_DIR is not set"

    resolve_target_triple
    load_checksums

    require_source_metadata gcc "${GCC_VERSION}" GCC_ARCHIVE GCC_URL GCC_SHA256
    require_source_metadata binutils "${BINUTILS_VERSION}" BINUTILS_ARCHIVE BINUTILS_URL BINUTILS_SHA256
    require_source_metadata linux "${LINUX_HEADERS_VERSION}" LINUX_HEADERS_ARCHIVE LINUX_HEADERS_URL LINUX_HEADERS_SHA256
    require_source_metadata glibc "${GLIBC_VERSION}" GLIBC_ARCHIVE GLIBC_URL GLIBC_SHA256
    require_source_metadata musl "${MUSL_VERSION}" MUSL_ARCHIVE MUSL_URL MUSL_SHA256
    require_source_metadata llvm-project "${LLVM_PROJECT_VERSION}" LLVM_PROJECT_ARCHIVE LLVM_PROJECT_URL LLVM_PROJECT_SHA256
}