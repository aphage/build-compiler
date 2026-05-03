#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_PATH="${PATH}"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/args.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/matrix.sh"
source "${ROOT_DIR}/lib/download.sh"
source "${ROOT_DIR}/lib/drivers.sh"

declare -ag STAGE_FILES=(
    "${ROOT_DIR}/stages/10-binutils.sh"
    "${ROOT_DIR}/stages/20-linux-headers.sh"
    "${ROOT_DIR}/stages/30-gcc-stage1.sh"
    "${ROOT_DIR}/stages/40-libc.sh"
    "${ROOT_DIR}/stages/50-llvm-runtimes.sh"
    "${ROOT_DIR}/stages/60-gcc-stage2.sh"
    "${ROOT_DIR}/stages/70-package.sh"
)

export_build_environment() {
    export ROOT_DIR
    export HOST_TRIPLE TARGET_TRIPLE TARGET_TRIPLE_EXPLICIT
    export TARGET_FLOAT_ABI TARGET_FPU TARGET_MARCH
    export TARGET_GLIBC_TRIPLE TARGET_MUSL_TRIPLE TARGET_LLVM_LIBC_TRIPLE
    export LIBC_VARIANT CXX_RUNTIME
    export JOBS CONFIG_FILE DRY_RUN PRINT_CONFIG CHECK_HOST_DEPS RESUME_FROM_STAGE
    export GCC_VERSION BINUTILS_VERSION LINUX_HEADERS_VERSION GLIBC_VERSION MUSL_VERSION LLVM_PROJECT_VERSION
    export GLIBC_MIN_KERNEL
    export DOWNLOADS_DIR BUILD_DIR INSTALL_DIR SYSROOTS_DIR LOGS_DIR ARTIFACTS_DIR SOURCE_CACHE_DIR
    export HOST_DEPS_FILE
    export BUILD_NAME WORK_DIR PREFIX_DIR SYSROOT_DIR SYSROOT_COMPAT_DIR MANIFEST_PATH
    export CONFIGURE_PREFIX CONFIGURE_SYSROOT
    export GCC_ARCHIVE GCC_URL GCC_SHA256
    export BINUTILS_ARCHIVE BINUTILS_URL BINUTILS_SHA256
    export LINUX_HEADERS_ARCHIVE LINUX_HEADERS_URL LINUX_HEADERS_SHA256
    export GLIBC_ARCHIVE GLIBC_URL GLIBC_SHA256
    export MUSL_ARCHIVE MUSL_URL MUSL_SHA256
    export LLVM_PROJECT_ARCHIVE LLVM_PROJECT_URL LLVM_PROJECT_SHA256
    export COMBO_STATUS COMBO_NOTE USE_LLVM_RUNTIMES USE_LLVM_LIBC
    export CURRENT_STAGE_ID CURRENT_STAGE_LOG
}

validate_resume_stage() {
    local stage_file stage_id found=0

    if [[ -z "${RESUME_FROM_STAGE}" ]]; then
        return 0
    fi

    for stage_file in "${STAGE_FILES[@]}"; do
        stage_id="$(basename "${stage_file}" .sh)"
        if [[ "${stage_id}" == "${RESUME_FROM_STAGE}" ]]; then
            found=1
            break
        fi
    done

    [[ "${found}" -eq 1 ]] || die "unknown stage for --resume: ${RESUME_FROM_STAGE}"
}

run_stage_file() {
    local stage_file=$1
    local stage_id stage_done_file

    stage_id="$(basename "${stage_file}" .sh)"
    stage_done_file="${WORK_DIR}/.${stage_id}.done"

    if [[ "${DRY_RUN}" -eq 0 && -f "${stage_done_file}" && -z "${RESUME_FROM_STAGE}" ]]; then
        log "stage ${stage_id} already completed; skipping"
        return 0
    fi

    CURRENT_STAGE_ID="${stage_id}"
    CURRENT_STAGE_LOG="${LOGS_DIR}/${BUILD_NAME}.${stage_id}.log"

    if [[ "${stage_id}" == "10-binutils" ]]; then
        PATH="${ORIGINAL_PATH}"
    else
        PATH="${PREFIX_DIR}/bin:${ORIGINAL_PATH}"
    fi

    export_build_environment

    log "starting stage ${stage_id}"
    bash "${stage_file}"

    if [[ "${DRY_RUN}" -eq 0 ]]; then
        : >"${stage_done_file}"
    fi
}

run_stage_pipeline() {
    local stage_file stage_id resume_started

    validate_resume_stage

    if [[ -n "${RESUME_FROM_STAGE}" ]]; then
        resume_started=0
    else
        resume_started=1
    fi

    for stage_file in "${STAGE_FILES[@]}"; do
        stage_id="$(basename "${stage_file}" .sh)"

        if [[ "${resume_started}" -eq 0 ]]; then
            if [[ "${stage_id}" != "${RESUME_FROM_STAGE}" ]]; then
                log "skipping stage ${stage_id} until resume point ${RESUME_FROM_STAGE}"
                continue
            fi
            resume_started=1
        fi

        run_stage_file "${stage_file}"
    done
}

main() {
    local command=build

    load_default_config
    parse_args "$@"

    if [[ "${SHOW_HELP}" -eq 1 ]]; then
        show_help
        return 0
    fi

    load_user_config
    apply_cli_overrides

    if [[ ${#POSITIONAL_ARGS[@]} -gt 1 ]]; then
        die "unexpected positional arguments: ${POSITIONAL_ARGS[*]}"
    fi

    if [[ ${#POSITIONAL_ARGS[@]} -eq 1 ]]; then
        case "${POSITIONAL_ARGS[0]}" in
            clean)
                command=clean
                ;;
            *)
                die "unexpected positional arguments: ${POSITIONAL_ARGS[*]}"
                ;;
        esac
    fi

    ensure_layout
    resolve_versions
    validate_combo
    resolve_build_paths

    if [[ "${PRINT_CONFIG}" -eq 1 ]]; then
        print_config
    fi

    if [[ "${command}" == "clean" ]]; then
        clean_build_outputs

        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "dry run complete; clean plan emitted for ${BUILD_NAME}"
        else
            log "clean completed for ${BUILD_NAME}"
        fi
        return 0
    fi

    assert_host_supported
    prepare_build_context
    export_build_environment
    write_manifest

    if [[ "${CHECK_HOST_DEPS}" -eq 1 ]]; then
        check_host_dependencies
        return 0
    fi

    if [[ "${DRY_RUN}" -eq 0 ]]; then
        check_host_dependencies
    fi

    run_stage_pipeline

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "dry run complete; build plan emitted for ${BUILD_NAME}"
        return 0
    fi

    log "toolchain build completed for ${BUILD_NAME}"
}

main "$@"