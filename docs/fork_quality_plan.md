# Fork 全仓优化计划与第一批交付

## 边界

先在 STARSHINE56/OhGithubLost 的独立开发分支优化，再考虑上游合并。
不改 main，不推送 OGL-Teams；不删功能，不替换签名私钥，不强推。
大文件不是自动重写理由：优先修复可证实问题，再按测试覆盖分批拆分。

## 第一批：已修改

- 手机/桌面导航目的地与页面索引分离；补有无 AI 两种映射回归测试。
- 切页动画的 RepaintBoundary 移到静态页面子树，保留所有现有动效。
- CI 覆盖 improvement/feature/starshine56 分支，启用实际截图落盘、AI 安全自检。
- 正式发布复用同提交质量门，校验非空引导注入和签名信任链。
- 新增 ARM64 Release，保留 universal APK 和 AAB；共用已有签名及 versionCode。
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

本机为 Android Alpine aarch64，无 Flutter/Dart SDK；没有跑 Flutter analyze、
Flutter test、新增导航测试或 AI Dart 安全自检。旧提交 CI 成功不能证明本批已通过。
没有配置安全推送凭据，因此本批只在本地提交，不声称 GitHub 已更新。

## 后续阶段（未完成）

1. 将第一批推至 Fork 独立分支并跑完整 CI；不先合 main。需安全配置新 GitHub Token。
2. 真机验证导航、登录/切号、通知已读、动画；增加导航 widget 测试及性能基线。
3. 验证 ARM64 签名包、启动、覆盖安装和体积；用同架构/同模式包比较，不预先承诺 23MB。
4. 用仓库指定 Flutter SDK 解析并提交真实 pubspec.lock；不能手工伪造锁文件。
5. 专项核查 AI 写入与账号切换竞态，扩展确认弹窗期间切号回归；未复现前不定性为漏洞。
6. 对 repo_page/settings_page/ai_service/repo_file_service 分模块评审：在行为测试锁定后逐步拆分，避免大规模重写。
7. 审查网络重试、缓存失效、下载队列、磁盘持久化与错误路径；按可复现问题独立提交。
8. 源码版本及说明统一在下一次正式发版时处理，不擅自创建或覆盖历史版本标签。
9. 上游合并单独评审：公共修复可 cherry-pick；Fork 信任根、签名配置和发布策略不可盲目覆盖上游。
