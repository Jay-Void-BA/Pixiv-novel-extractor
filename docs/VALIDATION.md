# 本地验证记录

环境：Linux x64，Flutter 3.47.9 / Dart 3.13.7，2026-11-06。

Linux 原生构建补充验证：2026-11-07，Ubuntu 24.04 x64 容器、GTK 3、Xvfb / 软件 OpenGL。

Android 原生构建补充验证：2026-11-07，Temurin JDK 17、Android SDK 36、NDK 28.2，发布密钥签名。

已完成：

- Dart 格式检查、`flutter analyze --fatal-infos`：通过。
- 16 项 Flutter 测试：通过，覆盖核心请求、系列选章、错误处理、导出和手机 / 桌面布局。
- 5 项 Python 本地服务测试：通过。
- 6 项 Node 浏览器扩展逻辑测试：通过，包括确认前不读取 Cookie、只向本机发送、过期连接与域名限制。
- Release Web 编译：通过；本地 CanvasKit、字体、可分发 Web / FreeBSD 包与扩展包已生成。
- 真实 Chromium 中的 Flutter UI 集成测试：通过。用自编系列选择第 2、4 章，分别下载 TXT 和 PDF，TXT 中没有未选章节；浏览器没有运行时异常。
- 浏览器导出的两页 PDF 经 Poppler 确认，顺序为第 2、4 章，中日文字可恢复。
- 长文导出为 50 页 A4 PDF，Poppler 独立提取检查确认长段落与全部末尾段落没有截断。
- 解压 ZIP 完整性检查：通过。源码清单不包含发布密钥、口令、缓存或导出文件。
- Linux 原生 Release 编译通过；进程成功启动、显示 GTK 窗口并保持运行，[截图](screenshot-linux.png)。运行库检查没有缺失的共享库。
- Android Release APK 编译通过；官方 `apksigner` 校验 APK v2 / RSA 3072 签名通过。确认应用 ID、最低 API 24、arm64-v8a / armeabi-v7a / x86_64 三种架构，以及随包的中文字体和许可证；`zipalign` 检查 16 KB ZIP 对齐。CI 已加入同样的成品检查。

尚未验证 / 需要外部条件：

- 当前云网络访问 Pixiv 返回 403 / 非 JSON 验证页面；未使用真实私人账号进行登录和受限作品端到端测试。
- 当前环境的 Chromium 管理策略禁止加载未打包扩展；没有修改或绕过管理策略。扩展逻辑通过模拟浏览器 API 测试，真实加载与官方登录需在允许扩展的用户浏览器中验证。
- Android 尚未进行真机启动与登录测试；Windows、macOS、iOS 的原生构建尚待仓库 Actions 执行，当前不能将这些任务描述为已通过。
- FreeBSD 服务尚未在本地 FreeBSD 主机运行，工作流已配置 FreeBSD VM 测试。
- 已确认在 `Jay-Void-BA/Pixiv-novel-extractor` 公开发布，源码采用 BSD-2-Clause；远程 CI 和 Release 的结果以仓库 Actions / Releases 页面为准。
- 当前 GitHub 连接的写入请求仍返回 403；代码尚未推送，远程 CI 与 Release 尚未执行。

复现命令见 README 和 `.github/workflows/delivery.yml`。CI 成功记录应以实际工作流运行页面为准。
