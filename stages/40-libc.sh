#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

build_target_libgcc() {
    local gcc_build_dir="${WORK_DIR}/30-gcc-stage1-build"

    run_in_dir "${gcc_build_dir}" make MAKEINFO=true -j "${JOBS}" all-target-libgcc
    run_in_dir "${gcc_build_dir}" make MAKEINFO=true DESTDIR="${INSTALL_DIR}" install-target-libgcc
}

find_glibc_donor_sysroot() {
    local donor_prefix candidate_sysroot
    local -a donor_prefixes=()

    shopt -s nullglob
    donor_prefixes=(
        "${INSTALL_DIR}/${TARGET_GLIBC_TRIPLE}-glibc-"*"-gcc-${GCC_VERSION}-binutils-${BINUTILS_VERSION}-linux-${LINUX_HEADERS_VERSION}"
    )
    shopt -u nullglob

    for donor_prefix in "${donor_prefixes[@]}"; do
        candidate_sysroot="${donor_prefix}/${TARGET_GLIBC_TRIPLE}/sysroot"
        if [[ -f "${candidate_sysroot}/lib/ld-linux-armhf.so.3" ]] &&
            [[ -f "${candidate_sysroot}/usr/lib/crt1.o" ]] &&
            [[ -f "${candidate_sysroot}/usr/lib/crti.o" ]] &&
            [[ -f "${candidate_sysroot}/usr/lib/crtn.o" ]]; then
            printf '%s' "${candidate_sysroot}"
            return 0
        fi
    done

    die "llvm-libc route requires a prebuilt glibc donor sysroot under ${INSTALL_DIR}; build a matching glibc toolchain first"
}

install_glibc_linker_script() {
    local destination_sysroot=$1
    local libc_linker_script

    libc_linker_script=$(cat <<'EOF'
/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
GROUP ( /lib/libc.so.6 /usr/lib/libc_nonshared.a  AS_NEEDED ( /lib/ld-linux-armhf.so.3 ) )
EOF
)

    install_text_file "${destination_sysroot}/usr/lib/libc.so" 0644 "${libc_linker_script}"
}

build_glibc_into() {
    local destination_sysroot=$1
    local glibc_source_dir build_dir target_cc target_cppflags target_cflags path_map_flags

    ensure_source_tree glibc "${GLIBC_VERSION}" glibc_source_dir
    build_dir="${WORK_DIR}/40-glibc-build-$(basename "${destination_sysroot}")"
    prepare_clean_dir "${build_dir}"
    ensure_dir "${destination_sysroot}/usr/include"
    ensure_dir "${destination_sysroot}/usr/lib"
    path_map_flags="$(build_path_map_flags)"

    target_cc="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-gcc --sysroot=${destination_sysroot} -march=${TARGET_MARCH} -mfloat-abi=${TARGET_FLOAT_ABI} -mfpu=${TARGET_FPU}"
    target_cppflags="--sysroot=${destination_sysroot} ${path_map_flags}"
    target_cflags="-O2 -march=${TARGET_MARCH} -mfloat-abi=${TARGET_FLOAT_ABI} -mfpu=${TARGET_FPU} ${path_map_flags}"

    run_in_dir "${build_dir}" env \
        BUILD_CC=gcc \
        CC="${target_cc}" \
        AR="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-ar" \
        AS="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-as" \
        LD="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-ld" \
        NM="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-nm" \
        CPPFLAGS="${target_cppflags}" \
        CFLAGS="${target_cflags}" \
        LDFLAGS="${target_cppflags}" \
        RANLIB="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-ranlib" \
        READELF="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-readelf" \
        "${glibc_source_dir}/configure" \
        --prefix=/usr \
        --build="${HOST_TRIPLE}" \
        --host="${TARGET_TRIPLE}" \
        --with-headers="${destination_sysroot}/usr/include" \
        --disable-multilib \
        --disable-werror \
        --enable-kernel="${GLIBC_MIN_KERNEL}"

    run_in_dir "${build_dir}" make -j "${JOBS}" install-bootstrap-headers=yes install-headers cross_compiling=yes install_root="${destination_sysroot}"
    run_in_dir "${build_dir}" make -j "${JOBS}" csu/subdir_lib

    run_cmd install -m 0644 "${build_dir}/csu/crt1.o" "${destination_sysroot}/usr/lib/crt1.o"
    run_cmd install -m 0644 "${build_dir}/csu/crti.o" "${destination_sysroot}/usr/lib/crti.o"
    run_cmd install -m 0644 "${build_dir}/csu/crtn.o" "${destination_sysroot}/usr/lib/crtn.o"
    run_cmd \
        "${PREFIX_DIR}/bin/${TARGET_TRIPLE}-gcc" \
        "--sysroot=${destination_sysroot}" \
        "-march=${TARGET_MARCH}" \
        "-mfloat-abi=${TARGET_FLOAT_ABI}" \
        "-mfpu=${TARGET_FPU}" \
        -nostdlib \
        -nostartfiles \
        -shared \
        -x c /dev/null \
        -o "${destination_sysroot}/usr/lib/libc.so"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[dry-run] touch ${destination_sysroot}/usr/include/gnu/stubs.h"
    else
        ensure_dir "${destination_sysroot}/usr/include/gnu"
        : >"${destination_sysroot}/usr/include/gnu/stubs.h"
    fi

    build_target_libgcc

    run_in_dir "${build_dir}" make -j "${JOBS}"
    run_in_dir "${build_dir}" make install install_root="${destination_sysroot}"
    install_glibc_linker_script "${destination_sysroot}"
    rewrite_internal_absolute_symlinks "${destination_sysroot}"
}

