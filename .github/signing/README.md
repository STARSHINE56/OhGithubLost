# OGL 固定签名配置

平台目录由 `flutter create` 生成。`tool/platform_spec.yaml` 声明固定签名，
`tool/inject_platform_spec.py` 修改生成的 Gradle Kotlin DSL。预览 APK、正式 APK
及 AAB 共用 `oglRelease` 签名配置；预览保留原来的 debug 模式及启动校验。

## Actions Secrets

仓库 Settings → Secrets and variables → Actions：

| Secret | 内容 |
| --- | --- |
| `OGL_ANDROID_KEYSTORE` | 长期 Release keystore 文件的 Base64 |
| `OGL_ANDROID_STORE_PASSWORD` | Keystore 密码 |
| `OGL_ANDROID_KEY_PASSWORD` | 私钥密码 |
| `OGL_ANDROID_KEY_ALIAS` | 私钥别名 |
| `OGL_ANDROID_CERT_SHA256` | 对应证书 SHA-256，64 位十六进制 |
| `OGL_BOOT_KEY` | 正式发布原有 Ed25519 引导私钥，与 APK 签名无关 |

`tool/android_signing.py prepare` 将 keystore 写到 runner 临时目录，密码及别名
写到被忽略的 `android/key.properties`，权限均为 0600。缺少签名 Secret、证书
指纹不匹配或 Gradle 模板变化均会停止构建，没有临时签名回退。工作流结束清理
私密文件；只上传安装包和不含秘密的签名核验报告。

密钥只允许首次配置时生成一次，绝对不能在工作流中生成。维护者应妥善保管
带外备份。GitHub API 无法读取 Secret 明文，不要覆盖 Secrets 或重新生成密钥。
仓库、提交历史和日志中禁止新增 keystore、Base64 密钥、密码及个人令牌。

## 版本号和验证

两条流程以从 2020-01-01 起的秒数作为 Android versionCode 下限，取它、pubspec
版本号和手动输入的最大值。手动输入是 Android 版本号的下限，桌面保持原行为。
正式构建全架构共用 manifest job 的同一个版本号。正常连续运行会递增；同秒
运行可能相同，Android 支持同版本覆盖安装。版本号不得超过 2100000000。

Gradle 直接签名，没有构建后重签。APK 用 `apksigner verify --verbose --print-certs`
验证签名完整性，核对唯一签名者 SHA-256、`com.yingo.ohgithublost` 包名及实际
versionCode，失败则不上传 APK。报告为 `build/android-signing-report.json`。

## 旧版本覆盖安装

修复前 fork 的 `preview.yml` 没有固定签名，使用各 runner 随机生成的 Debug
证书。v7.5.2 发布 APK 的证书 SHA-256：

`18512f7d5a218dc3a6c09bc5e8c2d4c2b93ecf5165b975ea3ac877ae4e3a2da4`

没有原私钥就不能用新签名直接覆盖这些旧 APK，APK 公钥证书无法恢复私钥。
先导出可导出的应用数据，再卸载旧签名版本一次。首次安装固定签名版本后，
后续包名相同、签名相同且版本号不降低的 APK 可覆盖安装并保留数据。

本次固定签名证书 SHA-256：

`6de3100f44fd49f255277a3683dee0a06c525345e500dd111bfd78d1c3df4f35`

上游 Ed25519 启动校验保持原样：正式 `build.yml` 仍需与内嵌公钥匹配的
`OGL_BOOT_KEY`。本次 APK 签名修复不生成或轮换这把密钥。
