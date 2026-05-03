#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"

main() {
    local artifact_path

    artifact_path="${ARTIFACTS_DIR}/${BUILD_NAME}.tar.xz"
    sanitize_text_paths_in_tree "${PREFIX_DIR}"
    sanitize_remaining_root_paths_in_tree "${PREFIX_DIR}"
    strip_debug_symbols_in_tree "${PREFIX_DIR}"
    run_cmd tar -C "${ROOT_DIR}" -caf "${artifact_path}" \
        "install/${BUILD_NAME}" \
        "artifacts/${BUILD_NAME}.manifest"
}

main "$@"