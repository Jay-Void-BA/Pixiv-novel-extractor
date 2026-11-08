# Android 首次正式发布签名

本项目尚未正式发布 Android APK。首次发布使用**本地新生成的发布密钥**，不沿用 Drive 交付包的测试签名。正式版本发布后，保留该密钥和密码用于后续升级。

## 1. 在自己的电脑生成发布密钥

安装 JDK 17、Python 3.10+ 和 GitHub CLI，并更新本地源码。以下操作在自己的终端完成；密钥文件放在 Git 仓库之外。

macOS / Linux：

```sh
umask 077
mkdir -p "$HOME/.config/pixiv-novel-extractor/signing"
keytool -genkeypair -v \
  -keystore "$HOME/.config/pixiv-novel-extractor/signing/shiori-release.jks" \
  -storetype JKS -alias shiori -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Pixiv Novel Extractor Release"
```

Windows PowerShell：

```powershell
$shioriSigningDir = Join-Path $env:APPDATA 'PixivNovelExtractor\signing'
New-Item -ItemType Directory -Force $shioriSigningDir | Out-Null
keytool -genkeypair -v `
  -keystore (Join-Path $shioriSigningDir 'shiori-release.jks') `
  -storetype JKS -alias shiori -keyalg RSA -keysize 4096 -validity 10000 `
  -dname "CN=Pixiv Novel Extractor Release"
```

按提示设置强密码。输入密码时终端不回显。私钥密码可以与密钥库密码相同（提示时按 Enter），也可以单独设置；后面的配置脚本支持两者。JKS 的格式迁移提示不表示生成失败。

安全备份 JKS 文件及密码。不要把 JKS、密码或其 Base64 内容发送到聊天、提交到 Git、写进工作流文件或添加到 Release 附件。

## 2. 安全配置 GitHub Actions Secrets

在同一台电脑的**仓库根目录**执行。GitHub 登录账号需要该仓库的 Secrets 管理权限。

```sh
git pull --ff-only origin main
gh auth login
python3 tool/setup_android_signing.py \
  --keystore "$HOME/.config/pixiv-novel-extractor/signing/shiori-release.jks" \
  --alias shiori --repo Jay-Void-BA/Pixiv-novel-extractor
```

Windows PowerShell 使用：

```powershell
git pull --ff-only origin main
gh auth login
python tool/setup_android_signing.py `
  --keystore (Join-Path $shioriSigningDir 'shiori-release.jks') `
  --alias shiori --repo Jay-Void-BA/Pixiv-novel-extractor
```

脚本隐藏询问两个密码，检查密钥和私钥访问，拒绝 Android Debug 证书，再通过 `gh secret set` 的**标准输入**上传以下五个 Secrets。Base64 只在进程内存中生成，不写入文件、不打印、不作为命令参数传递。

| Repository Secret | 内容 |
| --- | --- |
| `SHIORI_KEYSTORE_BASE64` | 新发布 JKS 文件的 Base64 |
| `SHIORI_KEYSTORE_PASSWORD` | JKS 密钥库密码 |
| `SHIORI_KEY_ALIAS` | 私钥别名，此处为 `shiori` |
| `SHIORI_KEY_PASSWORD` | 私钥密码，可与密钥库密码不同 |
| `SHIORI_SIGNING_CERT_SHA256` | 脚本从发布证书 DER 自动计算的 SHA-256 指纹 |

可在 [仓库 Secrets 设置](https://github.com/Jay-Void-BA/Pixiv-novel-extractor/settings/secrets/actions) 或以下命令确认五个名称存在；GitHub 不会返回 Secret 值。

```sh
gh secret list --repo Jay-Void-BA/Pixiv-novel-extractor
```

中途上传失败时修正本地 GitHub 权限后重跑脚本，使五项配置全部一致。不要在日志或聊天中排查、粘贴 Secret 值。

证书指纹属于公开校验信息，区别于私钥及密码；发布验证报告可包含该指纹。

## 3. 先验证正式签名

在 GitHub Actions 的 **Build, test & release → Run workflow** 中选择 `main`，启用 `verify_android_signing`。也可从终端执行：

```sh
gh workflow run delivery.yml --repo Jay-Void-BA/Pixiv-novel-extractor \
  --ref main -f verify_android_signing=true
```

此运行构建并验证正式 APK，**不会发布 GitHub Release**。完整成功后，`android-release` artifact 包含：

- `shiori-android.apk`：使用新发布密钥签名的 APK。
- `android-signing-verification.json`：公开校验报告，包含 APK SHA-256、证书 SHA-256、版本及非调试状态。

工作流验证：

1. 五项 Secrets 齐全，JKS 可打开，别名和私钥密码有效，证书指纹匹配。
2. Android SDK `apksigner` 验证成功，APK Signature Scheme v2 有效。
3. APK 的签名证书与预先配置的指纹完全相同，证书不是 Android Debug，Manifest 未设置 `debuggable`。
4. 应用 ID、最低 API 24、三种原生架构、字体和许可证齐全，ZIP 对齐正确。

JKS 仅写入 runner 临时目录，目录权限 `0700`、文件权限 `0600`。密码只在需要的步骤通过 Secrets 环境变量传入。成功或失败都会删除临时签名文件；密钥不进入缓存、Artifact 或 Release。

预检另有 `android-signing-proof` Artifact，只包含公开的签名验证 JSON，便于单独下载核对证书指纹、版本及 APK 摘要，不含密钥或密码。

普通 `main` / PR 运行只构建开发 APK，不读取发布密钥；其 artifact 为 `android-development`，文件为 `shiori-android-debug.apk`，不能通过正式发布检查。

## 4. 验证通过后发布

维护者确认上述运行成功后，在**相同已验证提交**上创建正式版本标签。标签运行仍会构建全部平台，并在发布前重新验证最终 APK 的实际签名、证书指纹及文件 SHA-256，检查报告与该 APK 对应。任何签名条件不满足都会中止，Release 保持未发布状态。

`v1.0.0` 已正式发布。后续版本沿用已备份的正式发布密钥，使用新的版本号与标签；不要移动已发布标签或替换其公开附件。正式标签必须指向该版本通过验证的提交。

Release 附件包含正式 APK、签名验证报告、其他平台归档及覆盖这些附件的 `SHA256SUMS.txt`。已有草稿可在所有检查通过后补齐并正式发布。
