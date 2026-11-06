# 本地验证记录

环境：Linux x64，Flutter 3.47.9 / Dart 3.13.7，2026-11-06。

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

尚未验证 / 需要外部条件：

- 当前云网络访问 Pixiv 返回 403 / 非 JSON 验证页面；未使用真实私人账号进行登录和受限作品端到端测试。
- 当前环境的 Chromium 管理策略禁止加载未打包扩展；没有修改或绕过管理策略。扩展逻辑通过模拟浏览器 API 测试，真实加载与官方登录需在允许扩展的用户浏览器中验证。
- 当前 Linux 环境无原生桌面工具链，且无系统包安装权限；原生 Linux、Android、Windows、macOS、iOS 构建应由仓库 Actions 执行。当前不能将这些任务描述为已通过。
- FreeBSD 服务尚未在本地 FreeBSD 主机运行，工作流已配置 FreeBSD VM 测试。
- GitHub 推送和 Release 需确认目标仓库与可见性。当前尚未上传代码、运行远程 CI 或创建 Release。

复现命令见 README 和 `.github/workflows/delivery.yml`。CI 成功记录应以实际工作流运行页面为准。
