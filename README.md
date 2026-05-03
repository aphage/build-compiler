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
- `tests/smoke.sh`: basic smoke test script for compile checks and optional qemu runtime checks

## Prerequisites

Check host tools:

```bash
./build-toolchain.sh --check-host-deps
```

Typical Ubuntu 24.04 setup for the full matrix:

```bash
sudo apt install build-essential curl gawk sed grep bison flex patch python3 texinfo xz-utils tar cmake ninja-build clang lld
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

Clean the generated outputs for the resolved combo without touching cached downloads or extracted source trees:

```bash
./build-toolchain.sh clean --libc glibc --cxx-runtime libstdc++
```

Build a musl toolchain using LLVM libc++:

```bash
./build-toolchain.sh --libc musl --cxx-runtime libc++
```

Build the llvm-libc route:

```bash
./build-toolchain.sh --libc llvm-libc --cxx-runtime libc++
```

This route now reuses a matching glibc donor sysroot from an existing glibc toolchain under `install/` instead of building glibc during the llvm-libc run itself. Build a matching glibc combo first if no donor sysroot is present.

## GitHub Actions

The repository includes a manual workflow at `.github/workflows/build-toolchain.yml` for running full builds on GitHub-hosted `ubuntu-24.04` runners.

- Trigger it from the Actions tab with the `Build Cross Toolchain` workflow.
- Select one supported `combo` input instead of mixing `--libc` and `--cxx-runtime` manually.
- Override individual component versions through the workflow inputs when needed.
- Successful runs upload `artifacts/*.tar.xz` and the matching `.manifest` file.
- Build logs are always uploaded as a separate workflow artifact.
- `run_smoke_tests` can be left enabled to run `tests/smoke.sh` after the build finishes, including the optional `qemu-arm` runtime check used in CI.

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

Preview what the clean command would remove:

```bash
./build-toolchain.sh clean --libc glibc --cxx-runtime libstdc++ --dry-run
```

## Notes

- `llvm-libc` support in v1 uses a hybrid boundary: the target sysroot still carries ARM glibc's `ld-linux-armhf.so.3` loader and startup objects copied from a matching prebuilt glibc donor sysroot.
- When `libc++` is selected, the final GCC drivers are wrapped instead of patching GCC's installed specs in place.
- The generated wrappers use `-nostdlib++` and generated specs fragments so `g++` defaults to `libc++` for that build output.
- The downloader uses the repository's own checksum table for deterministic validation.

## Smoke Test

After a successful build, compile sample C and C++ programs:

```bash
./tests/smoke.sh "$(pwd)/install/<build-name>"
```

Optionally run the compiled ARM binaries under `qemu-arm`:

```bash
RUN_RUNTIME_SMOKE=1 ./tests/smoke.sh "$(pwd)/install/<build-name>"
```

This runtime mode expects `qemu-arm` from the `qemu-user` package to be installed on the host.

The toolchain now carries its default sysroot inside the install prefix at `/<build-name>/<target-triple>/sysroot` and the local workspace keeps a compatibility symlink under `sysroots/<build-name>`.