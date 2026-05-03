#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

main() {
    local gcc_source_dir build_dir path_map_flags

    ensure_source_tree gcc "${GCC_VERSION}" gcc_source_dir
    ensure_gcc_prerequisites "${gcc_source_dir}"
    build_dir="${WORK_DIR}/30-gcc-stage1-build"
    prepare_clean_dir "${build_dir}"
    path_map_flags="$(build_path_map_flags)"

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
        --enable-languages=c \
        --disable-multilib \
        --disable-nls \
        --disable-shared \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libsanitizer \
        --without-headers \
        --with-arch="${TARGET_MARCH}" \
        --with-float="${TARGET_FLOAT_ABI}" \
        --with-fpu="${TARGET_FPU}"

    run_in_dir "${build_dir}" make MAKEINFO=true -j "${JOBS}" all-gcc
    run_in_dir "${build_dir}" make MAKEINFO=true DESTDIR="${INSTALL_DIR}" install-gcc
}

main "$@"