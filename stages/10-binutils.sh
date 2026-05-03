#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

main() {
    local binutils_source_dir build_dir path_map_flags

    ensure_source_tree binutils "${BINUTILS_VERSION}" binutils_source_dir
    build_dir="${WORK_DIR}/10-binutils-build"
    prepare_clean_dir "${build_dir}"
    path_map_flags="$(build_path_map_flags)"

    run_in_dir "${build_dir}" env \
        MAKEINFO=true \
        CFLAGS="${path_map_flags}" \
        CXXFLAGS="${path_map_flags}" \
        "${binutils_source_dir}/configure" \
        --prefix="${CONFIGURE_PREFIX}" \
        --target="${TARGET_TRIPLE}" \
        --with-sysroot="${CONFIGURE_SYSROOT}" \
        --disable-multilib \
        --disable-nls \
        --disable-werror

    run_in_dir "${build_dir}" make MAKEINFO=true -j "${JOBS}"
    run_in_dir "${build_dir}" make MAKEINFO=true DESTDIR="${INSTALL_DIR}" install
}

main "$@"