configure_musl() {
    local destination_sysroot=$1
    local musl_source_dir=$2
    local build_dir=$3
    local path_map_flags=$4

    run_in_dir "${build_dir}" env \
        "CC=${PREFIX_DIR}/bin/${TARGET_TRIPLE}-gcc --sysroot=${destination_sysroot}" \
        "AR=${PREFIX_DIR}/bin/${TARGET_TRIPLE}-ar" \
        "RANLIB=${PREFIX_DIR}/bin/${TARGET_TRIPLE}-ranlib" \
        "CFLAGS=--sysroot=${destination_sysroot} -march=${TARGET_MARCH} -mfloat-abi=${TARGET_FLOAT_ABI} -mfpu=${TARGET_FPU} ${path_map_flags}" \
        "${musl_source_dir}/configure" \
        --prefix=/usr \
        --target="${TARGET_TRIPLE}" \
        --syslibdir=/lib
}

build_musl_into() {
    local destination_sysroot=$1
    local musl_source_dir build_dir path_map_flags

    ensure_source_tree musl "${MUSL_VERSION}" musl_source_dir
    build_dir="${WORK_DIR}/40-musl-build"
    prepare_clean_dir "${build_dir}"
    path_map_flags="$(build_path_map_flags)"

    configure_musl "${destination_sysroot}" "${musl_source_dir}" "${build_dir}" "${path_map_flags}"

    run_in_dir "${build_dir}" make install-headers DESTDIR="${destination_sysroot}"
    build_target_libgcc

    # musl records the detected compiler runtime in config.mak during configure.
    configure_musl "${destination_sysroot}" "${musl_source_dir}" "${build_dir}" "${path_map_flags}"

    run_in_dir "${build_dir}" make -j "${JOBS}"
    run_in_dir "${build_dir}" make install DESTDIR="${destination_sysroot}"
    rewrite_internal_absolute_symlinks "${destination_sysroot}"
}

build_host_libc_hdrgen() {
    local llvm_source_dir=$1
    local -n out_hdrgen_path=$2
    local host_build_dir host_c_compiler host_cxx_compiler built_hdrgen_path

    host_build_dir="${WORK_DIR}/40-llvm-libc-tools-build"
    prepare_clean_dir "${host_build_dir}"

    if command_exists clang && command_exists clang++; then
        host_c_compiler=clang
        host_cxx_compiler=clang++
    else
        host_c_compiler=cc
        host_cxx_compiler=c++
    fi

    run_cmd cmake \
        -B "${host_build_dir}" \
        -S "${llvm_source_dir}/llvm" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="${host_c_compiler}" \
        -DCMAKE_CXX_COMPILER="${host_cxx_compiler}" \
        -DLLVM_ENABLE_PROJECTS=libc \
        -DLLVM_LIBC_FULL_BUILD=ON \
        -DLLVM_INCLUDE_TESTS=OFF

    run_cmd cmake --build "${host_build_dir}" --parallel "${JOBS}" --target libc-hdrgen

    built_hdrgen_path="${host_build_dir}/bin/libc-hdrgen"
    [[ -x "${built_hdrgen_path}" ]] || die "failed to build libc-hdrgen at ${built_hdrgen_path}"

    out_hdrgen_path="${built_hdrgen_path}"
}

