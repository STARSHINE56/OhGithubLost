# Fork 助手 GitHub 能力与授权边界

模型只有本地白名单工具，没有 Token 明文、任意 URL、请求头或 shell。
GitHub 实际权限由用户已有 Token、组织策略和仓库角色共同决定；增加工具不会
自动提升 OAuth scopes 或 fine-grained PAT 授权，403/404 必须如实报告。

## 新增工具

`github_read`：current_user、my_repositories、starred_repositories、search_repositories、
notifications、my_gists、organizations、repository、branches、commits、releases、
issue_comments、pull_files、collaborators、labels、milestones、workflow_runs、
workflow_jobs、workflow_artifacts、repository_permissions。

账号级读取不需要先选仓库；仓库列表 100 条/页，需要逐页调用才能声称“所有”。
默认 visibility=all，包含 Token 允许访问的私有仓库和组织/协作仓库，不只是自己创建的仓库。

`github_manage`：create/update/delete/fork_repository、star/unstar/watch/unwatch_repository、
create/delete_branch、create/update/delete_release、issue_comment、merge/close_pull、
rerun/cancel_workflow、mark_notification_read/mark_all_notifications_read、
create/update/delete_gist、add/remove_collaborator、create/delete_label、create_milestone。

所有写操作先本地验证，固定账号/目标/参数快照，再显示确认弹窗；取消或切号不执行。
合并 PR 需要明确 HEAD SHA；不支持 force push。删除、合并、权限修改等可能不可逆，
通用管理审计不承诺自动回滚。已有文件修改、Issue/PR 创建更新、Actions dispatch 和
原有回滚功能继续保留。

## 参数示例

- 读取账号仓库：`{action: my_repositories, page: 1}`。
- 创建仓库：`{action: create_repository, body: {name: example, private: true}}`。
- 发布 Release：`{action: create_release, repository: owner/repo, body: {tag_name: v1.0, name: Release, body: Notes, draft: false}}`。
- 合并 PR：`{action: merge_pull, repository: owner/repo, number: 1, body: {sha: <40位HEAD SHA>, merge_method: squash}}`。

## 明确不提供

不开放读取/导出 Secrets、Token、安全凭据、任意 GitHub API 透传、强推、账单、组织
管理员/企业管理员、用户私钥、Webhook Secrets 和未经实现的接口。不能声称覆盖
Token 所有可能的 scope。需要补充具体能力时，增加单独白名单并附安全与失败回归。

## 键盘修复

键盘守卫原先只识别 Focus.context.widget 本身为 EditableText，漏掉内部 Focus 上下文。
现在也检查 EditableText 祖先，真实输入保留 inset；无输入焦点仍过滤幽灵 inset。
AI 页明确避让键盘，主壳手机底栏在键盘弹起时隐藏。自动测试检查文本输入不被遮挡；
真机 Android 输入法/字体/横屏组合仍需用户验收。
