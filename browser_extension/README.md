# Shiori Bridge

桌面版 / FreeBSD Web 版的可选浏览器扩展。无需把浏览器的所有 Cookie 导出。

1. 解压 Release 的 `shiori-browser-bridge.zip`。
2. Chromium / Chrome / Edge：打开 `chrome://extensions` 或 `edge://extensions`，启用开发者模式，**加载已解压的扩展程序**，选择 `chromium/`。
3. Firefox：打开 `about:debugging#/runtime/this-firefox`，临时载入附加组件，选择 `firefox/manifest.json`。这是未签名的临时扩展，浏览器重启后需要重载；持续安装需要自行通过 Mozilla 签名。
4. 在 Shiori 点击登录。浏览器本机连接页点击扩展连接按钮，在扩展页面确认授权，然后登录 Pixiv。
5. 如果已登录，直接在扩展确认页点击「连接当前会话」。完成后返回 Shiori。

权限仅限 `*.pixiv.net`、`127.0.0.1`、Cookie API 和会话存储。仅读取 `PHPSESSID`，只在明确授权后通过带随机令牌的请求发送至本机。Cookie 不写入扩展存储；待连接信息保存在 `storage.session`，五分钟后失效。关闭应用或退出会话后应用会清除内存中的 Cookie；扩展不注销你浏览器中的 Pixiv。

不要向他人分享本机连接页的完整地址。扩展不会操作密码、绕过验证码或改变账号权限。
