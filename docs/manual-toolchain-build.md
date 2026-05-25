# 手动编译 ARM 交叉 Toolchain 教程

这份文档把仓库里的分阶段构建流程拆成可以手工执行的命令，目标是让你在**不调用 `build-toolchain.sh`** 的前提下，仍然能按当前仓库默认参数构建出同一套 ARM 交叉工具链。

本文默认基线组合是 `glibc + libstdc++`，因为它既是最稳妥的起点，也是 `llvm-libc + libc++` 需要的 donor sysroot 来源。其它组合会在对应章节给出差异命令。

## 1. 适用范围

- Host: `x86_64 Ubuntu 24.04`
- Target 架构: `armv7-a`, hard-float, `vfpv3-d16`
- 当前默认组件版本:
  - GCC `14.2.0`
  - binutils `2.43`
  - Linux headers `6.6.58`
  - glibc `2.40`
  - musl `1.2.5`
  - llvm-project `19.1.7`

支持的组合:

- `glibc + libstdc++`
- `glibc + libc++`
- `musl + libstdc++`
- `musl + libc++`
- `llvm-libc + libc++`

不支持的组合:

- `llvm-libc + libstdc++`

## 2. 建议构建顺序

推荐顺序如下:

1. 先做 `glibc + libstdc++`，确认 baseline 可用。
2. 再切到 `glibc + libc++` 或 `musl` 路线。
3. 最后做 `llvm-libc + libc++`，因为它需要一个**同版本、同 target triple** 的 glibc donor sysroot。

## 3. 主机依赖

先装宿主机工具。下面这组包覆盖了 GNU 路线和 LLVM 路线。

```bash
sudo apt update
sudo apt install \
  bash build-essential curl gawk sed grep bison flex patch python3 \
  texinfo xz-utils tar coreutils cmake ninja-build clang lld
```

说明:

- `texinfo` 提供 `makeinfo`。binutils/GCC 可以跳过 info 文档，但 glibc 安装阶段不要偷懒把 `MAKEINFO=true` 带进去。
- `coreutils` 里有 `sha256sum` 和 `realpath`，后面要用。
- 这份教程为了聚焦功能构建，不强制复现脚本里的 `-ffile-prefix-map` 等调试路径清洗参数。它们影响可重定位调试路径，不影响工具链本身是否能工作。

## 4. 先选一个组合

下面表格给出仓库当前支持的默认组合名。手工编译时，建议直接沿用它们，这样生成目录能和仓库里的 `install/`、`artifacts/`、`tests/smoke.sh` 对齐。

| 组合 | `TARGET_TRIPLE` | `BUILD_NAME` |
| --- | --- | --- |
| `glibc + libstdc++` | `arm-linux-gnueabihf` | `arm-linux-gnueabihf-glibc-libstdcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58` |
| `glibc + libc++` | `arm-linux-gnueabihf` | `arm-linux-gnueabihf-glibc-libcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58` |
| `musl + libstdc++` | `arm-linux-musleabihf` | `arm-linux-musleabihf-musl-libstdcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58` |
| `musl + libc++` | `arm-linux-musleabihf` | `arm-linux-musleabihf-musl-libcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58` |
| `llvm-libc + libc++` | `arm-linux-gnueabihf` | `arm-linux-gnueabihf-llvm-libc-libcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58` |

如果你是第一次做，先选第一行。

## 5. 初始化环境变量和目录

下面以 `glibc + libstdc++` 为例。要切换组合，只改 `LIBC_VARIANT`、`CXX_RUNTIME`、`TARGET_TRIPLE` 和 `BUILD_NAME`。

```bash
export ROOT_DIR=/home/foo/build-compiler
cd "$ROOT_DIR"

export HOST_TRIPLE=x86_64-linux-gnu
export TARGET_MARCH=armv7-a
export TARGET_FLOAT_ABI=hard
export TARGET_FPU=vfpv3-d16
export GLIBC_MIN_KERNEL=4.14
export JOBS="$(nproc)"

export GCC_VERSION=14.2.0
export BINUTILS_VERSION=2.43
export LINUX_HEADERS_VERSION=6.6.58
export GLIBC_VERSION=2.40
export MUSL_VERSION=1.2.5
export LLVM_PROJECT_VERSION=19.1.7

export LIBC_VARIANT=glibc
export CXX_RUNTIME='libstdc++'
export TARGET_TRIPLE=arm-linux-gnueabihf
export BUILD_NAME=arm-linux-gnueabihf-glibc-libstdcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58

export INSTALL_ROOT="$ROOT_DIR/install"
export PREFIX_DIR="$INSTALL_ROOT/$BUILD_NAME"
export CONFIGURE_PREFIX="/$BUILD_NAME"
export CONFIGURE_SYSROOT="$CONFIGURE_PREFIX/$TARGET_TRIPLE/sysroot"
export SYSROOT_DIR="$PREFIX_DIR/$TARGET_TRIPLE/sysroot"

export DOWNLOADS_DIR="$ROOT_DIR/downloads/manual"
export SOURCE_CACHE_DIR="$ROOT_DIR/build/sources/manual"
export BUILD_WORK="$ROOT_DIR/build/manual/$BUILD_NAME"

mkdir -p \
  "$DOWNLOADS_DIR" \
  "$SOURCE_CACHE_DIR" \
  "$BUILD_WORK" \
  "$PREFIX_DIR" \
  "$SYSROOT_DIR"

ln -sfn "../install/$BUILD_NAME/$TARGET_TRIPLE/sysroot" "$ROOT_DIR/sysroots/$BUILD_NAME"
```

