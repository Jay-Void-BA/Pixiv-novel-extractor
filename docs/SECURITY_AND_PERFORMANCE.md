# 登录安全与提取性能

## 自动恢复登录

默认只在内存保留会话。右上角菜单开启「在此设备安全保存登录」后，当前或下一次登录的 `PHPSESSID` 会通过系统安全存储保存，重启后自动恢复，最长 30 天。Shiori 不保存 Pixiv 账号密码，不将会话上传至第三方服务。系统密钥库不可用或未解锁时会提示错误，不回退到明文文件。

| 平台 | 保存方式 | 解锁与边界 |
| --- | --- | --- |
| Android | AES-256-GCM，密钥由 Android Keystore 生成且不可导出；密文在 `noBackupFilesDir` | 应用自动恢复；硬件保护能力取决于设备 |
| iOS | Keychain，`unlocked_this_device`，关闭 iCloud 同步 | 设备解锁后读取，记录不迁移到新设备；需安装已正确签名的应用 |
| macOS | 本机 Keychain，关闭 iCloud 同步 | 使用当前用户钥匙串；首次访问或应用更新时系统可能要求授权 |
| Windows | 当前用户的 DPAPI，应用支持目录中的加密文件 | 随系统用户登录自动解锁，不使用机器共享模式 |
| Linux 原生 | libsecret / Secret Service，例如 GNOME Keyring 或 KWallet | 需运行并解锁当前用户的系统密钥环 |
| Web / FreeBSD | 本地 Python 服务使用 `secret-tool` / Secret Service；Windows、macOS 可用 Python `keyring` 的系统后端 | 凭据在本地服务和系统密钥环内；浏览器只恢复登录状态标记，不持久保存 Cookie |

非 Android 原生平台通过锁定版本的 [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage/versions/11.2.0) 使用系统存储。macOS 使用本机传统 Keychain，不启用跨应用共享，避免无分发描述文件的桌面包依赖共享钥匙串能力。Web 服务只选择已知系统后端，不采用 `keyrings.alt`、普通文件、自动选择的第三方后端或浏览器 localStorage 作为凭据存储。

### 保存与清理

