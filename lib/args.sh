#!/usr/bin/env bash

declare -ag CLI_OVERRIDE_NAMES=()
declare -ag CLI_OVERRIDE_VALUES=()
declare -ag POSITIONAL_ARGS=()
declare -g SHOW_HELP=0

load_default_config() {
    local defaults_file

    defaults_file="${ROOT_DIR}/config/defaults.env"
    [[ -r "${defaults_file}" ]] || die "missing default config: ${defaults_file}"

    # shellcheck disable=SC1090
    source "${defaults_file}"
}

load_user_config() {
    if [[ -z "${CONFIG_FILE}" ]]; then
        return 0
    fi

    [[ -r "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
}

queue_override() {
    CLI_OVERRIDE_NAMES+=("$1")
    CLI_OVERRIDE_VALUES+=("$2")
}

apply_cli_overrides() {
    local index

    for index in "${!CLI_OVERRIDE_NAMES[@]}"; do
        printf -v "${CLI_OVERRIDE_NAMES[index]}" '%s' "${CLI_OVERRIDE_VALUES[index]}"
    done
}

require_option_value() {
    local option_name=$1
    local option_value=${2-}

    if [[ -z "${option_value}" ]]; then
        die "${option_name} requires a value"
    fi
}

parse_args() {
    local option value

    while [[ $# -gt 0 ]]; do
        option=$1

        case "${option}" in
            --config)
                shift
                require_option_value "--config" "${1-}"
                CONFIG_FILE=$1
                ;;
            --config=*)
                CONFIG_FILE=${option#*=}
                require_option_value "--config" "${CONFIG_FILE}"
                ;;
            --host)
                shift
                require_option_value "--host" "${1-}"
                queue_override HOST_TRIPLE "$1"
                ;;
            --host=*)
                queue_override HOST_TRIPLE "${option#*=}"
                ;;
            --target)
                shift
                require_option_value "--target" "${1-}"
                TARGET_TRIPLE_EXPLICIT=1
                queue_override TARGET_TRIPLE "$1"
                ;;
            --target=*)
                TARGET_TRIPLE_EXPLICIT=1
                queue_override TARGET_TRIPLE "${option#*=}"
                ;;
            --libc)
                shift
                require_option_value "--libc" "${1-}"
                queue_override LIBC_VARIANT "$1"
                ;;
            --libc=*)
                queue_override LIBC_VARIANT "${option#*=}"
                ;;
            --cxx-runtime)
                shift
                require_option_value "--cxx-runtime" "${1-}"
                queue_override CXX_RUNTIME "$1"
                ;;
            --cxx-runtime=*)
                queue_override CXX_RUNTIME "${option#*=}"
                ;;
            --jobs)
                shift
                require_option_value "--jobs" "${1-}"
                queue_override JOBS "$1"
                ;;
            --jobs=*)
                queue_override JOBS "${option#*=}"
                ;;
            --gcc-version)
                shift
                require_option_value "--gcc-version" "${1-}"
                queue_override GCC_VERSION "$1"
                ;;
            --gcc-version=*)
                queue_override GCC_VERSION "${option#*=}"
                ;;
            --binutils-version)
                shift
                require_option_value "--binutils-version" "${1-}"
                queue_override BINUTILS_VERSION "$1"
                ;;
            --binutils-version=*)
                queue_override BINUTILS_VERSION "${option#*=}"
                ;;
            --linux-headers-version)
                shift
                require_option_value "--linux-headers-version" "${1-}"
                queue_override LINUX_HEADERS_VERSION "$1"
                ;;
            --linux-headers-version=*)
                queue_override LINUX_HEADERS_VERSION "${option#*=}"
                ;;
            --glibc-version)
                shift
                require_option_value "--glibc-version" "${1-}"
                queue_override GLIBC_VERSION "$1"
                ;;
            --glibc-version=*)
                queue_override GLIBC_VERSION "${option#*=}"
                ;;
            --musl-version)
                shift
                require_option_value "--musl-version" "${1-}"
                queue_override MUSL_VERSION "$1"
                ;;
            --musl-version=*)
                queue_override MUSL_VERSION "${option#*=}"
                ;;
            --llvm-project-version)
                shift
                require_option_value "--llvm-project-version" "${1-}"
                queue_override LLVM_PROJECT_VERSION "$1"
                ;;
            --llvm-project-version=*)
                queue_override LLVM_PROJECT_VERSION "${option#*=}"
                ;;
            --resume)
                shift
                require_option_value "--resume" "${1-}"
                queue_override RESUME_FROM_STAGE "$1"
                ;;
            --resume=*)
                queue_override RESUME_FROM_STAGE "${option#*=}"
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --check-host-deps)
                CHECK_HOST_DEPS=1
                ;;
            --print-config)
                PRINT_CONFIG=1
                ;;
            --help|-h)
                SHOW_HELP=1
                ;;
            --)
                shift
                POSITIONAL_ARGS+=("$@")
                break
                ;;
            -*)
                die "unknown option: ${option}"
                ;;
            *)
                POSITIONAL_ARGS+=("${option}")
                ;;
        esac

        shift
    done

    value=${JOBS:-}
    if [[ -n "${value}" && ! "${value}" =~ ^[0-9]+$ ]]; then
        die "--jobs must be a positive integer"
    fi
}

