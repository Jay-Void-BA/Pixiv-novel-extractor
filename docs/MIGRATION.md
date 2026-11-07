# Drive 迁移与复核记录

日期：2026-11-07。

来源为 Google Drive **Primary** 中的「Shiori 栞 — Pixiv 小说提取器 v1.0.0（2026-11-07）」交付目录。源码恢复到 `Jay-Void-BA/Pixiv-novel-extractor` 的仓库根目录，各平台工程、测试、打包脚本、字体、许可证与文档均保留。

## 完整性

使用原交付中的 `FILE_INDEX.json` 校验以下文件的 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `shiori-source-v1.0.0.zip` | `8afc42d22b6a73b699de579345c454307d50b739f63fa0c24694b594b135e72d` |
| `shiori-git-history-v1.0.0.bundle` | `4d0280b3fd1be442557dcaa2533cac2272159297e4cc40d984264bea3531d2b4` |
| `shiori-validation-v1.0.0.zip` | `da0e27543c32bbf080bf2d7e82cf3e3445e4321cd40ca71be5f5e97d71bead31` |

`git bundle verify` 确认 bundle 包含完整历史，无外部前置提交要求。恢复的 `main` 原始末端提交为 `42b698bdee6f45637cb4249c469c8ac151360688`，共 6 次提交；该提交的 **173 个受版本控制文件**与源码 ZIP 逐个进行字节比较，路径集合及全部文件内容一致。

迁移后另行提交项目结构、开发指南、编辑器配置和文档状态更新，保留原始提交内容与作者信息。

## 本次执行的检查

环境：Linux x64，Python 3.12.14，Node.js 24.22.1。

- 原始 ZIP 与 bundle 的 SHA-256：通过。
- Git 历史完整性及源码逐文件比较：通过。
- `python3 -m unittest discover -s test -p 'test_*.py' -v`：5 项通过。
- `node --test test/extension_test.cjs`：6 项通过。
- `python3 tool/package_extension.py`：成功生成 Chromium / Firefox 扩展包，ZIP 完整性检查通过。
- `bash -n tool/native_linux_smoke.sh`：通过。

当前迁移环境没有 Flutter / Dart SDK，因此本次没有重新执行 Flutter 分析、Flutter 测试或原生编译。原交付中的 Flutter、Web、Linux 与 Android 验证记录保留于 [VALIDATION.md](VALIDATION.md)，不能视为本次重新构建的结果。后续自动化验证以 [Actions](https://github.com/Jay-Void-BA/Pixiv-novel-extractor/actions) 实际运行结果为准。

## 交付范围

源码仓库保存开发所需的完整工程结构。原始安装包与验证归档继续保留在 Drive，未将 APK、桌面二进制文件、缓存或生成目录作为源码提交。正式二进制发布由 `.github/workflows/delivery.yml` 管理。此前未正式发布过 Android APK；首次发布使用本地新生成的发布密钥及仓库 Secrets，见 [签名指南](ANDROID_SIGNING.md)。
