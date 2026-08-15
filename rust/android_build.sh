#!/usr/bin/env bash
# 使用 Android NDK 交叉编译 stitch_bridge 并复制到 jniLibs。
#
# 依赖：
#   - rustup 已安装 Android 目标（aarch64 / armv7 / x86_64 / i686）
#   - ANDROID_NDK_HOME 或 ANDROID_NDK 指向 NDK（Flutter 3.47 默认 r28.2）
# 用法：
#   bash rust/android_build.sh            # 构建全部 4 个 ABI
#   bash rust/android_build.sh arm64      # 仅 arm64（开发调试用）
set -euo pipefail

cd "$(dirname "$0")/.."

REMAP_ROOT="$(pwd -P)"
USER_ROOT="$(cd ~ && pwd -P)"
if [[ -n "${RUSTFLAGS:-}" ]]; then
  RUSTFLAGS="$RUSTFLAGS --remap-path-prefix=$REMAP_ROOT=. --remap-path-prefix=$USER_ROOT=.user"
else
  RUSTFLAGS="--remap-path-prefix=$REMAP_ROOT=. --remap-path-prefix=$USER_ROOT=.user"
fi
export RUSTFLAGS

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
WINDOWS_HOST=0
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) WINDOWS_HOST=1 ;;
esac
if [[ -n "$NDK" && "$WINDOWS_HOST" -eq 1 ]] && command -v cygpath >/dev/null 2>&1; then
  NDK="$(cygpath -u "$NDK")"
fi
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  echo "错误：找不到 NDK，请设置 ANDROID_NDK_HOME" >&2
  exit 1
fi

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
if [[ ! -d "$TOOLCHAIN" ]]; then
  TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
fi
if [[ ! -d "$TOOLCHAIN" ]]; then
  TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64"
fi
if [[ ! -d "$TOOLCHAIN" ]]; then
  echo "错误：NDK LLVM 工具链不存在（$TOOLCHAIN）" >&2
  exit 1
fi

API=24
DEST="android/app/src/main/jniLibs"

declare -A TRIPLES=(
  [arm64]="aarch64-linux-android:aarch64-linux-android"
  [arm]="armv7-linux-androideabi:armv7a-linux-androideabi"
  [x86_64]="x86_64-linux-android:x86_64-linux-android"
  [x86]="i686-linux-android:i686-linux-android"
)
declare -A ABIS=( [arm64]=arm64-v8a [arm]=armeabi-v7a [x86_64]=x86_64 [x86]=x86 )

build_one() {
  local name="$1"
  local rust_target="${TRIPLES[$name]%%:*}"
  local clang_prefix="${TRIPLES[$name]##*:}"
  local abi="${ABIS[$name]}"

  echo "==> 构建 $abi ($rust_target)"
  local cc="$TOOLCHAIN/bin/${clang_prefix}${API}-clang"
  local ar="$TOOLCHAIN/bin/llvm-ar"
  if [[ "$WINDOWS_HOST" -eq 1 && -f "$cc.cmd" ]]; then
    cc="$cc.cmd"
  elif [[ "$WINDOWS_HOST" -eq 1 && -f "$cc.exe" ]]; then
    cc="$cc.exe"
  fi
  if [[ "$WINDOWS_HOST" -eq 1 && -f "$ar.exe" ]]; then
    ar="$ar.exe"
  fi
  if [[ "$WINDOWS_HOST" -eq 1 ]] && command -v cygpath >/dev/null 2>&1; then
    cc="$(cygpath -w "$cc")"
    ar="$(cygpath -w "$ar")"
  fi
  local env_key=$(echo "$rust_target" | tr '[:lower:]-' '[:upper:]_')
  export "CARGO_TARGET_${env_key}_LINKER=$cc"
  export "CARGO_TARGET_${env_key}_AR=$ar"
  cargo build --manifest-path rust/Cargo.toml -p stitch_bridge --release --target "$rust_target"

  mkdir -p "$DEST/$abi"
  cp "rust/target/$rust_target/release/libstitch_bridge.so" "$DEST/$abi/"
  echo "==> 已复制到 $DEST/$abi/"
}

if [[ $# -eq 0 ]]; then
  for name in arm64 arm x86_64 x86; do
    build_one "$name"
  done
else
  build_one "$1"
fi

echo "完成。jniLibs 输出："
find "$DEST" -name '*.so' | sort