这里有两个路径概念必须分清:

- `PREFIX_DIR` 是宿主机上真正看到的安装目录，例如 `install/<build-name>`。
- `CONFIGURE_PREFIX` 是给 binutils/GCC 配置时使用的逻辑前缀，例如 `/<build-name>`。

这么做的原因是让 sysroot 仍然落在 `exec_prefix` 下面，保持仓库当前工具链的可重定位布局。安装时统一用 `DESTDIR="$INSTALL_ROOT"`，最终宿主机上的文件就会落到 `install/<build-name>`。

## 6. 下载源码并校验 SHA256

```bash
cd "$DOWNLOADS_DIR"

curl -LO https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz
curl -LO https://ftp.gnu.org/gnu/binutils/binutils-2.43.tar.xz
curl -LO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.58.tar.xz
curl -LO https://ftp.gnu.org/gnu/glibc/glibc-2.40.tar.xz
curl -LO https://musl.libc.org/releases/musl-1.2.5.tar.gz
curl -LO https://github.com/llvm/llvm-project/releases/download/llvmorg-19.1.7/llvm-project-19.1.7.src.tar.xz

cat > SHA256SUMS <<'EOF'
a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9  gcc-14.2.0.tar.xz
b53606f443ac8f01d1d5fc9c39497f2af322d99e14cea5c0b4b124d630379365  binutils-2.43.tar.xz
e7df81e588d70fab5ec3ec3bb04ac53d51f0860fc3b1ec45e0a4167a026899db  linux-6.6.58.tar.xz
19a890175e9263d748f627993de6f4b1af9cd21e03f080e4bfb3a1fac10205a2  glibc-2.40.tar.xz
a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4  musl-1.2.5.tar.gz
82401fea7b79d0078043f7598b835284d6650a75b93e64b6f761ea7b63097501  llvm-project-19.1.7.src.tar.xz
EOF

sha256sum -c SHA256SUMS
```

## 7. 解压源码

```bash
cd "$SOURCE_CACHE_DIR"

rm -rf "gcc-$GCC_VERSION" "binutils-$BINUTILS_VERSION" "linux-$LINUX_HEADERS_VERSION" \
       "glibc-$GLIBC_VERSION" "musl-$MUSL_VERSION" "llvm-project-$LLVM_PROJECT_VERSION" \
       "llvm-project-$LLVM_PROJECT_VERSION.src"

tar -xf "$DOWNLOADS_DIR/gcc-$GCC_VERSION.tar.xz"
tar -xf "$DOWNLOADS_DIR/binutils-$BINUTILS_VERSION.tar.xz"
tar -xf "$DOWNLOADS_DIR/linux-$LINUX_HEADERS_VERSION.tar.xz"
tar -xf "$DOWNLOADS_DIR/glibc-$GLIBC_VERSION.tar.xz"
tar -xf "$DOWNLOADS_DIR/musl-$MUSL_VERSION.tar.gz"
tar -xf "$DOWNLOADS_DIR/llvm-project-$LLVM_PROJECT_VERSION.src.tar.xz"
mv "llvm-project-$LLVM_PROJECT_VERSION.src" "llvm-project-$LLVM_PROJECT_VERSION"

export GCC_SRC="$SOURCE_CACHE_DIR/gcc-$GCC_VERSION"
export BINUTILS_SRC="$SOURCE_CACHE_DIR/binutils-$BINUTILS_VERSION"
export LINUX_SRC="$SOURCE_CACHE_DIR/linux-$LINUX_HEADERS_VERSION"
export GLIBC_SRC="$SOURCE_CACHE_DIR/glibc-$GLIBC_VERSION"
export MUSL_SRC="$SOURCE_CACHE_DIR/musl-$MUSL_VERSION"
export LLVM_SRC="$SOURCE_CACHE_DIR/llvm-project-$LLVM_PROJECT_VERSION"
```

GCC 还需要顺手把依赖拉下来:

```bash
cd "$GCC_SRC"
./contrib/download_prerequisites
```

## 8. 预先准备两个辅助函数

后面会重复用到 `libgcc` 安装和 sysroot 内部绝对软链接修正，先把函数放到当前 shell 里。

```bash
build_target_libgcc() {
  cd "$BUILD_WORK/30-gcc-stage1-build"
  make MAKEINFO=true -j "$JOBS" all-target-libgcc
  make MAKEINFO=true DESTDIR="$INSTALL_ROOT" install-target-libgcc
}

rewrite_internal_absolute_symlinks() {
  local tree_root=$1
  local link_path link_target resolved_target relative_target

  find "$tree_root" -type l -print0 | while IFS= read -r -d '' link_path; do
    link_target="$(readlink "$link_path")"
    [[ "$link_target" == /* ]] || continue

    resolved_target="$tree_root$link_target"
    [[ -e "$resolved_target" || -L "$resolved_target" ]] || continue

    relative_target="$(realpath --no-symlinks --relative-to="$(dirname "$link_path")" "$resolved_target")"
    rm -f "$link_path"
    ln -s "$relative_target" "$link_path"
  done
}
```

