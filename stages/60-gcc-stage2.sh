#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"
source "${ROOT_DIR}/lib/drivers.sh"

remove_gnu_cxx_runtime_artifacts() {
    local target_prefix runtime_lib_dir candidate

    target_prefix="${PREFIX_DIR}/${TARGET_TRIPLE}"
    runtime_lib_dir="${target_prefix}/lib"

    shopt -s nullglob
    for candidate in \
        "${runtime_lib_dir}/libstdc++"* \
        "${runtime_lib_dir}/libsupc++"*; do
        remove_path "${candidate}"
    done
    shopt -u nullglob

    remove_path "${target_prefix}/include/c++"
}

main() {
    local gcc_source_dir build_dir path_map_flags extra_configure_flags=()

    ensure_source_tree gcc "${GCC_VERSION}" gcc_source_dir
    ensure_gcc_prerequisites "${gcc_source_dir}"
    build_dir="${WORK_DIR}/60-gcc-stage2-build"
    prepare_clean_dir "${build_dir}"
    path_map_flags="$(build_path_map_flags)"

    if [[ "${CXX_RUNTIME}" == "libc++" ]]; then
        extra_configure_flags+=(
            --disable-libstdcxx
        )
    fi

    if [[ "${LIBC_VARIANT}" == "llvm-libc" ]]; then
        extra_configure_flags+=(
            --disable-shared
            --disable-threads
            --disable-libatomic
            --disable-libgomp
            --disable-libquadmath
            --disable-libssp
            --disable-libvtv
        )
    fi

    run_in_dir "${build_dir}" env \
        MAKEINFO=true \
        CFLAGS="${path_map_flags}" \
        CXXFLAGS="${path_map_flags}" \
        BOOT_CFLAGS="${path_map_flags}" \
        CFLAGS_FOR_TARGET="${path_map_flags}" \
        CXXFLAGS_FOR_TARGET="${path_map_flags}" \
        "${gcc_source_dir}/configure" \
        --prefix="${CONFIGURE_PREFIX}" \
        --target="${TARGET_TRIPLE}" \
        --with-sysroot="${CONFIGURE_SYSROOT}" \
        --with-build-sysroot="${SYSROOT_DIR}" \
        --enable-languages=c,c++ \
        --disable-multilib \
        --disable-nls \
        --disable-libsanitizer \
        "${extra_configure_flags[@]}" \
        --with-arch="${TARGET_MARCH}" \
        --with-float="${TARGET_FLOAT_ABI}" \
        --with-fpu="${TARGET_FPU}"

    run_in_dir "${build_dir}" make MAKEINFO=true -j "${JOBS}"
    run_in_dir "${build_dir}" make MAKEINFO=true DESTDIR="${INSTALL_DIR}" install

    if [[ "${CXX_RUNTIME}" == "libc++" ]]; then
        remove_gnu_cxx_runtime_artifacts
    fi

    if [[ "${CXX_RUNTIME}" == "libc++" || "${LIBC_VARIANT}" == "llvm-libc" ]]; then
        install_runtime_wrappers
    fi
}

main "$@"