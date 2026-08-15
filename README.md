# PixelForge

本地图片处理工具，当前支持：

- 长截图拼接：接缝分析、预览、裁切和多格式导出。
- 自动打码：识别文字、二维码和人脸，并支持实心遮挡与模糊处理。
- 隐私保护水印：在原图分辨率上生成重复斜向水印。

图片处理保持在设备本地完成。当前主要开发和验证 Android，iOS 工程暂缓。

依旧是自己要用什么做什么

## TODO
- [ ] IOS适配

## 环境要求

- Flutter 3.47.0。
- Rust stable、rustup，以及 Android Rust targets。
- Android SDK 和 NDK 28.2.13676358。
- Android 最低支持 API 24。

先获取 Flutter 依赖，并安装 Android native 构建所需的 Rust targets：

```bash
flutter pub get
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
```

## 构建

### Android

先构建 Rust native 库：

```bash
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/<ndk-version>"
bash rust/android_build.sh
```

Windows PowerShell：

```powershell
$env:ANDROID_NDK_HOME="C:\Android\Sdk\ndk\<ndk-version>"
.\rust\android_build.ps1
```

Debug APK：

```bash
flutter build apk --debug
```

输出：`build/app/outputs/flutter-apk/app-debug.apk`

安装到已连接的 Android 设备：

```bash
flutter devices
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk
```

Release APK：

```bash
flutter build apk --release \
  --android-project-arg=pixelforge-signing=release
```

输出文件：

- `PixelForge-版本号-android-universal.apk`
- `PixelForge-版本号-android-arm64-v8a.apk`
- `PixelForge-版本号-android-x86_64.apk`

配置自定义签名：

```bash
cp android/key.properties.example android/key.properties
```

然后编辑 `android/key.properties`，填写本地 keystore 信息。该文件和 keystore 已被 Git 忽略，不能提交。

Universal 包含 32 位 ARM，不单独构建 32 位 APK。

## iOS

仅 macOS 支持执行以下脚本；iOS 当前未纳入主要验证流程。

```bash
bash rust/ios_build.sh
```

## 检查

```bash
cargo fmt --manifest-path rust/Cargo.toml --all --check
cargo test --manifest-path rust/Cargo.toml --workspace
cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets -- -D warnings
flutter analyze
flutter test
flutter build apk --debug
```

## License
MIT