## 9. Stage 10: 构建 binutils

```bash
mkdir -p "$BUILD_WORK/10-binutils-build"
cd "$BUILD_WORK/10-binutils-build"

env MAKEINFO=true \
  "$BINUTILS_SRC/configure" \
  --prefix="$CONFIGURE_PREFIX" \
  --target="$TARGET_TRIPLE" \
  --with-sysroot="$CONFIGURE_SYSROOT" \
  --disable-multilib \
  --disable-nls \
  --disable-werror

make MAKEINFO=true -j "$JOBS"
make MAKEINFO=true DESTDIR="$INSTALL_ROOT" install
```

从这一步开始，把新装好的交叉 binutils 放进 `PATH`:

```bash
export PATH="$PREFIX_DIR/bin:$PATH"
```

## 10. Stage 20: 安装 Linux headers

```bash
mkdir -p "$SYSROOT_DIR/usr"
cd "$LINUX_SRC"
make ARCH=arm INSTALL_HDR_PATH="$SYSROOT_DIR/usr" headers_install
```

## 11. Stage 30: 构建 GCC stage1

这一步只做 C 编译器，用来把目标 libc 先引导起来。

```bash
mkdir -p "$BUILD_WORK/30-gcc-stage1-build"
cd "$BUILD_WORK/30-gcc-stage1-build"

env MAKEINFO=true \
  "$GCC_SRC/configure" \
  --prefix="$CONFIGURE_PREFIX" \
  --target="$TARGET_TRIPLE" \
  --with-sysroot="$CONFIGURE_SYSROOT" \
  --with-build-sysroot="$SYSROOT_DIR" \
  --enable-languages=c \
  --disable-multilib \
  --disable-nls \
  --disable-shared \
  --disable-threads \
  --disable-libatomic \
  --disable-libgomp \
  --disable-libquadmath \
  --disable-libssp \
  --disable-libvtv \
  --disable-libsanitizer \
  --without-headers \
  --with-arch="$TARGET_MARCH" \
  --with-float="$TARGET_FLOAT_ABI" \
  --with-fpu="$TARGET_FPU"

make MAKEINFO=true -j "$JOBS" all-gcc
make MAKEINFO=true DESTDIR="$INSTALL_ROOT" install-gcc
```

## 12. Stage 40: 构建目标 libc

这一节分三条路线。你只需要执行和 `LIBC_VARIANT` 匹配的那一节。

### 12.1 glibc 路线

先装 bootstrap headers 和启动文件，再回到 stage1 GCC 里补 `libgcc`，最后做完整 glibc。

```bash
mkdir -p "$BUILD_WORK/40-glibc-build"
cd "$BUILD_WORK/40-glibc-build"

export TARGET_CC="$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc --sysroot=$SYSROOT_DIR -march=$TARGET_MARCH -mfloat-abi=$TARGET_FLOAT_ABI -mfpu=$TARGET_FPU"
export TARGET_CPPFLAGS="--sysroot=$SYSROOT_DIR"
export TARGET_CFLAGS="-O2 -march=$TARGET_MARCH -mfloat-abi=$TARGET_FLOAT_ABI -mfpu=$TARGET_FPU"

env \
  BUILD_CC=gcc \
  CC="$TARGET_CC" \
  AR="$PREFIX_DIR/bin/$TARGET_TRIPLE-ar" \
  AS="$PREFIX_DIR/bin/$TARGET_TRIPLE-as" \
  LD="$PREFIX_DIR/bin/$TARGET_TRIPLE-ld" \
  NM="$PREFIX_DIR/bin/$TARGET_TRIPLE-nm" \
  CPPFLAGS="$TARGET_CPPFLAGS" \
  CFLAGS="$TARGET_CFLAGS" \
  LDFLAGS="$TARGET_CPPFLAGS" \
  RANLIB="$PREFIX_DIR/bin/$TARGET_TRIPLE-ranlib" \
  READELF="$PREFIX_DIR/bin/$TARGET_TRIPLE-readelf" \
  "$GLIBC_SRC/configure" \
  --prefix=/usr \
  --build="$HOST_TRIPLE" \
  --host="$TARGET_TRIPLE" \
  --with-headers="$SYSROOT_DIR/usr/include" \
  --disable-multilib \
  --disable-werror \
  --enable-kernel="$GLIBC_MIN_KERNEL"

make -j "$JOBS" install-bootstrap-headers=yes install-headers cross_compiling=yes install_root="$SYSROOT_DIR"
make -j "$JOBS" csu/subdir_lib

install -m 0644 csu/crt1.o "$SYSROOT_DIR/usr/lib/crt1.o"
install -m 0644 csu/crti.o "$SYSROOT_DIR/usr/lib/crti.o"
install -m 0644 csu/crtn.o "$SYSROOT_DIR/usr/lib/crtn.o"

"$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc" \
  --sysroot="$SYSROOT_DIR" \
  -march="$TARGET_MARCH" \
  -mfloat-abi="$TARGET_FLOAT_ABI" \
  -mfpu="$TARGET_FPU" \
  -nostdlib \
  -nostartfiles \
  -shared \
  -x c /dev/null \
  -o "$SYSROOT_DIR/usr/lib/libc.so"

mkdir -p "$SYSROOT_DIR/usr/include/gnu"
: > "$SYSROOT_DIR/usr/include/gnu/stubs.h"
```

