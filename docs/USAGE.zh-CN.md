# Shiori 栞 · 使用方法

Pixiv 小说提取器 v1.0.0 · 2026-11-07

## 先选适合你的文件

- Android 手机：下载 `01_安装包/shiori-android.apk`。支持 Android 7.0 及以上，包含 arm64-v8a、armeabi-v7a 和 x86_64 三种架构。
- Linux x64 电脑：下载 `01_安装包/shiori-linux-x64.tar.gz`。基于 Ubuntu 24.04 构建，需要兼容的 GTK 3、glibc 和 C++ 运行库。
- FreeBSD：下载 `01_安装包/shiori-web-freebsd.zip`。这是 Flutter Web UI 加 Python 本地服务，需要 Python 3.10+ 和现代浏览器，不是原生 ELF 程序。
- 桌面浏览器登录：另下载 `01_安装包/shiori-browser-bridge.zip`，按下文加载扩展。
- 开发或自行构建：`02_源码与开发资料/shiori-source-v1.0.0.zip` 包含六个平台的工程、README、测试与 CI 工作流；Git 历史备份为 `shiori-git-history-v1.0.0.bundle`。

本次实际提供 Android、Linux、Web / FreeBSD 和浏览器扩展包。Windows、macOS、iOS 尚未生成经过验证的安装包；它们的工程在源码中。iOS 需要在 Mac 上用自己的 Apple 开发团队或个人证书签名后安装。GitHub 上传仍返回 403，远程 CI 和 GitHub Release 尚未执行。

## Android 安装

1. 在 Google Drive 打开 `01_安装包`，下载 `shiori-android.apk`，不要下载源码 ZIP 作为手机安装包。
2. 在系统「下载」或文件管理器中打开 APK，按系统提示允许当前浏览器或文件管理器「安装未知应用」。
3. 完成安装，打开「Shiori 栞」。读取作品需要能访问 Pixiv 的网络环境。

本包使用项目发布密钥签名，已通过官方 apksigner 验证。APK 的 SHA-256 校验值见交付根目录 `SHA256SUMS.txt`。Android 真机登录尚未在当前云环境验证。

## Linux 启动

将安装包放到一个目录，在终端执行：

```sh
mkdir -p shiori
tar -xzf shiori-linux-x64.tar.gz -C shiori
cd shiori
./shiori
```

保留 `shiori` 旁边的 `lib/` 与 `data/` 目录。若出现缺少 GTK 或共享库的提示，先通过发行版的软件包管理器安装所缺运行库；较老的 glibc 环境可从源码在本机重新构建。当前包已通过 Ubuntu 24.04 环境的原生构建和窗口启动检查。

## FreeBSD / 本地 Web 启动

FreeBSD 管理员先安装依赖：

```sh
pkg install python311 ca_root_nss chromium
```

解压并以普通用户启动：

```sh
unzip shiori-web-freebsd.zip -d shiori-web
cd shiori-web
python3.11 shiori_server.py
```

服务会分配本机端口并尝试打开浏览器。若没有自动打开，复制终端显示的 `http://127.0.0.1:端口/`。按 Ctrl+C 停止服务。

此 Web 包也可在已安装 Python 3.10+ 的 Linux、macOS、Windows 上使用。在这些系统中将启动命令改成 `python3 shiori_server.py`，Windows 也可使用 `py -3 shiori_server.py`。这条兼容路径不代表已完成对应平台的原生构建或真机测试。

必须启动随包 Python 服务；不要双击 `web/index.html`，也不要直接把 Web 文件上传为普通静态网站。服务只监听本机，渲染器和中文字体随包提供，读取 Pixiv 仍需要网络。

## 提取单篇小说

1. 粘贴小说链接，例如 `https://www.pixiv.net/novel/show.php?id=12345678`，也可直接输入小说 ID。示例 ID 只用于说明格式。
2. 点击「读取作品」，确认标题、作者和章节内容。
3. 选择 TXT 或 PDF，按需设置文件名、作品信息和 PDF 字号。
4. 点击导出。Android 打开系统分享 / 保存界面；Linux 打开保存对话框；Web 版由浏览器下载文件。

TXT 使用带 BOM 的 UTF-8，方便常见文本编辑器识别中文。PDF 嵌入中文字体，可直接阅读；作品插图以原文链接或占位文本保留，不嵌入图片。

## 选择合集中的部分章节并合并

1. 输入系列链接，例如 `https://www.pixiv.net/novel/series/1234567`，点击「读取作品」。
2. 逐章勾选，或输入 `2, 4-6` 并点击「应用」，表示选择目录第 2、4、5、6 章。这里的数字是目录序号，不是小说 ID。
3. 可使用全选、清空、反选或标题筛选。标题筛选仅改变显示，不会自动取消已经选中的章节。
4. 核对所选章节，选择 TXT / PDF 后导出。所选章节按原始目录顺序合并成一个文件。

任何所选章节读取失败都会中止这次导出，不会保存缺章的半份文件。取消保存后可使用「再次保存」，无需重复提取。

## 需要登录时

### Android / iOS

应用会打开 Pixiv 官方网页的应用内浏览器。完成登录和验证码后通常会自动返回；若未返回，点击右上角「已完成登录」。应用通过系统 WebView Cookie API 取得当前会话并重试读取。密码只提交给 Pixiv 官方页面。

若 Pixiv 拒绝嵌入式浏览器，可使用右上角菜单的「导入会话」备用入口。iOS 本次只提供源码，需自行构建和签名后使用。