show_help() {
    cat <<'EOF'
Usage: build-toolchain.sh [options]

Options:
  --config PATH                  Load a user config file after defaults.
  --host TRIPLE                  Override host triple.
  --target TRIPLE                Override target triple.
  --libc NAME                    Select glibc, musl, or llvm-libc.
  --cxx-runtime NAME             Select libstdc++ or libc++.
  --jobs N                       Set parallel job count.
  --gcc-version VERSION          Override GCC version.
  --binutils-version VERSION     Override binutils version.
  --linux-headers-version VER    Override Linux headers version.
  --glibc-version VERSION        Override glibc version.
  --musl-version VERSION         Override musl version.
  --llvm-project-version VER     Override LLVM project version.
  --resume STAGE                 Resume from a specific stage.
    --check-host-deps              Validate required host tools.
  --print-config                 Print the resolved configuration.
  --dry-run                      Validate the config without building.
  --help                         Show this help text.
EOF
}

print_config() {
    cat <<EOF
ROOT_DIR=${ROOT_DIR}
HOST_TRIPLE=${HOST_TRIPLE}
TARGET_TRIPLE=${TARGET_TRIPLE}
LIBC_VARIANT=${LIBC_VARIANT}
CXX_RUNTIME=${CXX_RUNTIME}
JOBS=${JOBS}
GCC_VERSION=${GCC_VERSION}
BINUTILS_VERSION=${BINUTILS_VERSION}
LINUX_HEADERS_VERSION=${LINUX_HEADERS_VERSION}
GLIBC_VERSION=${GLIBC_VERSION}
MUSL_VERSION=${MUSL_VERSION}
LLVM_PROJECT_VERSION=${LLVM_PROJECT_VERSION}
CONFIG_FILE=${CONFIG_FILE}
RESUME_FROM_STAGE=${RESUME_FROM_STAGE}
CHECK_HOST_DEPS=${CHECK_HOST_DEPS}
DOWNLOADS_DIR=${DOWNLOADS_DIR}
BUILD_DIR=${BUILD_DIR}
INSTALL_DIR=${INSTALL_DIR}
SYSROOTS_DIR=${SYSROOTS_DIR}
LOGS_DIR=${LOGS_DIR}
ARTIFACTS_DIR=${ARTIFACTS_DIR}
SOURCE_CACHE_DIR=${SOURCE_CACHE_DIR}
BUILD_NAME=${BUILD_NAME:-}
WORK_DIR=${WORK_DIR:-}
PREFIX_DIR=${PREFIX_DIR:-}
SYSROOT_DIR=${SYSROOT_DIR:-}
MANIFEST_PATH=${MANIFEST_PATH:-}
COMBO_STATUS=${COMBO_STATUS:-}
COMBO_NOTE=${COMBO_NOTE:-}
GCC_ARCHIVE=${GCC_ARCHIVE:-}
GCC_URL=${GCC_URL:-}
BINUTILS_ARCHIVE=${BINUTILS_ARCHIVE:-}
BINUTILS_URL=${BINUTILS_URL:-}
LINUX_HEADERS_ARCHIVE=${LINUX_HEADERS_ARCHIVE:-}
LINUX_HEADERS_URL=${LINUX_HEADERS_URL:-}
GLIBC_ARCHIVE=${GLIBC_ARCHIVE:-}
GLIBC_URL=${GLIBC_URL:-}
MUSL_ARCHIVE=${MUSL_ARCHIVE:-}
MUSL_URL=${MUSL_URL:-}
LLVM_PROJECT_ARCHIVE=${LLVM_PROJECT_ARCHIVE:-}
LLVM_PROJECT_URL=${LLVM_PROJECT_URL:-}
EOF
}