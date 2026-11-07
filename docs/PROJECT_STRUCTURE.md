# 项目结构

Shiori 是一个 Flutter 应用，桌面、手机和本地 Web 版本共用 `lib/` 中的界面与提取逻辑。Git 仓库直接保存可开发的源码目录，安装包由构建流程生成。

## 目录

```text
Pixiv-novel-extractor/
├── .editorconfig                  # 编辑器缩进与换行约定
├── .gitattributes                 # 跨平台文本换行与二进制识别
├── .github/
│   └── workflows/delivery.yml     # 检查、多平台构建和标签发布
├── .gitignore                     # 缓存、产物、本地设置和密钥忽略规则
├── .metadata                      # Flutter 工程元数据
├── analysis_options.yaml          # Dart 静态检查配置
├── pubspec.yaml                   # 应用版本、依赖、字体和资源声明
├── pubspec.lock                   # 已锁定的依赖版本
├── README.md                      # 项目入口与快速使用
├── CONTRIBUTING.md                # 环境、修改流程和验证命令
├── CHANGELOG.md                   # 更新记录
├── LICENSE                        # 应用 BSD-2-Clause 许可
├── assets/
│   └── fonts/
│       ├── NotoSansSC-Regular.ttf # 随应用分发的中日文字体
│       └── OFL.txt                # 字体 SIL Open Font License
├── lib/
│   ├── main.dart                  # 应用入口、响应式界面与操作状态
│   ├── core/
│   │   ├── models.dart            # 作品/章节模型、链接和选章范围校验
│   │   ├── pixiv_client.dart      # 小说/系列请求、会话、重试与缓存
│   │   ├── novel_text.dart        # Pixiv 正文标记与简介转换
│   │   └── exporter.dart          # TXT/PDF 导出及导出选项
│   └── platform/
│       ├── platform_bridge.dart   # 按编译平台选择桥接实现
│       ├── bridge_native.dart     # 原生网络、桌面会话连接与系统保存
│       ├── bridge_web.dart        # 浏览器下载与本机服务通信
│       ├── bridge_stub.dart       # 不支持平台的回退实现
│       ├── session_vault.dart     # Android 加密会话存储通道，不接触原始密钥
│       └── mobile_login.dart      # 移动端官方登录页与 WebView 会话
├── android/                       # Gradle、Manifest、Kotlin 入口和资源
│   ├── app/build.gradle.kts
│   ├── app/src/main/              # MainActivity、SessionVault、Manifest 与资源
│   ├── app/src/androidTest/       # 真正调用 Android Keystore 的安全测试
│   └── gradle/wrapper/gradle-wrapper.properties
├── ios/                           # iOS 宿主工程与平台测试
│   ├── Flutter/
│   ├── Runner/
│   ├── Runner.xcodeproj/
│   ├── Runner.xcworkspace/
│   └── RunnerTests/
├── linux/                         # GTK/CMake 桌面宿主
│   ├── CMakeLists.txt
│   ├── flutter/
│   └── runner/
├── macos/                         # macOS 宿主工程与平台测试
│   ├── Flutter/
│   ├── Runner/
│   ├── Runner.xcodeproj/
│   ├── Runner.xcworkspace/
│   └── RunnerTests/
├── windows/                       # Win32/CMake 桌面宿主
│   ├── CMakeLists.txt
│   ├── flutter/
│   └── runner/
├── web/                           # HTML 入口、启动脚本、图标与 manifest
├── browser_extension/
│   ├── manifest.json              # Chromium 扩展定义
│   ├── background.js              # 已获授权的本机会话传递
│   ├── content.js                 # 本机连接页交互
│   ├── validation.js              # 连接地址、令牌和有效期校验
│   ├── approve.html               # 用户确认页
│   ├── approve.js
│   ├── style.css
│   └── README.md                  # Chromium / Firefox 加载方法
├── freebsd/
│   └── shiori_server.py           # Python 标准库的本地 Web 服务
├── test/
│   ├── core_test.dart             # 链接、目录、会话和异常处理
│   ├── export_test.dart           # TXT、长篇 CJK PDF 与空导出校验
│   ├── widget_test.dart           # 选章、界面交互和布局
│   ├── test_local_server.py       # 服务访问范围、会话和路径测试
│   ├── test_android_signing.py    # 密钥保护、调试签名拒绝和发布校验测试
│   └── extension_test.cjs         # 浏览器扩展授权与传递逻辑测试
├── tool/
│   ├── browser_smoke.py           # Chromium 界面与文件下载集成检查
│   ├── native_linux_smoke.sh      # Linux 原生窗口启动检查
│   ├── package_extension.py       # 生成 Chromium / Firefox 扩展包
│   ├── package_web.py             # 打包 Web UI 与本地服务
│   ├── verify_pdf.py              # 用 Poppler 独立检查 PDF 内容完整性
│   ├── verify_android.py          # APK 签名、对齐、资源与架构检查
│   ├── android_signing.py         # 发布证书身份、指纹和报告校验
│   ├── prepare_android_signing.py # CI 私有临时目录恢复发布密钥
│   ├── setup_android_signing.py   # 本地隐藏输入密码并安全配置 Secrets
│   └── check_release.py           # 检查所有发布附件并生成 SHA-256
└── docs/
    ├── USAGE.zh-CN.md             # 中文安装与使用方法
    ├── LINUX.md                   # Linux 运行说明
    ├── FREEBSD.md                 # 本地 Web / FreeBSD 运行说明
    ├── RELEASE_NOTES.md           # 多平台完整 Release 的说明模板
    ├── ANDROID_SIGNING.md         # 首次正式发布与本地密钥 / Secrets 配置
    ├── SECURITY_AND_PERFORMANCE.md # 加密会话、请求队列与验证方法
    ├── VALIDATION.md              # 原始交付验证记录
    ├── MIGRATION.md               # Drive 迁移来源与本次复核
    ├── PROJECT_STRUCTURE.md       # 本文
    ├── icon.png
    └── screenshot-*.png           # 自编测试数据的界面截图
```