各平台都可开启自动恢复：右上角「会话与帮助」→「在此设备安全保存登录」→「开启安全保存」。已登录时保存当前会话，未登录时在下次登录后保存。重启后自动恢复，最长 30 天，Pixiv 也可能提前使会话失效。不需要手动生成 AES 密钥或添加 GitHub Secrets。

默认关闭。关闭选项删除已保存的会话，当前登录可使用到关闭应用；「退出并清除会话」同时清理内存与保存内容。Android 使用 Keystore，Apple 使用 Keychain，Windows 使用 DPAPI，Linux 使用系统密钥环。Web/FreeBSD 需先配置本地服务的系统密钥环，才会出现安全保存选项。系统密钥库未解锁或不可用时会提示错误。详见 [平台配置与安全说明](SECURITY_AND_PERFORMANCE.md)。

### Linux / 桌面 Web / FreeBSD

1. 解压 `shiori-browser-bridge.zip`。
2. Chrome / Chromium 打开 `chrome://extensions`，Edge 打开 `edge://extensions`，启用开发者模式，点击「加载已解压的扩展程序」，选择解压目录中的 `chromium/`。
3. Firefox 打开 `about:debugging#/runtime/this-firefox`，临时加载 `firefox/manifest.json`。临时扩展在重启后需要重新加载；持续安装需要自行签名。
4. 回到 Shiori 触发登录，在自动打开的本机连接页点击扩展连接按钮，在扩展页面确认授权，再登录 Pixiv。
5. 如果浏览器已经登录 Pixiv，点击「连接当前会话」。连接完成后返回 Shiori。连接页有效期为五分钟，过期后重新发起登录。

扩展只在确认后将 Pixiv 的 PHPSESSID 发往本机。默认在关闭应用时清除内存会话；主动开启安全保存后可在重启时恢复。退出会话会删除保存的登录信息，外部浏览器的登录状态单独保留。

### 手动导入会话

在已登录 Pixiv 的桌面浏览器开发者工具中，打开 Application / Storage → Cookies，找到 PHPSESSID，复制它的值；在 Shiori 右上角菜单选择「导入会话」并粘贴。不要粘贴完整 Cookie 字符串。PHPSESSID 相当于账号访问凭据，不要分享，也不要写入源码、截图或说明文档。

## 常见问题

- 403 或非 JSON 页面：可能是网络验证或 Pixiv 风控，也可能是需要登录。先在浏览器确认可以正常打开原作，再回应用重试。403 不会触发无限循环登录。
- 登录后仍无权访问：确认当前账号本来就有阅读权限，作品未删除、未隐藏。登录不会改变作品权限。
- 扩展无法加载：检查是否选中了 `chromium/` 目录或 Firefox 的 `manifest.json`。受管理的浏览器可能禁止加载扩展，可使用允许加载扩展的个人浏览器或备用会话导入。
- 手机没有找到文件：导出后需在系统分享界面选择保存位置或目标应用。选择 TXT 便于在手机文本阅读器中打开。
- PDF 个别罕见字或 Emoji 显示异常：字体覆盖范围有限，可改用 TXT 并在阅读器中选择支持该字符的字体。
- Web 页面打不开：保持终端中的 Python 服务运行，并使用终端显示的实际本机地址。

## 源码恢复与自行构建

普通开发可解压源码 ZIP。若需要完整 Git 历史，将 bundle 文件放在当前目录并执行：

```sh
git clone shiori-git-history-v1.0.0.bundle pixiv-novel-extractor
cd pixiv-novel-extractor
git remote remove origin
```

安装 Flutter 3.47.9 / Dart 3.13.7 及对应平台工具链后：

```sh
flutter pub get --enforce-lockfile
flutter analyze --fatal-infos
flutter test
```

常用构建命令为 `flutter build apk --release`、`flutter build linux --release`、`flutter build windows --release`、`flutter build macos --release`。iOS 需 Xcode / CocoaPods，先运行 `flutter build ios --release --no-codesign`，再在 Xcode 的 Runner 签名设置中选择自己的 Team 并安装到设备。未签名 iOS 应用不能直接安装。

Android 正式发布需持续使用原发布密钥；未配置发布密钥的本地开发构建使用调试签名，不能直接覆盖当前发布签名 APK。CI 所需 Secrets 为 `SHIORI_KEYSTORE_BASE64` 与 `SHIORI_KEYSTORE_PASSWORD`，密钥别名为 `shiori`。签名材料不在源码包或 Git 历史备份中。

## 校验、测试与许可

下载后可在 macOS / Linux 用 `shasum -a 256 文件名` 或 `sha256sum 文件名`，Windows 用 PowerShell `Get-FileHash 文件名 -Algorithm SHA256`，与根目录 `SHA256SUMS.txt` 对照。FreeBSD 可用 `sha256 文件名`。

`03_验证记录与截图` 保存本地验证记录、真实界面截图与自编测试作品的导出样例。已完成 16 项 Flutter、5 项 Python、6 项浏览器扩展逻辑测试，以及 Web UI 下载、长文 PDF、Linux 原生窗口和 Android APK 成品检查。真实私人账号登录、FreeBSD 真机及 Windows / macOS / iOS 原生构建仍需进一步验证。

源码采用 BSD-2-Clause；随包字体采用 SIL Open Font License。项目与 Pixiv 无隶属关系，请只保存有权访问的作品，并尊重作者版权。
