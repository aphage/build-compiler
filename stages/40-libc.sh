#!/usr/bin/env bash

set -euo pipefail

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/versions.sh"
source "${ROOT_DIR}/lib/download.sh"

build_target_libgcc() {
    local gcc_build_dir="${WORK_DIR}/30-gcc-stage1-build"

    run_in_dir "${gcc_build_dir}" make MAKEINFO=true -j "${JOBS}" all-target-libgcc
    run_in_dir "${gcc_build_dir}" make MAKEINFO=true install-target-libgcc
}

build_glibc_into() {
    local destination_sysroot=$1
    local glibc_source_dir build_dir target_cc target_cppflags target_cflags

    ensure_source_tree glibc "${GLIBC_VERSION}" glibc_source_dir
    build_dir="${WORK_DIR}/40-glibc-build-$(basename "${destination_sysroot}")"
    prepare_clean_dir "${build_dir}"
    ensure_dir "${destination_sysroot}/usr/include"
    ensure_dir "${destination_sysroot}/usr/lib"

    target_cc="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-gcc --sysroot=${destination_sysroot} -march=${TARGET_MARCH} -mfloat-abi=${TARGET_FLOAT_ABI} -mfpu=${TARGET_FPU}"
    target_cppflags="--sysroot=${destination_sysroot}"
    target_cflags="-O2 -march=${TARGET_MARCH} -mfloat-abi=${TARGET_FLOAT_ABI} -mfpu=${TARGET_FPU}"

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
}

build_musl_into() {
    local destination_sysroot=$1
    local musl_source_dir build_dir

    ensure_source_tree musl "${MUSL_VERSION}" musl_source_dir
    build_dir="${WORK_DIR}/40-musl-build"
    prepare_clean_dir "${build_dir}"

    run_in_dir "${build_dir}" env \
        "CC=${PREFIX_DIR}/bin/${TARGET_TRIPLE}-gcc --sysroot=${destination_sysroot}" \
        "AR=${PREFIX_DIR}/bin/${TARGET_TRIPLE}-ar" \
        "RANLIB=${PREFIX_DIR}/bin/${TARGET_TRIPLE}-ranlib" \
        "CFLAGS=--sysroot=${destination_sysroot} -march=${TARGET_MARCH} -mfloat-abi=${TARGET_FLOAT_ABI} -mfpu=${TARGET_FPU}" \
        "${musl_source_dir}/configure" \
        --prefix=/usr \
        --target="${TARGET_TRIPLE}" \
        --syslibdir=/lib

    run_in_dir "${build_dir}" make install-headers DESTDIR="${destination_sysroot}"
    build_target_libgcc

    run_in_dir "${build_dir}" make -j "${JOBS}"
    run_in_dir "${build_dir}" make install DESTDIR="${destination_sysroot}"
}

build_llvm_libc_into() {
    local destination_sysroot=$1
    local donor_sysroot=$2
    local llvm_source_dir build_dir

    ensure_source_tree llvm-project "${LLVM_PROJECT_VERSION}" llvm_source_dir
    build_dir="${WORK_DIR}/40-llvm-libc-build"
    prepare_clean_dir "${build_dir}"

    run_cmd cmake \
        -B "${build_dir}" \
        -S "${llvm_source_dir}/runtimes" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DLLVM_ENABLE_RUNTIMES=libc \
        -DLLVM_LIBC_FULL_BUILD=ON \
        -DLIBC_TARGET_TRIPLE="${TARGET_TRIPLE}" \
        -DLIBC_KERNEL_HEADERS="${destination_sysroot}/usr/include" \
        -DCMAKE_INSTALL_PREFIX=/usr

    run_cmd cmake --build "${build_dir}" --parallel "${JOBS}" --target libc
    run_cmd env DESTDIR="${destination_sysroot}" cmake --install "${build_dir}"

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
            donor_sysroot="${WORK_DIR}/glibc-donor-sysroot"
            build_glibc_into "${donor_sysroot}"
            build_llvm_libc_into "${SYSROOT_DIR}" "${donor_sysroot}"
            ;;
    esac
}

main "$@"