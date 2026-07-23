# Runtime Contract Index

这个文件是 `/novel-assistant` 的运行契约索引，用来把入口 skill 从“所有规则都堆在一个文件里”逐步收束为“入口只保留硬门禁，细节按需读取”。

## 启动硬门禁

- 更新确认硬门禁：先处理 skill / 协作环境更新提醒，再进入业务候选。
- 统一前置守卫：`scripts/workflow-entry-guard.js` 按固定顺序执行 runtime supervisor、task inbox 和可见输出门禁，返回 `business_routing_allowed` 后才允许进入业务路由。
- 运行时巡检：`scripts/workflow-runtime-supervisor.js` 判定 running / stalled / resumable / blocked_runtime_guard_missing。
- 全局任务收件箱：`scripts/workflow-task-inbox.js` 只读汇总长篇、短篇、审阅、拆文、下载/续更等任务，并写入 `追踪/workflow/task-index.json`。

## 工作流大脑

- Canonical contract: `story-workflow/references/workflow-contract.md`
- 维护性内核：`story-workflow/references/maintainability-kernel.md`
- 成本治理：`story-workflow/references/token-cost-governance.md`
- AI Native 小说生产吸收契约：
  - `story-workflow/references/quality-debt-policy.md`
  - `story-workflow/references/structured-intent-routing.md`
  - `story-workflow/references/story-assets-ledger.md`
  - `story-workflow/references/style-asset-engine.md`

`story-workflow` 负责 workflow packet、result packet、pending_action、runtime_guard、checkpoint、heartbeat、下一步候选和完成后推荐。L3 专业模块只消费 packet 并回传结果，不各自发明长任务状态。

## 平台个人写作资产（按需）

- Canonical contract: `author-style-context-contract.md`

仅当宿主平台在当前请求中提供个人风格 envelope 或要求返回个人校准结果时读取。本契约规定平台与 skill 的无状态边界；普通独立 CLI 写作不预读，也不依赖平台服务。

## 输出健康门

- Canonical contract: `story-workflow/references/output-safety-contract.md`
- 可见输出检查：`scripts/output-pollution-check.js`
- 模型退化短模板：`scripts/blocked-recovery-template.js`
- 工具污染预检：`scripts/tool-call-degradation-check.js`
- 写入失败分诊：`scripts/write-failure-triage.js`

正文、报告、修复方案、下一步候选和 recap 风格状态句都属于可见输出。命中重复循环、工程词泄露、伪完成、工具 transcript 污染时，必须先隔离污染段，再从最后可信断点恢复。

## 发布隔离

- 开发分支允许存在私有子 skill、内部 demo、superpowers 设计稿。
- GitHub 公开分支必须走清理后的 `github/public-release` worktree。
- 发布前运行：`node scripts/na-dev.js release-status --json`
- 公开审计运行：`node scripts/na-dev.js release-audit --json`

开发分支的 `public-release-audit` 失败不代表本地不可用；它是在提醒当前分支含私有资产，不能直接推到公开 GitHub。

## 入口文件边界

`SKILL.md` 只应承担：

1. 单入口安装和用户命令兼容说明。
2. 启动硬门禁和路由优先级。
3. 指向本索引及内部模块的最小导航。
4. 少量必须直接出现在入口中的安全红线。

新增长规则时，优先放入 `references/` 或 `story-workflow/references/`，再在入口文件用一句话引用。只有需要被所有会话第一时间看到的硬门禁，才放回 `SKILL.md`。
