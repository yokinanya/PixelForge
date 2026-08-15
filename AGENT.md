# PixelForge Agent Instructions

本文件只记录 Agent 需要遵守的项目约束；用户操作说明和发布说明写入 `README.md`。

## 项目边界

- 项目是 Flutter 图片处理应用：Dart 负责界面与状态，Rust 负责核心图像算法，Android Kotlin 负责平台集成与 ML Kit。
- 当前以 Android 为唯一主要开发和验证平台。iOS 工程保留但暂缓；除非用户明确恢复，否则不要扩展或验证 iOS。
- 图片处理和识别保持本地完成。除非用户明确要求，不要新增图片上传、遥测或网络依赖。
- 保持现有 UX：主页功能卡只显示图标、名称和必要操作；Android 专属功能继续用 `Platform.isAndroid` 控制。

## 修改规则

- 开始前查看相关代码、`README.md` 和 `git status`；保留用户已有改动，不得用 reset、checkout 或覆盖操作清理它们。
- 遵循现有分层：`lib/src/features` 放界面，`lib/src/application` 放用例和状态，`lib/src/infrastructure` 放平台/存储适配，Rust 算法放 `rust/crates`。
- 让错误显式暴露。不要添加 mock 成功、静默降级、吞错、无依据的限制或未获请求的兼容分支。
- 不得把真实姓名、联系方式、路径、证书信息、密钥或其他个人信息写入 Git 跟踪文件、测试数据、日志、截图或构建产物。签名文件只存在于本地：`android/key.properties` 和 keystore 不得提交。
- 暂存或发布前检查完整 diff 和 staged 内容，确认没有隐私信息或凭据。
- 当项目约束、架构、已知问题或验证流程发生持久变化时，Agent 可以自主更新本文件；同步删除失效规则，保持内容简洁，不记录临时过程或用户特定偏好。面向用户的内容放到对应文档。

## Android 与 native 约束

- 最低支持 Android API 24。修改 Rust 或 FFI 后，先运行 `bash rust/android_build.sh` 更新 `android/app/src/main/jniLibs`；只做 arm64 快速验证时可传 `arm64`。
- 保持 native 库的 `arm64-v8a`、`armeabi-v7a`、`x86`、`x86_64` 目录同步，不要提交只在本机生成的 ABI。
- 自动打码使用设备端 ML Kit。人脸检测必须保留 Play Services 实现和按需初始化；不要无验证地改回 bundled 模型。
- 不要删除 `android/app/proguard-rules.pro` 中保留 `ComponentRegistrar` 的 R8 规则，否则 Release 可能无法初始化 ML Kit。
- 隐私保护水印默认文字是 `仅供XX办理使用`；输出保持原图分辨率，现有重复斜向、低透明度和 `BlendMode.difference` 样式不要随意改变。

## 验证命令

按改动范围执行，相关命令失败时修复根因，不要绕过检查：

```bash
cargo fmt --manifest-path rust/Cargo.toml --all --check
cargo test --manifest-path rust/Cargo.toml --workspace
cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets -- -D warnings
flutter analyze
flutter test
flutter build apk --debug
```

## Release 规则

- Release 必须使用项目签名，并显式传入 `--android-project-arg=pixelforge-signing=release`。缺少 `android/key.properties` 或 keystore 时直接失败并报告错误，禁止回退到 Debug 签名。
- 默认 Release 应生成 Universal、`arm64-v8a`、`x86_64` 三种交付包。Universal 必须包含 32 位 ARM 支持；不要单独交付 `armeabi-v7a` APK。
- 交付文件名必须是 `PixelForge-<pubspec 版本>-android-<abi>.apk`，不要把 Flutter 的 `app-release.apk` 当作交付文件。
- 发布前先完成测试和构建，再提交、推送代码，最后创建或更新 Release 并上传文件；代码未推送成功前不得发布。
- Release notes 要覆盖上一个 Release 到当前版本的变更，关联 Issue（修复用 `Fixes #编号`，其他用 `Refs #编号`），并为每个 APK 附上 SHA256。
