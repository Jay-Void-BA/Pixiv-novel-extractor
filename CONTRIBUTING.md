# 开发指南

## 环境

使用 Flutter **3.47.9**（Dart **3.13.7**）及 `pubspec.lock` 中的依赖版本；CI 使用相同 Flutter 版本。Python 基础服务及单元测试使用标准库，需要 Python 3.10+；安全保存可选使用系统 `secret-tool` 或 Python `keyring`。浏览器扩展测试使用 Node.js 22+。

```sh
git clone https://github.com/Jay-Void-BA/Pixiv-novel-extractor.git
cd Pixiv-novel-extractor
flutter --version
flutter pub get --enforce-lockfile
```

平台宿主工具链按 [Flutter 官方说明](https://docs.flutter.dev/platform-integration) 安装。Android 使用 JDK 17 和 Android SDK；Linux 需要 GTK 3、Clang、CMake、Ninja、pkg-config、liblzma 和 libsecret 开发包；Windows 原生构建需要 Windows 与 Visual Studio C++ 桌面工具；macOS / iOS 需要 macOS 与 Xcode。

## 修改与验证

模块职责见 [项目结构](docs/PROJECT_STRUCTURE.md)。修改提取、会话、选章或导出行为时，应补充覆盖实际行为的现有测试；单纯文档修改可检查链接与命令。

```sh
dart format --output=none --set-exit-if-changed lib test integration_test tool/benchmark_client.dart
flutter analyze --fatal-infos
flutter test --coverage
python3 -m unittest discover -s test -p 'test_*.py' -v
node --test test/extension_test.cjs
```

没有 Flutter SDK 时，Python 与 Node 测试仍可独立运行。PDF 测试生成 `build/test-exports/cjk-long.pdf` 后，安装 Poppler 工具并执行 `python3 tool/verify_pdf.py`，独立检查长文排版及中日文字恢复。

```sh
flutter run -d linux
# 或在有对应工具链的宿主机上选择 macos、windows、Android 或 iOS 设备
```

Web 与 FreeBSD 兼容包的构建和运行：

```sh
flutter build web --release --no-web-resources-cdn
python3 freebsd/shiori_server.py --web-root build/web
```

打包扩展和本地 Web 版本：

```sh
python3 tool/package_extension.py
python3 tool/package_web.py
```

Web 打包前需要先完成 Web 编译。界面集成检查、原生启动检查、平台测试与发布附件检查由 [交付工作流](.github/workflows/delivery.yml) 执行；复现要求见 [README](README.md#开发与测试)。

## 版本与发布

应用版本位于 `pubspec.yaml`。修改版本时，同步 `CHANGELOG.md` 与 `docs/RELEASE_NOTES.md`；发布前核对所有平台实际完成的构建与验证。

`main` 和 PR 触发构建测试，Android 仅生成明确标注的开发 APK。首次正式发布应在本地生成新的发布密钥，再用安全配置脚本上传五项 Actions Secrets，完整步骤见 [Android 签名指南](docs/ANDROID_SIGNING.md)。普通构建不读取发布密钥。

先手动运行 `verify_android_signing=true` 完成正式签名验证；此运行只生成正式签名 Artifact，不发布 Release。随后在同一提交使用正式版本标签，待所有平台通过、最终 APK 的证书指纹和签名报告再次验证后发布。首次正式发布后保留新发布密钥用于后续升级。

提交前检查 `git diff --check` 和 `git status`。会话 Cookie、签名密钥、密码、本地 SDK 配置、用户导出文件以及构建缓存应留在本机；测试数据使用自行编写的内容。
