#!/usr/bin/env bash
# 为 iOS 构建 stitch_bridge 静态库并打包 XCFramework。
#
# 仅能在 macOS 上运行（需要 Xcode 命令行工具）。
# 用法：bash rust/ios_build.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# iOS 设备（arm64）与模拟器（arm64 + x86_64）。
IOS_TARGET="aarch64-apple-ios"
SIM_TARGETS=("aarch64-apple-ios-sim" "x86_64-apple-ios")

echo "==> 安装 iOS Rust 目标"
rustup target add "$IOS_TARGET" "${SIM_TARGETS[@]}"

echo "==> 构建设备库（$IOS_TARGET）"
cargo build --manifest-path rust/Cargo.toml -p stitch_bridge --release --target "$IOS_TARGET"

SIM_LIBS=()
for target in "${SIM_TARGETS[@]}"; do
  echo "==> 构建模拟器库（$target）"
  cargo build --manifest-path rust/Cargo.toml -p stitch_bridge --release --target "$target"
  SIM_LIBS+=("rust/target/$target/release/libstitch_bridge.a")
done

OUT="ios/Frameworks/StitchBridge.xcframework"
rm -rf "$OUT"
mkdir -p "$OUT"

# 模拟器库合并（fat）。
SIM_FAT="rust/target/ios-sim-fat/libstitch_bridge.a"
mkdir -p "$(dirname "$SIM_FAT")"
lipo -create "${SIM_LIBS[@]}" -output "$SIM_FAT"

xcodebuild -create-xcframework \
  -library "rust/target/$IOS_TARGET/release/libstitch_bridge.a" \
  -library "$SIM_FAT" \
  -output "$OUT"

echo "完成：$OUT"