现在补 `libgcc`:

```bash
build_target_libgcc
```

最后做完整 glibc。注意这里**不要**设 `MAKEINFO=true`。

```bash
cd "$BUILD_WORK/40-glibc-build"
make -j "$JOBS"
make install install_root="$SYSROOT_DIR"

cat > "$SYSROOT_DIR/usr/lib/libc.so" <<'EOF'
/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
GROUP ( /lib/libc.so.6 /usr/lib/libc_nonshared.a  AS_NEEDED ( /lib/ld-linux-armhf.so.3 ) )
EOF

rewrite_internal_absolute_symlinks "$SYSROOT_DIR"
```

### 12.2 musl 路线

如果你改成 `musl`，至少要同步改这几个变量:

```bash
export LIBC_VARIANT=musl
export CXX_RUNTIME='libstdc++'   # 或 libc++
export TARGET_TRIPLE=arm-linux-musleabihf
export BUILD_NAME=arm-linux-musleabihf-musl-libstdcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58
```

然后重新按前面的 stage 10、20、30 走一遍，接着执行下面的 musl 构建。

```bash
mkdir -p "$BUILD_WORK/40-musl-build"
cd "$BUILD_WORK/40-musl-build"

env \
  "CC=$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc --sysroot=$SYSROOT_DIR" \
  "AR=$PREFIX_DIR/bin/$TARGET_TRIPLE-ar" \
  "RANLIB=$PREFIX_DIR/bin/$TARGET_TRIPLE-ranlib" \
  "CFLAGS=--sysroot=$SYSROOT_DIR -march=$TARGET_MARCH -mfloat-abi=$TARGET_FLOAT_ABI -mfpu=$TARGET_FPU" \
  "$MUSL_SRC/configure" \
  --prefix=/usr \
  --target="$TARGET_TRIPLE" \
  --syslibdir=/lib

make install-headers DESTDIR="$SYSROOT_DIR"
```

装完 headers 后，先补 `libgcc`:

```bash
build_target_libgcc
```

关键点: musl 要再跑一次 `configure`，不然 `config.mak` 里的运行时探测不完整，最终 `lib/libc.so` 很容易在链接时缺少类似 `__aeabi_idivmod` 这样的符号。

```bash
cd "$BUILD_WORK/40-musl-build"

env \
  "CC=$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc --sysroot=$SYSROOT_DIR" \
  "AR=$PREFIX_DIR/bin/$TARGET_TRIPLE-ar" \
  "RANLIB=$PREFIX_DIR/bin/$TARGET_TRIPLE-ranlib" \
  "CFLAGS=--sysroot=$SYSROOT_DIR -march=$TARGET_MARCH -mfloat-abi=$TARGET_FLOAT_ABI -mfpu=$TARGET_FPU" \
  "$MUSL_SRC/configure" \
  --prefix=/usr \
  --target="$TARGET_TRIPLE" \
  --syslibdir=/lib

make -j "$JOBS"
make install DESTDIR="$SYSROOT_DIR"

rewrite_internal_absolute_symlinks "$SYSROOT_DIR"
```

### 12.3 llvm-libc 路线

`llvm-libc` 不是完全独立的纯净路线。当前仓库实现是 hybrid 路线:

- 目标 C 库主体来自 `llvm-libc`
- 动态加载器 `ld-linux-armhf.so.3`、`crt1.o/crti.o/crtn.o` 和一部分 glibc runtime surface 来自**预先构建好的 glibc donor sysroot**

所以在做 `llvm-libc + libc++` 之前，先完成一套**同版本、同 triple** 的 `glibc + libstdc++` 或 `glibc + libc++` 工具链。假设 donor sysroot 在:

```bash
export DONOR_BUILD_NAME=arm-linux-gnueabihf-glibc-libstdcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58
export DONOR_SYSROOT="$ROOT_DIR/install/$DONOR_BUILD_NAME/arm-linux-gnueabihf/sysroot"
```

再切换当前组合:

```bash
export LIBC_VARIANT=llvm-libc
export CXX_RUNTIME='libc++'
export TARGET_TRIPLE=arm-linux-gnueabihf
export BUILD_NAME=arm-linux-gnueabihf-llvm-libc-libcxx-gcc-14.2.0-binutils-2.43-linux-6.6.58
```

重新跑一遍前面的 stage 10、20、30，然后执行下面的 `llvm-libc` 步骤。

先做 host 侧 `libc-hdrgen`:

```bash
mkdir -p "$BUILD_WORK/40-llvm-libc-tools-build"
cmake \
  -B "$BUILD_WORK/40-llvm-libc-tools-build" \
  -S "$LLVM_SRC/llvm" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DLLVM_ENABLE_PROJECTS=libc \
  -DLLVM_LIBC_FULL_BUILD=ON \
  -DLLVM_INCLUDE_TESTS=OFF

cmake --build "$BUILD_WORK/40-llvm-libc-tools-build" --parallel "$JOBS" --target libc-hdrgen

export LIBC_HDRGEN="$BUILD_WORK/40-llvm-libc-tools-build/bin/libc-hdrgen"
```

再做目标 `llvm-libc` / `libm`:

```bash
mkdir -p "$BUILD_WORK/40-llvm-libc-build"

cmake \
  -B "$BUILD_WORK/40-llvm-libc-build" \
  -S "$LLVM_SRC/runtimes" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_SYSROOT="$SYSROOT_DIR" \
  -DCMAKE_C_FLAGS="-march=$TARGET_MARCH -mfloat-abi=$TARGET_FLOAT_ABI -mfpu=$TARGET_FPU --gcc-toolchain=$PREFIX_DIR --sysroot=$SYSROOT_DIR" \
  -DCMAKE_CXX_FLAGS="-march=$TARGET_MARCH -mfloat-abi=$TARGET_FLOAT_ABI -mfpu=$TARGET_FPU --gcc-toolchain=$PREFIX_DIR --sysroot=$SYSROOT_DIR" \
  -DCMAKE_ASM_FLAGS="-march=$TARGET_MARCH -mfloat-abi=$TARGET_FLOAT_ABI -mfpu=$TARGET_FPU --gcc-toolchain=$PREFIX_DIR --sysroot=$SYSROOT_DIR" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_RUNTIMES=libc \
  -DLLVM_LIBC_FULL_BUILD=ON \
  -DLIBC_HDRGEN_EXE="$LIBC_HDRGEN" \
  -DLIBC_TARGET_TRIPLE="$TARGET_TRIPLE" \
  -DLIBC_KERNEL_HEADERS="$SYSROOT_DIR/usr/include" \
  -DCMAKE_INSTALL_PREFIX=/usr

cmake --build "$BUILD_WORK/40-llvm-libc-build" --parallel "$JOBS" --target libc libm
```

`llvm-libc` 的头文件不是一次 `install` 就全部自然出现，手工做时要把生成目标补齐:

```bash
LLVM_LIBC_HEADER_TARGETS=(
  libc/include/__llvm-libc-common.h
  libc/include/arpa/inet.h
  libc/include/assert.h
  libc/include/dirent.h
  libc/include/dlfcn.h
  libc/include/errno.h
  libc/include/fcntl.h
  libc/include/features.h
  libc/include/fenv.h
  libc/include/float.h
  libc/include/inttypes.h
  libc/include/limits.h
  libc/include/math.h
  libc/include/pthread.h
  libc/include/sched.h
  libc/include/search.h
  libc/include/setjmp.h
  libc/include/signal.h
  libc/include/spawn.h
  libc/include/stdbit.h
  libc/include/stdckdint.h
  libc/include/stdfix.h
  libc/include/stdint.h
  libc/include/stdio.h
  libc/include/stdlib.h
  libc/include/string.h
  libc/include/strings.h
  libc/include/sys/auxv.h
  libc/include/sys/epoll.h
  libc/include/sys/ioctl.h
  libc/include/sys/mman.h
  libc/include/sys/prctl.h
  libc/include/sys/queue.h
  libc/include/sys/random.h
  libc/include/sys/resource.h
  libc/include/sys/select.h
  libc/include/sys/sendfile.h
  libc/include/sys/socket.h
  libc/include/sys/stat.h
  libc/include/sys/statvfs.h
  libc/include/sys/syscall.h
  libc/include/sys/time.h
  libc/include/sys/types.h
  libc/include/sys/utsname.h
  libc/include/sys/wait.h
  libc/include/termios.h
  libc/include/threads.h
  libc/include/time.h
  libc/include/uchar.h
  libc/include/unistd.h
  libc/include/wchar.h
)

cmake --build "$BUILD_WORK/40-llvm-libc-build" --parallel "$JOBS" --target "${LLVM_LIBC_HEADER_TARGETS[@]}"
env DESTDIR="$SYSROOT_DIR" cmake --install "$BUILD_WORK/40-llvm-libc-build"
```

把生成的头文件复制到 sysroot，再 overlay donor glibc 的 headers 和 runtime surface:

