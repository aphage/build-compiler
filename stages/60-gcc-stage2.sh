#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"
source "${ROOT_DIR}/lib/drivers.sh"

main() {
    local gcc_source_dir build_dir

    ensure_source_tree gcc "${GCC_VERSION}" gcc_source_dir
    ensure_gcc_prerequisites "${gcc_source_dir}"
    build_dir="${WORK_DIR}/60-gcc-stage2-build"
    prepare_clean_dir "${build_dir}"

    run_in_dir "${build_dir}" env \
        MAKEINFO=true \
        "${gcc_source_dir}/configure" \
        --prefix="${PREFIX_DIR}" \
        --target="${TARGET_TRIPLE}" \
        --with-sysroot="${SYSROOT_DIR}" \
        --with-build-sysroot="${SYSROOT_DIR}" \
        --enable-languages=c,c++ \
        --disable-multilib \
        --disable-nls \
        --disable-libsanitizer \
        --with-arch="${TARGET_MARCH}" \
        --with-float="${TARGET_FLOAT_ABI}" \
        --with-fpu="${TARGET_FPU}"

    run_in_dir "${build_dir}" make MAKEINFO=true -j "${JOBS}"
    run_in_dir "${build_dir}" make MAKEINFO=true install

    if [[ "${CXX_RUNTIME}" == "libc++" || "${LIBC_VARIANT}" == "llvm-libc" ]]; then
        install_runtime_wrappers
    fi
}

main "$@"