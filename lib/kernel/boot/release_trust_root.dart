/// 发布信任根（Release Trust Root）：内嵌 Ed25519 公钥。
///
/// 信任模型：
/// - CI 构建时用对应**私钥**给引导清单（Boot Manifest）签名；
/// - 应用启动时用这里的**公钥**校验签名；签名不符 → 拒绝启动；
/// - 私钥**不再随仓库保管**：存放于 GitHub Actions Secret（`OGL_BOOT_KEY`），
///   由构建流程在 CI 内临时还原使用（轮换记录见 `.github/signing/README.md`）；
/// - **密钥版本：v3（fork 自有信任根）**。历史版本各自内嵌各自的清单与公钥，
///   不受影响；供本 fork 校验的外部签名物需由匹配 v3 的私钥签署。
///
/// 防脱节：`test/kernel/boot_release_chain_test.dart` 用**固定签名样本**
/// （`test/kernel/fixtures/release_key_signed_manifest.json`，由发布私钥签出）
/// 验证「内嵌公钥可验发布签名」，任何一边被改动都会红。
library;

/// 32 字节 Ed25519 公钥原始字节（v3 · fork 自有引导密钥）。
///
/// 本 fork（STARSHINE56/OhGithubLost）自 v7.6 起使用**独立引导信任根**：
/// 由 fork 维护者生成并持有私钥（Actions Secret `OGL_BOOT_KEY`），
/// 与上游 yingo-server 的 v2 密钥解耦。重签样本见
/// `test/kernel/fixtures/release_key_signed_manifest.json`。
///
/// base64：`Aj2UxDPv0exI7NFmwV+/11Okh89ZbzLZoHPfO1TNkP0=`
const List<int> kOgLReleasePublicKey = <int>[
  2, 61, 148, 196, 51, 239, 209, 236, 72, 236, 209, 102, 193, 95, 191, 215,
  83, 164, 135, 207, 89, 111, 50, 217, 160, 115, 223, 59, 84, 205, 144, 253,
];

/// 公钥的 base64 形式（日志与文档展示用）。
const String kOgLReleasePublicKeyBase64 =
    'Aj2UxDPv0exI7NFmwV+/11Okh89ZbzLZoHPfO1TNkP0=';