```bash
mkdir -p "$SYSROOT_DIR/usr/include"
find "$BUILD_WORK/40-llvm-libc-build/libc/include" -type f -name '*.h' -print0 | while IFS= read -r -d '' header; do
  rel="${header#$BUILD_WORK/40-llvm-libc-build/libc/include/}"
  mkdir -p "$(dirname "$SYSROOT_DIR/usr/include/$rel")"
  install -m 0644 "$header" "$SYSROOT_DIR/usr/include/$rel"
done

cp -a "$DONOR_SYSROOT/usr/include/." "$SYSROOT_DIR/usr/include/"

mkdir -p "$SYSROOT_DIR/lib" "$SYSROOT_DIR/usr/lib" "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE"

for rel in \
  lib/ld-linux-armhf.so.3 \
  lib/libc.so.6 \
  lib/libdl.so.2 \
  lib/libm.so.6 \
  lib/libpthread.so.0 \
  lib/librt.so.1 \
  usr/lib/libc.so \
  usr/lib/libc_nonshared.a \
  usr/lib/libdl.a \
  usr/lib/libm.a \
  usr/lib/libm.so \
  usr/lib/libpthread.a \
  usr/lib/librt.a; do
  [[ -e "$DONOR_SYSROOT/$rel" ]] || continue
  mkdir -p "$(dirname "$SYSROOT_DIR/$rel")"
  cp -a "$DONOR_SYSROOT/$rel" "$SYSROOT_DIR/$rel"
done

for startup_file in crt1.o crti.o crtn.o; do
  cp -a "$DONOR_SYSROOT/usr/lib/$startup_file" "$SYSROOT_DIR/usr/lib/$startup_file"
done

[[ -f "$SYSROOT_DIR/usr/lib/libc.so" ]] && ln -sfn ../libc.so "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE/libc.so"
[[ -f "$SYSROOT_DIR/usr/lib/libm.so" ]] && ln -sfn ../libm.so "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE/libm.so"
[[ -f "$SYSROOT_DIR/lib/libdl.so.2" ]] && ln -sfn ../../lib/libdl.so.2 "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE/libdl.so"
[[ -f "$SYSROOT_DIR/lib/libpthread.so.0" ]] && ln -sfn ../../lib/libpthread.so.0 "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE/libpthread.so"
[[ -f "$SYSROOT_DIR/lib/librt.so.1" ]] && ln -sfn ../../lib/librt.so.1 "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE/librt.so"

if [[ -f "$SYSROOT_DIR/usr/lib/libllvmlibc.a" && ! -e "$SYSROOT_DIR/usr/lib/libc.a" ]]; then
  ln -sfn libllvmlibc.a "$SYSROOT_DIR/usr/lib/libc.a"
fi

rewrite_internal_absolute_symlinks "$SYSROOT_DIR"
```

## 13. Stage 50: 只有 `libc++` 组合才需要 LLVM runtimes

如果你构建的是 `libstdc++` 组合，可以直接跳到 stage 60。

如果是 `libc++` 组合，先准备额外参数:

```bash
LLVM_RUNTIME_EXTRA_FLAGS=()

if [[ "$LIBC_VARIANT" == "musl" ]]; then
  LLVM_RUNTIME_EXTRA_FLAGS+=(
    -DLIBCXX_HAS_MUSL_LIBC=ON
    -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF
  )
fi

if [[ "$LIBC_VARIANT" == "llvm-libc" ]]; then
  LLVM_RUNTIME_EXTRA_FLAGS+=(
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

HOST_CLANG_RESOURCE_DIR="$(clang --print-resource-dir)"
RUNTIME_FLAGS="-march=$TARGET_MARCH --gcc-toolchain=$PREFIX_DIR -resource-dir=$BUILD_WORK/50-llvm-runtimes-build/compiler-rt -isystem $HOST_CLANG_RESOURCE_DIR/include"
```

然后配置和安装 runtimes:

```bash
mkdir -p "$BUILD_WORK/50-llvm-runtimes-build"

cmake \
  -B "$BUILD_WORK/50-llvm-runtimes-build" \
  -S "$LLVM_SRC/runtimes" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_ASM_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_SYSROOT="$SYSROOT_DIR" \
  -DCMAKE_C_FLAGS="$RUNTIME_FLAGS" \
  -DCMAKE_CXX_FLAGS="$RUNTIME_FLAGS" \
  -DCMAKE_ASM_FLAGS="$RUNTIME_FLAGS" \
  -DLLVM_ENABLE_RUNTIMES='compiler-rt;libunwind;libcxxabi;libcxx' \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
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
  "${LLVM_RUNTIME_EXTRA_FLAGS[@]}"

cmake --build "$BUILD_WORK/50-llvm-runtimes-build" --parallel "$JOBS" --target compiler-rt
cmake --build "$BUILD_WORK/50-llvm-runtimes-build" --parallel "$JOBS" --target unwind cxxabi cxx cxx_experimental
env DESTDIR="$SYSROOT_DIR" cmake --install "$BUILD_WORK/50-llvm-runtimes-build"
```

## 14. Stage 60: 构建 GCC stage2

先准备 GCC stage2 的额外参数。

```bash
GCC_STAGE2_EXTRA_FLAGS=()

if [[ "$CXX_RUNTIME" == "libc++" ]]; then
  GCC_STAGE2_EXTRA_FLAGS+=(--disable-libstdcxx)
fi

if [[ "$LIBC_VARIANT" == "llvm-libc" ]]; then
  GCC_STAGE2_EXTRA_FLAGS+=(
    --disable-shared
    --disable-threads
    --disable-libatomic
    --disable-libgomp
    --disable-libquadmath
    --disable-libssp
    --disable-libvtv
  )
fi
```

然后开始 stage2:

