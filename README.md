# ARM GCC Cross Toolchain Builder

This repository builds a GCC-based cross toolchain on `x86_64 Ubuntu 24.04`.

Current v1 scope:

- Host: `x86_64 Ubuntu 24.04`
- ARM glibc target: `arm-linux-gnueabihf`
- ARM musl target: `arm-linux-musleabihf`
- ARM llvm-libc target: `arm-linux-gnueabihf`
- libc choices: `glibc`, `musl`, `llvm-libc`
- C++ runtime choices: `libstdc++`, `libc++`

Supported runtime matrix:

- `glibc + libstdc++`
- `glibc + libc++`
- `musl + libstdc++`
- `musl + libc++`
- `llvm-libc + libc++`

Rejected in v1:

- `llvm-libc + libstdc++`

## Layout

- `build-toolchain.sh`: main entrypoint
- `config/`: defaults, checksum metadata, dependency list, supported combos
- `lib/`: shared Bash helpers
- `stages/`: ordered build stages
- `templates/`: generated specs fragments used by wrapper drivers
- `tests/smoke.sh`: basic compile-only smoke test script

## Prerequisites

Check host tools:

```bash
./build-toolchain.sh --check-host-deps
```

Typical Ubuntu 24.04 setup for the full matrix:

```bash
sudo apt install build-essential curl gawk sed grep bison flex patch python3 xz-utils tar cmake ninja-build clang lld
```

## Examples

Print the resolved configuration:

```bash
./build-toolchain.sh --print-config --dry-run
```

Dry-run the stable GNU baseline:

```bash
./build-toolchain.sh --libc glibc --cxx-runtime libstdc++ --dry-run
```

Build a musl toolchain using LLVM libc++:

```bash
./build-toolchain.sh --libc musl --cxx-runtime libc++
```

Build the llvm-libc route:

```bash
./build-toolchain.sh --libc llvm-libc --cxx-runtime libc++
```

## GitHub Actions

The repository includes a manual workflow at `.github/workflows/build-toolchain.yml` for running full builds on GitHub-hosted `ubuntu-24.04` runners.

- Trigger it from the Actions tab with the `Build Cross Toolchain` workflow.
- Select one supported `combo` input instead of mixing `--libc` and `--cxx-runtime` manually.
- Override individual component versions through the workflow inputs when needed.
- Successful runs upload `artifacts/*.tar.xz` and the matching `.manifest` file.
- Build logs are always uploaded as a separate workflow artifact.
- `run_smoke_tests` can be left enabled to run `tests/smoke.sh` after the build finishes.

The workflow is intentionally `workflow_dispatch` only because full cross-toolchain builds are long-running and disk-heavy.

Override individual component versions:

```bash
./build-toolchain.sh \
  --libc glibc \
  --cxx-runtime libc++ \
  --gcc-version 14.2.0 \
  --binutils-version 2.43 \
  --linux-headers-version 6.6.58 \
  --glibc-version 2.40 \
  --llvm-project-version 19.1.7
```

Resume from a later stage:

```bash
./build-toolchain.sh --resume 50-llvm-runtimes
```

## Notes

- `llvm-libc` support in v1 uses a hybrid boundary: the target sysroot still carries ARM glibc's `ld-linux-armhf.so.3` loader.
- When `libc++` is selected, the final GCC drivers are wrapped instead of patching GCC's installed specs in place.
- The generated wrappers use `-nostdlib++` and generated specs fragments so `g++` defaults to `libc++` for that build output.
- The downloader uses the repository's own checksum table for deterministic validation.

## Smoke Test

After a successful build, compile sample C and C++ programs:

```bash
./tests/smoke.sh "$(pwd)/install/<build-name>" "$(pwd)/sysroots/<build-name>"
```