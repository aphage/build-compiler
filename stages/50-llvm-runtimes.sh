#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

main() {
    local llvm_source_dir build_dir runtime_source_dir compiler_bin cxx_compiler_bin extra_target_flags=()

    if [[ "${CXX_RUNTIME}" != "libc++" ]]; then
        log "skipping LLVM runtimes stage because C++ runtime is ${CXX_RUNTIME}"
        return 0
    fi

    ensure_source_tree llvm-project "${LLVM_PROJECT_VERSION}" llvm_source_dir
    runtime_source_dir="${llvm_source_dir}/runtimes"
    build_dir="${WORK_DIR}/50-llvm-runtimes-build"
    prepare_clean_dir "${build_dir}"

    if command_exists clang && command_exists clang++; then
        compiler_bin=clang
        cxx_compiler_bin=clang++
        extra_target_flags=(
            -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}"
            -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}"
            -DCMAKE_ASM_COMPILER_TARGET="${TARGET_TRIPLE}"
        )
    else
        compiler_bin="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-gcc"
        cxx_compiler_bin="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-g++"
        extra_target_flags=()
    fi

    run_cmd cmake \
        -B "${build_dir}" \
        -S "${runtime_source_dir}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="${compiler_bin}" \
        -DCMAKE_CXX_COMPILER="${cxx_compiler_bin}" \
        -DCMAKE_SYSROOT="${SYSROOT_DIR}" \
        -DCMAKE_C_FLAGS="-march=${TARGET_MARCH}" \
        -DCMAKE_CXX_FLAGS="-march=${TARGET_MARCH}" \
        -DCMAKE_ASM_FLAGS="-march=${TARGET_MARCH}" \
        -DLLVM_ENABLE_RUNTIMES=compiler-rt\;libunwind\;libcxxabi\;libcxx \
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
        -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}" \
        -DLLVM_TARGETS_TO_BUILD=ARM \
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLIBUNWIND_ENABLE_ARM_EHABI=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DCMAKE_INSTALL_PREFIX=/usr \
        "${extra_target_flags[@]}"

    run_cmd cmake --build "${build_dir}" --parallel "${JOBS}" --target builtins unwind cxxabi cxx
    run_cmd env DESTDIR="${SYSROOT_DIR}" cmake --install "${build_dir}"
}

main "$@"