build_llvm_libc_runtime_headers() {
    local build_dir=$1
    local -a header_targets=(
        "libc/include/__llvm-libc-common.h"
        "libc/include/arpa/inet.h"
        "libc/include/assert.h"
        "libc/include/dirent.h"
        "libc/include/dlfcn.h"
        "libc/include/errno.h"
        "libc/include/fcntl.h"
        "libc/include/features.h"
        "libc/include/fenv.h"
        "libc/include/float.h"
        "libc/include/inttypes.h"
        "libc/include/limits.h"
        "libc/include/math.h"
        "libc/include/pthread.h"
        "libc/include/sched.h"
        "libc/include/search.h"
        "libc/include/setjmp.h"
        "libc/include/signal.h"
        "libc/include/spawn.h"
        "libc/include/stdbit.h"
        "libc/include/stdckdint.h"
        "libc/include/stdfix.h"
        "libc/include/stdint.h"
        "libc/include/stdio.h"
        "libc/include/stdlib.h"
        "libc/include/string.h"
        "libc/include/strings.h"
        "libc/include/sys/auxv.h"
        "libc/include/sys/epoll.h"
        "libc/include/sys/ioctl.h"
        "libc/include/sys/mman.h"
        "libc/include/sys/prctl.h"
        "libc/include/sys/queue.h"
        "libc/include/sys/random.h"
        "libc/include/sys/resource.h"
        "libc/include/sys/select.h"
        "libc/include/sys/sendfile.h"
        "libc/include/sys/socket.h"
        "libc/include/sys/stat.h"
        "libc/include/sys/statvfs.h"
        "libc/include/sys/syscall.h"
        "libc/include/sys/time.h"
        "libc/include/sys/types.h"
        "libc/include/sys/utsname.h"
        "libc/include/sys/wait.h"
        "libc/include/termios.h"
        "libc/include/threads.h"
        "libc/include/time.h"
        "libc/include/uchar.h"
        "libc/include/unistd.h"
        "libc/include/wchar.h"
    )

    run_cmd cmake --build "${build_dir}" --parallel "${JOBS}" --target "${header_targets[@]}"
}

install_llvm_libc_generated_headers() {
    local build_dir=$1
    local destination_sysroot=$2
    local include_build_dir header relative_path

    include_build_dir="${build_dir}/libc/include"
    [[ -d "${include_build_dir}" ]] || die "llvm-libc generated include tree missing at ${include_build_dir}"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[dry-run] would copy generated llvm-libc headers from ${include_build_dir} into ${destination_sysroot}/usr/include"
        return 0
    fi

    ensure_dir "${destination_sysroot}/usr/include"
    while IFS= read -r -d '' header; do
        relative_path="${header#${include_build_dir}/}"
        ensure_dir "$(dirname "${destination_sysroot}/usr/include/${relative_path}")"
        run_cmd install -m 0644 "${header}" "${destination_sysroot}/usr/include/${relative_path}"
    done < <(find "${include_build_dir}" -type f -name '*.h' -print0)
}

install_glibc_donor_headers() {
    local donor_sysroot=$1
    local destination_sysroot=$2

    [[ -d "${donor_sysroot}/usr/include" ]] || die "glibc donor headers missing under ${donor_sysroot}/usr/include"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[dry-run] would copy donor glibc headers from ${donor_sysroot}/usr/include into ${destination_sysroot}/usr/include"
        return 0
    fi

    ensure_dir "${destination_sysroot}/usr/include"
    cp -a "${donor_sysroot}/usr/include/." "${destination_sysroot}/usr/include/"
}

install_glibc_donor_runtime_surface() {
    local donor_sysroot=$1
    local destination_sysroot=$2
    local runtime_lib_dir relative_path destination_path
    local -a donor_runtime_paths=(
        "lib/ld-linux-armhf.so.3"
        "lib/libc.so.6"
        "lib/libdl.so.2"
        "lib/libm.so.6"
        "lib/libpthread.so.0"
        "lib/librt.so.1"
        "usr/lib/libc.so"
        "usr/lib/libc_nonshared.a"
        "usr/lib/libdl.a"
        "usr/lib/libm.a"
        "usr/lib/libm.so"
        "usr/lib/libpthread.a"
        "usr/lib/librt.a"
    )

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[dry-run] would copy donor glibc runtime surface from ${donor_sysroot} into ${destination_sysroot}"
        return 0
    fi

    runtime_lib_dir="${destination_sysroot}/usr/lib/${TARGET_TRIPLE}"
    ensure_dir "${destination_sysroot}/lib"
    ensure_dir "${destination_sysroot}/usr/lib"
    ensure_dir "${runtime_lib_dir}"

    for relative_path in "${donor_runtime_paths[@]}"; do
        [[ -e "${donor_sysroot}/${relative_path}" ]] || continue
        destination_path="${destination_sysroot}/${relative_path}"
        ensure_dir "$(dirname "${destination_path}")"
        cp -a "${donor_sysroot}/${relative_path}" "${destination_path}"
    done

    if [[ -f "${destination_sysroot}/usr/lib/libc.so" ]]; then
        ln -sf ../libc.so "${runtime_lib_dir}/libc.so"
    fi
    if [[ -f "${destination_sysroot}/usr/lib/libm.so" ]]; then
        ln -sf ../libm.so "${runtime_lib_dir}/libm.so"
    fi
    if [[ -f "${destination_sysroot}/lib/libdl.so.2" ]]; then
        ln -sf ../../lib/libdl.so.2 "${runtime_lib_dir}/libdl.so"
    fi
    if [[ -f "${destination_sysroot}/lib/libpthread.so.0" ]]; then
        ln -sf ../../lib/libpthread.so.0 "${runtime_lib_dir}/libpthread.so"
    fi
    if [[ -f "${destination_sysroot}/lib/librt.so.1" ]]; then
        ln -sf ../../lib/librt.so.1 "${runtime_lib_dir}/librt.so"
    fi
}

