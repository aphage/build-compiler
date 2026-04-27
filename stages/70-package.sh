#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"

main() {
    local artifact_path

    artifact_path="${ARTIFACTS_DIR}/${BUILD_NAME}.tar.xz"
    run_cmd tar -C "${ROOT_DIR}" -caf "${artifact_path}" \
        "install/${BUILD_NAME}" \
        "sysroots/${BUILD_NAME}" \
        "artifacts/${BUILD_NAME}.manifest"
}

main "$@"