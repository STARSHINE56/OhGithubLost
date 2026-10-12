# Fork 全仓优化计划与第一批交付

## 边界

先在 STARSHINE56/OhGithubLost 的独立开发分支优化，再考虑上游合并。
用户已授权更新 Fork main；新改动先通过独立分支 CI 再快进合入。
不推送 OGL-Teams，不碰上游 main；不删功能，不替换签名私钥，不强推。
大文件不是自动重写理由：优先修复可证实问题，再按测试覆盖分批拆分。

## 第一批：已修改

- 手机/桌面导航目的地与页面索引分离；补有无 AI 两种映射回归测试。
- 切页动画的 RepaintBoundary 移到静态页面子树，保留所有现有动效。
- CI 覆盖 improvement/feature/starshine56 分支，启用实际截图落盘、AI 安全自检。
- 正式发布复用同提交质量门，校验非空引导注入和签名信任链。
- Android 仅构建 ARM64 APK（用户追加要求）；移除其他 ABI、universal/AAB 构建，共用已有签名及 versionCode。
- 新增不解压、不修改 APK 的大小报告，包含实际字节数、各 ABI 原生库、资源和 DEX 占比。
- 更新上游仓库名条件，移除不存在的 best_effort 字段。
- 更新 Fork v3 签名说明；不改变公钥和实际签名逻辑。
- 发布标签 target_commitish 绑定构建 SHA，缺产物直接失败，不取消正在进行的发布。

## 本地验证

- 6 项全仓 Python 审计通过：layer/i18n/motion/perf/stats/platform injector。
- APK 报告工具 3 个离线测试通过。
- 全部 Actions 工作流通过 actionlint 1.7.4（禁用 shellcheck 外部检查）。
  两个已使用的 hosted ARM64 runner 标签在 actionlint.yaml 补充，未忽略其他错误。
- git diff --check 通过。

本机为 Android Alpine aarch64，无 Flutter/Dart SDK；Flutter 验证在 Fork CI 执行。
第一批 b790fee 已通过 CI 并合入 Fork main；ARM64-only 为 c1da184。
第二批阶段提交 b132def 的 CI 38318894033 已通过：analyze 0 issues、
23 AI safety selftests、503 Flutter tests passed。后续增量需要自己的 CI 结果。

## 第二批：运行时、安全与存储

- 修复 desugaring 注入标错行和单行 dependencies 漏依赖，补边界及幂等回归。
- AI 请求显式绑定提案/会话账号，队列等待及返回时切号均拒绝串号结果。
- 页面销毁/被覆盖后取消 AI 写入确认；设置保存固定快照，避免访问释放的控制器。
- 主壳认证及聊天加载使用代次，拒绝旧结果覆盖新状态。
- 后台暂停轮询，恢复补查，网络失败指数退避，切号重置。
- 模型列表按地址/协议/密钥缓存 5 分钟；手动检测强制刷新，失败不缓存。
- 提取 AiConversationStore：单会话加密写入、索引串行更新、旧数据可重试迁移。
  迁移成功后清旧快照；不再隐式丢弃第 50 条以后的会话。
- pubspec.lock 来自指定 SDK 的真实 CI artifact，跟踪版本并用 --enforce-lockfile 校验。
- 新增缓存、切号、迁移失败/并发/隔离/历史完整性及 UI 生命周期回归测试。

这不是所有源码都重写完成；未取得真机基线前不声称性能提升百分比或零 Bug。

## 后续阶段（未完成）

1. 每批改动推至 Fork 独立分支并跑完整 CI，通过后才合 Fork main。
2. 真机验证导航、登录/切号、通知已读、动画；增加导航 widget 测试及性能基线。
3. 验证 ARM64 签名包、启动、覆盖安装和体积；用同架构/同模式包比较，不预先承诺 23MB。
4. 锁文件已跟踪；后续依赖升级需重新解析锁文件并全量测试，不能手工伪造。
5. AI 账号绑定已加强；仍需真机验证确认弹窗期间切号与页面退出等组合场景。
6. 对 repo_page/settings_page/ai_service/repo_file_service 分模块评审：在行为测试锁定后逐步拆分，避免大规模重写。
7. 审查网络重试、缓存失效、下载队列、磁盘持久化与错误路径；按可复现问题独立提交。
8. 源码版本及说明统一在下一次正式发版时处理，不擅自创建或覆盖历史版本标签。
9. 上游合并单独评审：公共修复可 cherry-pick；Fork 信任根、签名配置和发布策略不可盲目覆盖上游。