## 模块关系

界面将用户输入交给 `WorkLink` 校验，再由 `PixivClient` 加载作品与系列目录。用户选择章节后，客户端通过受限并发队列读取正文，并按目录顺序组装结果，`NovelExporter` 生成 TXT 或 PDF，最后交给平台桥接保存或分享。任一选中章节读取失败时，导出流程中止。

手机通过应用内官方登录页建立会话；桌面通过浏览器扩展与本机连接页传递已获授权的会话。Web 版本需要随包 Python 服务，不能用普通静态托管替代。详细会话行为见 [使用方法](USAGE.zh-CN.md) 与 [扩展说明](../browser_extension/README.md)。

Android 主动开启安全保存时，`bridge_native.dart` → `session_vault.dart` → Kotlin `SessionVault`。Keystore 负责 AES 密钥和加解密，密文写入应用的 `noBackupFilesDir`。APK 的发布签名与此设备会话密钥彼此独立。

## 生成目录

以下目录在本机或 CI 中生成，不提交到 Git：

| 路径 | 用途 |
| --- | --- |
| `.dart_tool/` | Dart / Flutter 工具状态 |
| `build/` | 各平台编译产物、集成测试输出和临时打包目录 |
| `coverage/` | Flutter 测试覆盖率 |
| `dist/` | 可分发 ZIP / TAR / APK 与发布校验文件 |
| `ios/Pods/`、`macos/Pods/` | Apple 平台生成的依赖 |
| 各平台 `ephemeral/` | Flutter 工具生成的临时工程 |

Android 的 Gradle 启动脚本与 wrapper JAR 由 Flutter 工具按工程配置生成，遵循原工程的忽略规则。应从仓库根目录使用 `flutter build apk`；机器相关的 SDK 路径、签名配置和密钥不属于共享源码。