```bash
mkdir -p "$BUILD_WORK/60-gcc-stage2-build"
cd "$BUILD_WORK/60-gcc-stage2-build"

env MAKEINFO=true \
  "$GCC_SRC/configure" \
  --prefix="$CONFIGURE_PREFIX" \
  --target="$TARGET_TRIPLE" \
  --with-sysroot="$CONFIGURE_SYSROOT" \
  --with-build-sysroot="$SYSROOT_DIR" \
  --enable-languages=c,c++ \
  --disable-multilib \
  --disable-nls \
  --disable-libsanitizer \
  "${GCC_STAGE2_EXTRA_FLAGS[@]}" \
  --with-arch="$TARGET_MARCH" \
  --with-float="$TARGET_FLOAT_ABI" \
  --with-fpu="$TARGET_FPU"

make MAKEINFO=true -j "$JOBS"
make MAKEINFO=true DESTDIR="$INSTALL_ROOT" install
```

如果当前是 `libc++` 组合，清掉 GCC 默认装上的 GNU C++ 运行时残留:

```bash
if [[ "$CXX_RUNTIME" == "libc++" ]]; then
  rm -rf "$PREFIX_DIR/$TARGET_TRIPLE/include/c++"
  rm -f "$PREFIX_DIR/$TARGET_TRIPLE/lib/libstdc++"*
  rm -f "$PREFIX_DIR/$TARGET_TRIPLE/lib/libsupc++"*
fi
```

到这里，`glibc + libstdc++` 和 `musl + libstdc++` 已经可以直接用了。

## 15. 让 `libc++` / `llvm-libc` 组合默认开箱即用

这一节是为了让最终驱动行为尽量贴近仓库当前产物。

- 如果你是 `glibc + libstdc++` 或 `musl + libstdc++`，可以跳过。
- 如果你是 `glibc + libc++` 或 `musl + libc++`，建议至少配置 `g++` 包装器。
- 如果你是 `llvm-libc + libc++`，建议把 `gcc` 和 `g++` 都包起来，因为还要注入 `llvmlibc` specs。

先准备三个 helper:

```bash
pick_runtime_lib_dir() {
  if [[ -d "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE" ]]; then
    printf '%s\n' "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE"
  elif [[ -d "$SYSROOT_DIR/usr/lib" ]]; then
    printf '%s\n' "$SYSROOT_DIR/usr/lib"
  else
    printf '%s\n' "$SYSROOT_DIR/lib"
  fi
}

runtime_lib_dir_to_spec() {
  case "$1" in
    "$SYSROOT_DIR")
      printf '%%R\n'
      ;;
    "$SYSROOT_DIR"/*)
      printf '%%R%s\n' "${1#$SYSROOT_DIR}"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

write_compiler_wrapper() {
  local wrapper_path=$1
  local include_args=$2
  local common_args=$3
  local specs_args=$4

  cat > "$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

WRAPPER_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_ROOT="\$(cd "\${WRAPPER_DIR}/.." && pwd)"
SYSROOT_DIR="\${TOOLCHAIN_ROOT}/${TARGET_TRIPLE}/sysroot"
REAL_DRIVER="\${WRAPPER_DIR}/\${0##*/}.real"
COMMON_ARGS=( ${common_args} )
INCLUDE_ARGS=( ${include_args} )
SPECS_ARGS=( ${specs_args} )

exec "\${REAL_DRIVER}" "\${COMMON_ARGS[@]}" "\${SPECS_ARGS[@]}" "\${INCLUDE_ARGS[@]}" "\$@"
EOF

  chmod +x "$wrapper_path"
}
```

生成 specs 文件:

```bash
mkdir -p "$PREFIX_DIR/lib/toolchain"

RUNTIME_LIB_DIR="$(pick_runtime_lib_dir)"
RUNTIME_LIB_DIR_SPEC="$(runtime_lib_dir_to_spec "$RUNTIME_LIB_DIR")"

if [[ "$CXX_RUNTIME" == "libc++" ]]; then
  cat > "$PREFIX_DIR/lib/toolchain/$TARGET_TRIPLE.libcxx.specs" <<EOF
%rename lib original_lib

*lib:
%(original_lib) -L${RUNTIME_LIB_DIR_SPEC} -rpath-link %R/lib -rpath-link %R/usr/lib -lc++ -lc++abi -lunwind -lc
EOF
fi

if [[ "$LIBC_VARIANT" == "llvm-libc" ]]; then
  cat > "$PREFIX_DIR/lib/toolchain/$TARGET_TRIPLE.llvmlibc.specs" <<EOF
%rename link original_link

*link:
%(original_link) -L${RUNTIME_LIB_DIR_SPEC} --dynamic-linker /lib/ld-linux-armhf.so.3 -rpath-link %R/lib -rpath-link %R/usr/lib -rpath-link ${RUNTIME_LIB_DIR_SPEC}
EOF
fi
```

把原始驱动改名为 `.real`，然后写包装器:

```bash
[[ -e "$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc.real" ]] || mv "$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc" "$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc.real"
[[ -e "$PREFIX_DIR/bin/$TARGET_TRIPLE-g++.real" ]] || mv "$PREFIX_DIR/bin/$TARGET_TRIPLE-g++" "$PREFIX_DIR/bin/$TARGET_TRIPLE-g++.real"

GCC_SPECS_ARGS=''
GXX_SPECS_ARGS=''

if [[ "$LIBC_VARIANT" == "llvm-libc" ]]; then
  GCC_SPECS_ARGS='"-specs=${TOOLCHAIN_ROOT}/lib/toolchain/'"$TARGET_TRIPLE"'.llvmlibc.specs"'
  GXX_SPECS_ARGS='"-specs=${TOOLCHAIN_ROOT}/lib/toolchain/'"$TARGET_TRIPLE"'.llvmlibc.specs"'
fi

if [[ "$CXX_RUNTIME" == "libc++" ]]; then
  if [[ -n "$GXX_SPECS_ARGS" ]]; then
    GXX_SPECS_ARGS="$GXX_SPECS_ARGS \"-specs=\${TOOLCHAIN_ROOT}/lib/toolchain/$TARGET_TRIPLE.libcxx.specs\""
  else
    GXX_SPECS_ARGS='"-specs=${TOOLCHAIN_ROOT}/lib/toolchain/'"$TARGET_TRIPLE"'.libcxx.specs"'
  fi
fi

write_compiler_wrapper \
  "$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc" \
  '' \
  '"--sysroot" "${SYSROOT_DIR}"' \
  "$GCC_SPECS_ARGS"

if [[ "$CXX_RUNTIME" == "libc++" ]]; then
  write_compiler_wrapper \
    "$PREFIX_DIR/bin/$TARGET_TRIPLE-g++" \
    '"-nostdinc++" "-isystem" "${SYSROOT_DIR}/usr/include/c++/v1"' \
    '"--sysroot" "${SYSROOT_DIR}" "-nostdlib++"' \
    "$GXX_SPECS_ARGS"
else
  write_compiler_wrapper \
    "$PREFIX_DIR/bin/$TARGET_TRIPLE-g++" \
    '' \
    '"--sysroot" "${SYSROOT_DIR}"' \
    "$GXX_SPECS_ARGS"
fi
```

如果你不想做包装器，也可以在使用时手动给 `g++` 补这些参数:

```bash
--sysroot "$SYSROOT_DIR" -nostdinc++ -isystem "$SYSROOT_DIR/usr/include/c++/v1" -nostdlib++ -specs="$PREFIX_DIR/lib/toolchain/$TARGET_TRIPLE.libcxx.specs"
```

如果是 `llvm-libc + libc++`，再额外补:

```bash
-specs="$PREFIX_DIR/lib/toolchain/$TARGET_TRIPLE.llvmlibc.specs"
```

## 16. 手工验收

先验证编译能不能过。

```bash
WORK_DIR="$(mktemp -d)"

cat > "$WORK_DIR/hello.c" <<'EOF'
#include <stdio.h>

int main(void) {
  puts("hello");
  return 0;
}
EOF

cat > "$WORK_DIR/hello.cpp" <<'EOF'
#include <iostream>

int main() {
  std::cout << "hello" << std::endl;
  return 0;
}
EOF

"$PREFIX_DIR/bin/$TARGET_TRIPLE-gcc" --sysroot "$SYSROOT_DIR" "$WORK_DIR/hello.c" -o "$WORK_DIR/hello-c"
"$PREFIX_DIR/bin/$TARGET_TRIPLE-g++" --sysroot "$SYSROOT_DIR" "$WORK_DIR/hello.cpp" -o "$WORK_DIR/hello-cxx"
```

如果宿主机安装了 `qemu-arm`，可以继续做运行时验证。

`glibc` / `llvm-libc` 路线:

```bash
qemu-arm -L "$SYSROOT_DIR" "$WORK_DIR/hello-c"
LD_LIBRARY_PATH="$PREFIX_DIR/$TARGET_TRIPLE/lib:$SYSROOT_DIR/lib:$SYSROOT_DIR/usr/lib" \
  qemu-arm -L "$SYSROOT_DIR" "$WORK_DIR/hello-cxx"
```

`musl` 路线通常也可以直接用 `-L "$SYSROOT_DIR"`，但前提是你前面的 sysroot 软链接已经做过相对化修正。

## 17. 可选: 打包成仓库同风格产物

如果你还想产出和仓库现有 `artifacts/` 结构接近的压缩包，最小可用命令是:

```bash
mkdir -p "$ROOT_DIR/artifacts"
tar -C "$ROOT_DIR" -caf "$ROOT_DIR/artifacts/$BUILD_NAME.tar.xz" "install/$BUILD_NAME"
```

如果还需要 manifest，可以自行把版本号、URL、SHA256 和组合信息整理成 `artifacts/$BUILD_NAME.manifest`。

## 18. 常见坑

- glibc 完整安装阶段不要带 `MAKEINFO=true`，否则容易在 `manual/libc.info*` 上翻车。
- musl 一定要在 `install-headers` 和 `build_target_libgcc` 之后再跑第二次 `configure`。
- `llvm-libc` 不是纯独立 sysroot，必须先准备好 donor glibc sysroot。
- `libc++` 组合的 GCC stage2 要带 `--disable-libstdcxx`，否则会把 GNU `libstdc++` 一起装进去。
- 如果 `qemu-arm -L "$SYSROOT_DIR"` 运行失败，先检查 sysroot 里有没有绝对软链接没改成相对软链接。

走完上面的步骤后，你得到的是一套和仓库当前 stage 划分一致、但完全可以手工复现的 ARM 交叉 toolchain 构建流程。