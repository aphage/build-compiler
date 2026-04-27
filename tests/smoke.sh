#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: tests/smoke.sh <toolchain-prefix> <sysroot>" >&2
    exit 1
fi

TOOLCHAIN_PREFIX=$1
SYSROOT_DIR=$2
TARGET_TRIPLE=${TARGET_TRIPLE:-$(basename "${TOOLCHAIN_PREFIX}" | cut -d- -f1-4)}
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