#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

main() {
    local linux_source_dir

    ensure_source_tree linux "${LINUX_HEADERS_VERSION}" linux_source_dir
    ensure_dir "${SYSROOT_DIR}/usr"

    run_in_dir "${linux_source_dir}" make ARCH=arm INSTALL_HDR_PATH="${SYSROOT_DIR}/usr" headers_install
}

main "$@"