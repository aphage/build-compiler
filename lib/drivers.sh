#!/usr/bin/env bash

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

detect_runtime_library_dir() {
    local candidate

    for candidate in \
        "${SYSROOT_DIR}/usr/lib/${TARGET_TRIPLE}" \
        "${SYSROOT_DIR}/usr/lib" \
        "${SYSROOT_DIR}/lib"; do
        if [[ -d "${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    printf '%s' "${SYSROOT_DIR}/usr/lib"
}

render_template() {
    local template_path=$1
    local output_path=$2
    local runtime_lib_dir=$3
    local builtins_flag=${4-}

    local sysroot_escaped runtime_lib_dir_escaped builtins_flag_escaped content
    sysroot_escaped="$(escape_sed_replacement "${SYSROOT_DIR}")"
    runtime_lib_dir_escaped="$(escape_sed_replacement "${runtime_lib_dir}")"
    builtins_flag_escaped="$(escape_sed_replacement "${builtins_flag}")"

    content="$(sed \
        -e "s|@SYSROOT_DIR@|${sysroot_escaped}|g" \
        -e "s|@RUNTIME_LIB_DIR@|${runtime_lib_dir_escaped}|g" \
        -e "s|@BUILTINS_FLAG@|${builtins_flag_escaped}|g" \
        "${template_path}")"

    install_text_file "${output_path}" 0644 "${content}"
}

ensure_real_driver() {
    local driver_path=$1
    local out_var_name=$2
    local real_driver_path="${driver_path}.real"

    if [[ ! -e "${driver_path}" && -e "${real_driver_path}" ]]; then
        printf -v "${out_var_name}" '%s' "${real_driver_path}"
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] would move ${driver_path} -> ${real_driver_path}"
        printf -v "${out_var_name}" '%s' "${real_driver_path}"
        return 0
    fi

    if [[ ! -e "${real_driver_path}" ]]; then
        mv "${driver_path}" "${real_driver_path}"
    fi

    printf -v "${out_var_name}" '%s' "${real_driver_path}"
}

write_compiler_wrapper() {
    local wrapper_path=$1
    local real_driver_path=$2
    local include_args=$3
    local common_args=$4
    local link_args=$5
    local specs_args=$6

    local wrapper_content
    wrapper_content=$(cat <<EOF
#!/usr/bin/env bash

set -euo pipefail

REAL_DRIVER="${real_driver_path}"
COMMON_ARGS=( ${common_args} )
INCLUDE_ARGS=( ${include_args} )
LINK_ARGS=( ${link_args} )
SPECS_ARGS=( ${specs_args} )

is_link_step=1
for arg in "\$@"; do
    case "\$arg" in
        -c|-S|-E|-M|-MM|-fsyntax-only)
            is_link_step=0
            ;;
    esac
done

final_args=( "\${COMMON_ARGS[@]}" "\${SPECS_ARGS[@]}" )
if [[ \${#INCLUDE_ARGS[@]} -gt 0 ]]; then
    final_args+=( "\${INCLUDE_ARGS[@]}" )
fi

if [[ "\${is_link_step}" -eq 1 && \${#LINK_ARGS[@]} -gt 0 ]]; then
    exec "\${REAL_DRIVER}" "\${final_args[@]}" "\$@" "\${LINK_ARGS[@]}"
fi

exec "\${REAL_DRIVER}" "\${final_args[@]}" "\$@"
EOF
)

    install_text_file "${wrapper_path}" 0755 "${wrapper_content}"
}

install_runtime_wrappers() {
    local support_dir runtime_lib_dir libcxx_specs_path llvmlibc_specs_path
    local gcc_driver gcc_real_driver gxx_driver gxx_real_driver
    local gcc_specs_args gxx_specs_args gcc_link_args gxx_link_args
    local gxx_include_args gxx_common_args gcc_common_args builtins_flag

    support_dir="${PREFIX_DIR}/lib/toolchain"
    runtime_lib_dir="$(detect_runtime_library_dir)"
    ensure_dir "${support_dir}"

    libcxx_specs_path="${support_dir}/${TARGET_TRIPLE}.libcxx.specs"
    llvmlibc_specs_path="${support_dir}/${TARGET_TRIPLE}.llvmlibc.specs"
    builtins_flag=""

    if [[ "${CXX_RUNTIME}" == "libc++" ]]; then
        render_template "${ROOT_DIR}/templates/libcxx.specs.in" "${libcxx_specs_path}" "${runtime_lib_dir}" "${builtins_flag}"
    fi

    if [[ "${LIBC_VARIANT}" == "llvm-libc" ]]; then
        render_template "${ROOT_DIR}/templates/llvmlibc.specs.in" "${llvmlibc_specs_path}" "${runtime_lib_dir}" "${builtins_flag}"
    fi

    gcc_driver="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-gcc"
    gxx_driver="${PREFIX_DIR}/bin/${TARGET_TRIPLE}-g++"
    ensure_real_driver "${gcc_driver}" gcc_real_driver
    ensure_real_driver "${gxx_driver}" gxx_real_driver

    gcc_specs_args=""
    gxx_specs_args=""
    gcc_link_args=""
    gxx_link_args=""
    gcc_common_args="--sysroot \"${SYSROOT_DIR}\""
    gxx_common_args="--sysroot \"${SYSROOT_DIR}\""
    gxx_include_args=""

    if [[ "${LIBC_VARIANT}" == "llvm-libc" ]]; then
        gcc_specs_args="\"-specs=${llvmlibc_specs_path}\""
        gxx_specs_args="\"-specs=${llvmlibc_specs_path}\""
    fi

    if [[ "${CXX_RUNTIME}" == "libc++" ]]; then
        if [[ -d "${SYSROOT_DIR}/usr/include/c++/v1" ]]; then
            gxx_include_args="\"-nostdinc++\" \"-isystem\" \"${SYSROOT_DIR}/usr/include/c++/v1\""
        else
            gxx_include_args="\"-nostdinc++\" \"-isystem\" \"${SYSROOT_DIR}/usr/include/c++/v1\""
        fi

        gxx_common_args="${gxx_common_args} \"-nostdlib++\""
        if [[ -n "${gxx_specs_args}" ]]; then
            gxx_specs_args="${gxx_specs_args} \"-specs=${libcxx_specs_path}\""
        else
            gxx_specs_args="\"-specs=${libcxx_specs_path}\""
        fi
    fi

    write_compiler_wrapper "${gcc_driver}" "${gcc_real_driver}" "" "${gcc_common_args}" "${gcc_link_args}" "${gcc_specs_args}"
    write_compiler_wrapper "${gxx_driver}" "${gxx_real_driver}" "${gxx_include_args}" "${gxx_common_args}" "${gxx_link_args}" "${gxx_specs_args}"
}