#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

main() {
    local llvm_source_dir build_dir runtime_source_dir compiler_bin cxx_compiler_bin host_clang_resource_dir path_map_flags runtime_flags extra_target_flags=() extra_runtime_cmake_flags=()

    if [[ "${CXX_RUNTIME}" != "libc++" ]]; then
        log "skipping LLVM runtimes stage because C++ runtime is ${CXX_RUNTIME}"
        return 0
    fi

    ensure_source_tree llvm-project "${LLVM_PROJECT_VERSION}" llvm_source_dir
    runtime_source_dir="${llvm_source_dir}/runtimes"
    build_dir="${WORK_DIR}/50-llvm-runtimes-build"
    prepare_clean_dir "${build_dir}"
    path_map_flags="$(build_path_map_flags)"
    runtime_flags="-march=${TARGET_MARCH} ${path_map_flags}"

    if command_exists clang && command_exists clang++; then
        compiler_bin=clang
        cxx_compiler_bin=clang++
        host_clang_resource_dir="$(clang --print-resource-dir)"
        runtime_flags="${runtime_flags} --gcc-toolchain=${PREFIX_DIR} -resource-dir=${build_dir}/compiler-rt -isystem ${host_clang_resource_dir}/include"
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

    if [[ "${LIBC_VARIANT}" == "musl" ]]; then
        extra_runtime_cmake_flags=(
            -DLIBCXX_HAS_MUSL_LIBC=ON
            -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF
        )
    elif [[ "${LIBC_VARIANT}" == "llvm-libc" ]]; then
        extra_runtime_cmake_flags=(
            -DLIBUNWIND_ENABLE_SHARED=OFF
            -DLIBUNWIND_ENABLE_STATIC=ON
            -DLIBCXXABI_ENABLE_SHARED=OFF
            -DLIBCXXABI_ENABLE_STATIC=ON
            -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON
            -DLIBCXX_ENABLE_SHARED=OFF
            -DLIBCXX_ENABLE_STATIC=ON
            -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
        )
    fi

    run_cmd cmake \
        -B "${build_dir}" \
        -S "${runtime_source_dir}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_COMPILER="${compiler_bin}" \
        -DCMAKE_CXX_COMPILER="${cxx_compiler_bin}" \
        -DCMAKE_SYSROOT="${SYSROOT_DIR}" \
        -DCMAKE_C_FLAGS="${runtime_flags}" \
        -DCMAKE_CXX_FLAGS="${runtime_flags}" \
        -DCMAKE_ASM_FLAGS="${runtime_flags}" \
        -DLLVM_ENABLE_RUNTIMES=compiler-rt\;libunwind\;libcxxabi\;libcxx \
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
        -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}" \
        -DLLVM_TARGETS_TO_BUILD=ARM \
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_BUILD_CRT=ON \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF \
        -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
        -DCOMPILER_RT_BUILD_MEMPROF=OFF \
        -DCOMPILER_RT_BUILD_ORC=OFF \
        -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLIBUNWIND_ENABLE_ARM_EHABI=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_HAS_ATOMIC_LIB=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr \
        "${extra_runtime_cmake_flags[@]}" \
        "${extra_target_flags[@]}"

    run_cmd cmake --build "${build_dir}" --parallel "${JOBS}" --target compiler-rt
    run_cmd cmake --build "${build_dir}" --parallel "${JOBS}" --target unwind cxxabi cxx cxx_experimental
    run_cmd env DESTDIR="${SYSROOT_DIR}" cmake --install "${build_dir}"
}

main "$@"