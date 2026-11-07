# Linux 桌面版

在 GTK 3 桌面环境解压整个目录，运行：

```sh
./shiori
```

保留启动器旁的 `lib/` 和 `data/`。不要只复制 `shiori` 可执行文件。本包使用 Ubuntu 24.04 x64 工具链构建，其他发行版需要兼容的 GTK 3、glibc 和 C++ 运行库。

首次遇到登录要求时，会打开系统浏览器中的本机连接页。请按浏览器扩展包 `shiori-browser-bridge.zip` 的说明加载 Shiori Bridge，确认连接后在 Pixiv 官方网站登录；也可在右上角菜单导入 PHPSESSID。会话仅保留在本机内存中。

选择章节和 TXT / PDF 格式后导出，桌面保存对话框可选择文件位置。所选章节按原始目录顺序合并；失败时不会保存半份文件。

程序源码采用 BSD-2-Clause，见随包 `LICENSE`；字体保留 OFL 许可。项目、完整说明和构建记录：https://github.com/Jay-Void-BA/Pixiv-novel-extractor