- Android 使用 256 位 AES 密钥，每次写入生成新的 96 位随机 nonce 和 128 位认证标签；应用标识及格式版本作为 AAD。密文以 `0600` 原子写入私有目录，应用关闭备份。实现依据 [Android Keystore](https://developer.android.com/privacy-and-security/keystore) 与 [AES-GCM 示例](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec)。
- 所有平台将会话、格式版本、保存时间和过期时间一并放进受保护的记录。非 Android 存储写入后立即读回核对，避免未正确配置系统权限却误报保存成功。
- 本地最长保存 30 天；Pixiv 可能提前使 Cookie 失效。启动不访问 Pixiv，第一次读取作品时验证服务端有效性。会话损坏、格式未知、过期或时间回拨时拒绝恢复并删除。
- 关闭安全保存删除保存的会话，当前登录继续留在内存；退出登录还清理正文缓存和待保存导出文件。Android 同时删除应用专用 AES 密钥，其他平台删除对应的系统存储项，不删除操作系统的主密钥。
- 401 / 明确要求重新登录时先删除旧会话；换账号会取消旧请求并清空缓存。受限作品的 403 不会引发无限登录。
- 密钥和密码不写入 Git、日志或聊天，不通过命令行参数传递会话。Web 的 `secret-tool` 只从标准输入读取会话。正式 APK 的签名私钥与设备会话密钥用途独立，本功能不需要新配 Secrets，也不更换已发布证书。

自动恢复信任当前操作系统用户及其已授权应用。建议设置设备锁屏、为系统密钥环设置密码，并让桌面登录解锁密钥环；不要创建空密码密钥环。此功能不增加每次启动时的应用密码或生物识别步骤，不能保护已被控制的系统。内存中的 Cookie 用于网络请求，已导出文件和外部浏览器由用户管理。Apple Keychain 项可能在卸载应用后保留，卸载前可先退出登录，未退出的记录仍受本地 30 天上限限制。

AES-CTR 单独使用不验证密文完整性，因此 Android 选用 GCM；其他平台由系统凭据库管理加密。CRT 通常指公开证书，不是保存 Cookie 的格式。

### Linux / FreeBSD 配置

Linux 原生运行需要 `libsecret-1-0`，源码构建另需 `libsecret-1-dev`。GNOME / KDE 桌面通常已有密钥环，确保它已解锁且支持 Secret Service。Web 服务优先使用 `secret-tool`：

```sh
# Debian / Ubuntu
sudo apt install libsecret-1-0 libsecret-tools gnome-keyring dbus-user-session
# FreeBSD（以具备包安装权限的账号执行）
pkg install libsecret gnome-keyring dbus
```

从已登录的桌面会话启动本地服务，使其能访问当前用户的 D-Bus 和密钥环，然后在应用菜单开启安全保存。Shiori 不会代你创建空密码密钥环。没有桌面密钥环的终端或服务器环境继续支持内存登录；需要先配置并解锁系统密钥环才能保存。

Windows / macOS 上运行本地 Web 服务，可在服务所用 Python 环境安装官方 [keyring](https://keyring.readthedocs.io/en/latest/)：

```sh
python3 -m venv .venv
# Linux / macOS: source .venv/bin/activate
# Windows PowerShell: .venv\Scripts\Activate.ps1
python -m pip install keyring
python shiori_server.py --no-browser
```

服务显式选择 Windows Credential Locker、macOS Keychain 或 Secret Service 后端，不接受明文替代后端。未安装依赖时不显示 Web 的保存选项；原生 Windows / macOS 应用已内置对应支持，不需要 Python。

## 请求性能

v1.0.0 逐章串行请求，并在章节间固定等待 700ms，缓存命中也会等待。v1.1.0 使用同一个客户端连接池和全局请求队列：

- 最多同时处理 3 个请求，网络请求启动间隔至少 350ms；元信息、目录、预览和重试共用限流，不随章节数创建无限并发。
- 系列元信息与完整目录并行读取；同一小说的同时读取合并成一个请求，某个读取者取消不影响其他读取者。
- 内存 LRU 缓存上限 128 篇、400 万个 UTF-16 代码单元（正文和简介），有效期 10 分钟。缓存命中无需网络和人为等待，账号变更立即清空。
- 429 / 5xx / 超时触发共享冷却，最多尝试 3 次；支持 Retry-After 秒数和 HTTP 日期。超过一分钟的冷却直接提示稍后重试，不截短服务端要求后继续猛试。
- 每个网络请求超时 25 秒，取消能终止等待并中止支持取消的 HTTP 传输。失败会取消同一批次的其他读取，结果按目录位置组装，任何失败都不生成部分文件。
- 会话切换会使旧请求失效，旧正文不能重新填充缓存；Web 本地服务保留固定上游、TLS 验证和来源校验，并转发经过校验的 Retry-After。

真实速度仍取决于网络、Pixiv 响应和 PDF 排版耗时，限流不会绕过访问权限或验证码。

## 验证

```sh
flutter test --coverage
dart run tool/benchmark_client.dart
python3 -m unittest discover -s test -p 'test_*.py' -v
# 在对应宿主机 / iOS 模拟器上使用 linux、windows、macos 或模拟器 ID：
flutter test integration_test/session_storage_test.dart -d linux
# Android 模拟器 / 设备已连接，且已运行 flutter pub get：
cd android
./gradlew connectedDebugAndroidTest
```

性能基准模拟 12 章、每请求 300ms 的响应，将旧版串行 + 700ms 间隔与新版默认队列实际计时，并验证目录顺序、并发上限和重复提取的零网络请求。输出 `build/benchmark-client.json`，这是合成数据，不代表真实 Pixiv 网络测速。

开发验证 [Actions 42375988485](https://github.com/Jay-Void-BA/Pixiv-novel-extractor/actions/runs/42375988485) 的结果：旧循环 11,356ms，新队列 4,162ms（约 2.73 倍）；再次提取 571µs，新增网络请求为 0。该场景的响应耗时低于全局请求间隔，因此峰值网络并发为 1；另有乱序响应测试确认可达到且不超过 3 个并发，并保持章节顺序。

自动化还覆盖并发上限、请求间隔、请求合并与独立取消、缓存淘汰/过期、失败停止、共享冷却、退出后的旧响应丢弃和安全存储失败。Windows、macOS、Linux 和 iOS 模拟器的集成测试实际调用系统存储，检查保存、跨实例恢复、过期和删除。Linux / 本地 Web 使用独立 D-Bus 与随机密码保护的临时密钥环，测试密码不输出。Android 仪器测试使用独立测试别名和文件，实际调用 Keystore，检查 256 位不可导出密钥、重启恢复、新 nonce、篡改拒绝、丢失密钥、过期/未知格式和退出删除。测试仅使用自编会话值，不读取用户账号。

发布仍要求全部平台通过；所有系统密钥库集成测试与 Android Keystore 测试均为 Release 必需条件。正式 APK 必须通过发布证书指纹、非调试构建和 APK v2 签名验证，保持原有签名门禁。
