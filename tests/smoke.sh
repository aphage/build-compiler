#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

resolve_host_path() {
    local requested_path=$1
    local fallback_path

    if [[ -e "${requested_path}" || -L "${requested_path}" ]]; then
        printf '%s' "${requested_path}"
        return 0
    fi

    if [[ "${requested_path}" == /* ]]; then
        fallback_path="${REPO_ROOT}/install${requested_path}"
        if [[ -e "${fallback_path}" || -L "${fallback_path}" ]]; then
            printf '%s' "${fallback_path}"
            return 0
        fi
    fi

    printf '%s' "${requested_path}"
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: tests/smoke.sh <toolchain-prefix> [sysroot]" >&2
    exit 1
fi

TOOLCHAIN_PREFIX=$(resolve_host_path "$1")
SYSROOT_DIR=${2-}
if [[ -n "${SYSROOT_DIR}" ]]; then
    SYSROOT_DIR=$(resolve_host_path "${SYSROOT_DIR}")
fi
RUN_RUNTIME_SMOKE=${RUN_RUNTIME_SMOKE:-0}

if [[ -n "${TARGET_TRIPLE:-}" ]]; then
    TARGET_TRIPLE=${TARGET_TRIPLE}
else
    shopt -s nullglob
    gcc_drivers=("${TOOLCHAIN_PREFIX}/bin/"*-gcc)
    shopt -u nullglob

    if [[ ${#gcc_drivers[@]} -eq 0 ]]; then
        echo "unable to infer target triple from ${TOOLCHAIN_PREFIX}/bin" >&2
        exit 1
    fi

    TARGET_TRIPLE=$(basename "${gcc_drivers[0]}" -gcc)
fi

if [[ -z "${SYSROOT_DIR}" ]]; then
    SYSROOT_DIR="${TOOLCHAIN_PREFIX}/${TARGET_TRIPLE}/sysroot"
fi

if [[ ! -d "${SYSROOT_DIR}" ]]; then
    echo "sysroot not found: ${SYSROOT_DIR}" >&2
    exit 1
fi

if [[ "${RUN_RUNTIME_SMOKE}" == "1" ]]; then
    QEMU_ARM_BIN=${QEMU_ARM_BIN:-$(command -v qemu-arm || true)}
    if [[ -z "${QEMU_ARM_BIN}" ]]; then
        echo "RUN_RUNTIME_SMOKE=1 requires qemu-arm" >&2
        exit 1
    fi

    QEMU_LD_LIBRARY_PATH="${TOOLCHAIN_PREFIX}/${TARGET_TRIPLE}/lib:${SYSROOT_DIR}/lib:${SYSROOT_DIR}/usr/lib"
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

cat >"${WORK_DIR}/hello.c" <<'EOF'
#include <stdio.h>

int main(void) {
    puts("hello");
    return 0;
}
EOF

cat >"${WORK_DIR}/hello.cpp" <<'EOF'
#include <iostream>

int main() {
    try {
        std::cout << "hello" << std::endl;
    } catch (...) {
        return 1;
    }
    return 0;
}
EOF

"${TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLE}-gcc" --sysroot "${SYSROOT_DIR}" "${WORK_DIR}/hello.c" -o "${WORK_DIR}/hello-c"
"${TOOLCHAIN_PREFIX}/bin/${TARGET_TRIPLE}-g++" --sysroot "${SYSROOT_DIR}" "${WORK_DIR}/hello.cpp" -o "${WORK_DIR}/hello-cxx"

echo "smoke compile completed: ${WORK_DIR}/hello-c ${WORK_DIR}/hello-cxx"

if [[ "${RUN_RUNTIME_SMOKE}" == "1" ]]; then
    c_output="$("${QEMU_ARM_BIN}" -L "${SYSROOT_DIR}" "${WORK_DIR}/hello-c")"
    cxx_output="$("${QEMU_ARM_BIN}" -L "${SYSROOT_DIR}" -E LD_LIBRARY_PATH="${QEMU_LD_LIBRARY_PATH}" "${WORK_DIR}/hello-cxx")"

    [[ "${c_output}" == "hello" ]] || {
        echo "unexpected C runtime output: ${c_output}" >&2
        exit 1
    }
    [[ "${cxx_output}" == "hello" ]] || {
        echo "unexpected C++ runtime output: ${cxx_output}" >&2
        exit 1
    }

    echo "smoke runtime completed: ${c_output} ${cxx_output}"
fi