#!/usr/bin/env bash

declare -Ag SUPPORTED_COMBOS=()
declare -Ag COMBO_NOTES=()

load_supported_combos() {
    local combos_file

    combos_file="${ROOT_DIR}/config/supported-combos.env"
    [[ -r "${combos_file}" ]] || die "missing supported combo config: ${combos_file}"

    SUPPORTED_COMBOS=()
    COMBO_NOTES=()

    while IFS='|' read -r libc_variant cxx_runtime status note || [[ -n "${libc_variant:-}" ]]; do
        [[ -n "${libc_variant}" ]] || continue
        [[ "${libc_variant}" =~ ^# ]] && continue
        SUPPORTED_COMBOS["${libc_variant}|${cxx_runtime}"]="${status}"
        COMBO_NOTES["${libc_variant}|${cxx_runtime}"]="${note}"
    done <"${combos_file}"
}

validate_combo() {
    local combo_key status note

    load_supported_combos

    if [[ "${LIBC_VARIANT}" != "glibc" && "${LIBC_VARIANT}" != "musl" && "${LIBC_VARIANT}" != "llvm-libc" ]]; then
        die "unsupported libc variant: ${LIBC_VARIANT}; expected glibc, musl, or llvm-libc"
    fi

    if [[ "${CXX_RUNTIME}" != "libstdc++" && "${CXX_RUNTIME}" != "libc++" ]]; then
        die "unsupported C++ runtime: ${CXX_RUNTIME}; expected libstdc++ or libc++"
    fi

    case "${LIBC_VARIANT}" in
        glibc)
            [[ "${TARGET_TRIPLE}" == "${TARGET_GLIBC_TRIPLE}" ]] || die "glibc route requires target triple ${TARGET_GLIBC_TRIPLE}; got ${TARGET_TRIPLE}"
            ;;
        musl)
            [[ "${TARGET_TRIPLE}" == "${TARGET_MUSL_TRIPLE}" ]] || die "musl route requires target triple ${TARGET_MUSL_TRIPLE}; got ${TARGET_TRIPLE}"
            ;;
        llvm-libc)
            [[ "${TARGET_TRIPLE}" == "${TARGET_LLVM_LIBC_TRIPLE}" ]] || die "llvm-libc route requires target triple ${TARGET_LLVM_LIBC_TRIPLE}; got ${TARGET_TRIPLE}"
            ;;
    esac

    combo_key="${LIBC_VARIANT}|${CXX_RUNTIME}"
    status="${SUPPORTED_COMBOS[${combo_key}]:-unsupported}"
    note="${COMBO_NOTES[${combo_key}]:-unsupported combination}"

    case "${status}" in
        supported)
            COMBO_STATUS="supported"
            COMBO_NOTE="${note}"
            ;;
        rejected)
            die "unsupported runtime combination ${LIBC_VARIANT} + ${CXX_RUNTIME}: ${note}"
            ;;
        *)
            die "runtime combination ${LIBC_VARIANT} + ${CXX_RUNTIME} is not in the supported matrix"
            ;;
    esac

    USE_LLVM_RUNTIMES=0
    USE_LLVM_LIBC=0
    if [[ "${CXX_RUNTIME}" == "libc++" ]]; then
        USE_LLVM_RUNTIMES=1
    fi
    if [[ "${LIBC_VARIANT}" == "llvm-libc" ]]; then
        USE_LLVM_LIBC=1
    fi
}