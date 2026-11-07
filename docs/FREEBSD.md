# FreeBSD / 本地 Web 版

FreeBSD 不在 Flutter 官方原生支持的平台中。本包由同一套 Flutter UI 编译而来，通过本机浏览器使用，**不是 FreeBSD 原生 ELF 程序**。本地 Python 服务仅用于托管 UI、转发固定的 Pixiv 小说接口和接收浏览器登录会话，不依赖第三方后端。

## 启动

```sh
pkg install python311 ca_root_nss chromium
unzip shiori-web-freebsd.zip -d shiori
cd shiori
python3.11 shiori_server.py
```

服务随机分配本机端口并尝试打开浏览器。如果未自动打开，复制终端显示的 `http://127.0.0.1:端口/`。停止服务按 Ctrl+C。无需安装 Dart 或 Flutter。也可在其他有 Python 3.10+ 的系统上运行。

```sh
python3.11 shiori_server.py --no-browser
# 源码开发，先 flutter build web --no-web-resources-cdn：
python3 freebsd/shiori_server.py --web-root build/web
```

## 登录与导出

公开作品可直接读取。需要登录时，会打开本机连接页。按 `shiori-browser-bridge.zip` 中的 README 加载 Chromium / Firefox 扩展，在扩展确认页允许连接并登录 Pixiv；也可在应用右上角菜单导入 PHPSESSID。

浏览器 Cookie 受浏览器隔离机制保护，普通 Web 页面无法自动读取其他网站的登录状态，因此桌面浏览器登录需要扩展或手动导入。扩展只在你确认后将会话传回本机；实际 Cookie 不进入 Flutter Web 界面。

选择章节、格式后点击导出，浏览器会下载合并文件。没有选择的章节不会被请求。PDF 字体和 CanvasKit 均随包附带，不依赖 Google 字体 / 渲染器 CDN。

## 网络与权限

仅监听 `127.0.0.1`，不能修改为公网地址。控制接口有随机授权令牌、Host 和 Origin 校验；代理只接受三个固定的小说接口模式，不支持任意 URL。TLS 验证保持开启。配置代理可使用 Python 标准库支持的 `HTTPS_PROXY` 等环境变量。

默认关闭进程即清除内存中的会话与连接令牌；主动开启安全保存后，重启会恢复系统密钥环中的会话，最长 30 天。退出登录会删除已保存会话。安装 `libsecret`、运行并解锁 GNOME Keyring / Secret Service 后，可在应用菜单开启，见 [安全保存配置](SECURITY_AND_PERFORMANCE.md)。不要把本机接口暴露到公网，不要分享带连接令牌的地址。浏览器扩展的会话权限足以访问账号内容，请只安装受信任源码。
