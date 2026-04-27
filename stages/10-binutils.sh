#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

main() {
    local binutils_source_dir build_dir

    ensure_source_tree binutils "${BINUTILS_VERSION}" binutils_source_dir
    build_dir="${WORK_DIR}/10-binutils-build"
    prepare_clean_dir "${build_dir}"

    run_in_dir "${build_dir}" env \
        MAKEINFO=true \
        "${binutils_source_dir}/configure" \
        --prefix="${PREFIX_DIR}" \
        --target="${TARGET_TRIPLE}" \
        --with-sysroot="${SYSROOT_DIR}" \
        --disable-multilib \
        --disable-nls \
        --disable-werror

    run_in_dir "${build_dir}" make MAKEINFO=true -j "${JOBS}"
    run_in_dir "${build_dir}" make MAKEINFO=true install
}

main "$@"