# 支持与使用边界

## 获取帮助前

请先确认：

1. 你安装的是单目录 `novel-assistant`，日常只调用 `/novel-assistant`；
2. skill 包已更新后，当前书籍项目是否也已刷新协作环境；
3. 你的目标是写作、审阅、拆文、扫榜、导入、去 AI 味还是维护；
4. 是否已有可恢复任务、结果包或错误信息。

安装和更新见 [docs/installation-and-update.md](docs/installation-and-update.md)，工作流行为见 [docs/workflow.md](docs/workflow.md)。

## 提交 issue 时请提供

- 使用的宿主：Claude Code、Codex、ZCode、OpenCode 或其他兼容宿主；
- skill 版本或 `bundleId`；
- 操作系统与安装方式（全局或项目内）；
- 目标类型和最小复现步骤；
- 脱敏后的错误输出、workflow 状态或结果包路径；
- 预期结果与实际结果。

请不要提交 API key、登录 token、个人书稿、完整受版权保护原文、私有地址或本机绝对路径。

## 支持边界

- 项目提供 workflow、记忆、质量门和宿主适配约束，不代管模型账号、账单、API key、代理或登录状态。
- 交互会话会保存断点与任务状态，但只有 runner 托管模式具备子进程级的自动恢复和健康中止能力。
- 公开版本使用公开内部模块；本地可选扩展由用户自行维护，不属于 GitHub 公开包的支持范围。
- 写作质量门降低明显污染与流程错误，但不能替代作者的审稿、事实核验、版权判断和发布前备份。

## 贡献入口

修复、文档、测试和设计建议请参见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请参见 [SECURITY.md](SECURITY.md)。