build_llvm_libc_into() {
    local destination_sysroot=$1
    local donor_sysroot=$2
    local llvm_source_dir build_dir path_map_flags compiler_flags hdrgen_path

    ensure_source_tree llvm-project "${LLVM_PROJECT_VERSION}" llvm_source_dir
    build_dir="${WORK_DIR}/40-llvm-libc-build"
    prepare_clean_dir "${build_dir}"
    path_map_flags="$(build_path_map_flags)"
    compiler_flags="-march=${TARGET_MARCH} -mfloat-abi=${TARGET_FLOAT_ABI} -mfpu=${TARGET_FPU} ${path_map_flags} --gcc-toolchain=${PREFIX_DIR} --sysroot=${destination_sysroot}"
    build_host_libc_hdrgen "${llvm_source_dir}" hdrgen_path

    run_cmd cmake \
        -B "${build_dir}" \
        -S "${llvm_source_dir}/runtimes" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_SYSROOT="${destination_sysroot}" \
        -DCMAKE_C_FLAGS="${compiler_flags}" \
        -DCMAKE_CXX_FLAGS="${compiler_flags}" \
        -DCMAKE_ASM_FLAGS="${compiler_flags}" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_ENABLE_RUNTIMES=libc \
        -DLLVM_LIBC_FULL_BUILD=ON \
        -DLIBC_HDRGEN_EXE="${hdrgen_path}" \
        -DLIBC_TARGET_TRIPLE="${TARGET_TRIPLE}" \
        -DLIBC_KERNEL_HEADERS="${destination_sysroot}/usr/include" \
        -DCMAKE_INSTALL_PREFIX=/usr

    run_cmd cmake --build "${build_dir}" --parallel "${JOBS}" --target libc libm
    build_llvm_libc_runtime_headers "${build_dir}"
    run_cmd env DESTDIR="${destination_sysroot}" cmake --install "${build_dir}"
    install_llvm_libc_generated_headers "${build_dir}" "${destination_sysroot}"
    install_glibc_donor_headers "${donor_sysroot}" "${destination_sysroot}"
    install_glibc_donor_runtime_surface "${donor_sysroot}" "${destination_sysroot}"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "[dry-run] would copy glibc donor loader and startup files from ${donor_sysroot}"
        return 0
    fi

    ensure_dir "${destination_sysroot}/lib"
    ensure_dir "${destination_sysroot}/usr/lib"
    if [[ -f "${donor_sysroot}/lib/ld-linux-armhf.so.3" ]]; then
        cp -a "${donor_sysroot}/lib/ld-linux-armhf.so.3" "${destination_sysroot}/lib/ld-linux-armhf.so.3"
    fi

    for startup_file in crt1.o crti.o crtn.o; do
        if [[ -f "${donor_sysroot}/usr/lib/${startup_file}" ]]; then
            cp -a "${donor_sysroot}/usr/lib/${startup_file}" "${destination_sysroot}/usr/lib/${startup_file}"
        fi
    done

    if [[ -f "${destination_sysroot}/usr/lib/libllvmlibc.a" && ! -e "${destination_sysroot}/usr/lib/libc.a" ]]; then
        ln -sf libllvmlibc.a "${destination_sysroot}/usr/lib/libc.a"
    fi

    rewrite_internal_absolute_symlinks "${destination_sysroot}"
}

main() {
    local donor_sysroot

    case "${LIBC_VARIANT}" in
        glibc)
            build_glibc_into "${SYSROOT_DIR}"
            ;;
        musl)
            build_musl_into "${SYSROOT_DIR}"
            ;;
        llvm-libc)
            donor_sysroot="$(find_glibc_donor_sysroot)"
            log "using prebuilt glibc donor sysroot ${donor_sysroot} for llvm-libc"
            build_llvm_libc_into "${SYSROOT_DIR}" "${donor_sysroot}"
            ;;
    esac
}

main "$@"