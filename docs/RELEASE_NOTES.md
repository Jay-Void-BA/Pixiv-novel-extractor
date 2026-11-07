## Shiori 栞 1.1.0

Flutter Pixiv 小说提取器：单篇 / 系列目录，逐章选择与范围选择，正文预览，按原始顺序合并为 UTF-8 TXT 或带中日文字体的 PDF。

源码采用 BSD-2-Clause；随包字体保留 SIL Open Font License。

- 提取性能：由串行请求改为最多 3 个并发、至少 350ms 的全局启动间隔。目录信息并行读取；同章请求合并，缓存命中不再等待。
- 请求安全：共享 429 / 服务错误冷却，支持 Retry-After；取消、失败和账号切换会停止排队请求，章节仍按原目录顺序合并。
- Android 登录记忆：会话菜单中主动开启「在此设备安全保存登录」，使用 AES-256-GCM 与不可导出的 Keystore 密钥，最长 30 天。只保存 PHPSESSID，不保存 Pixiv 密码；关闭选项或退出登录会删除密文及密钥。
- 添加请求队列测试、合成性能基准与 Android 模拟器上的真实 Keystore 安全测试。其他平台的登录会话仍只驻留内存。

- Android：`shiori-android.apk`，沿用 v1.0.0 正式发布密钥；证书指纹与预先配置的指纹匹配，APK 非可调试构建。可覆盖安装正式 v1.0.0。`android-signing-verification.json` 提供公开签名验证记录。
- Linux：`shiori-linux-x64.tar.gz`，解压整个目录后运行 `./shiori`；需要 GTK 3。
- Windows：`shiori-windows-x64.zip`，解压整个目录后运行 `shiori.exe`；可能需要 Microsoft Visual C++ 2015–2022 x64 运行库。
- macOS：`shiori-macos-<架构>.zip`，未经过 Developer ID 公证。解压后右键打开；不要只复制包内可执行文件。
- iOS：`shiori-ios-unsigned.zip`，包含未签名的 `Runner.app`，**不能直接安装**。使用个人 / 开发者证书重新签名，或按 README 从源码构建。
- FreeBSD：`shiori-web-freebsd.zip`，Flutter Web UI + Python 本地服务；不是原生 ELF。详见包内 README。
- 桌面浏览器登录扩展：`shiori-browser-bridge.zip`。移动端使用应用内 Pixiv 网页登录。扩展未在商店分发，需按包内说明加载。

所有预期平台构建和自动化测试通过后，工作流才发布本 Release。`SHA256SUMS.txt` 可校验附件。Pixiv 的登录验证码和作品权限由 Pixiv 处理；本应用不绕过权限或验证码。插图以链接 / 占位文本保留，不下载嵌入图片。未使用真实私人账号运行自动登录测试。
