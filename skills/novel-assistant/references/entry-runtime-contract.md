# novel-assistant 入口运行时契约

仅当顶层入口需要解释或执行启动自检、更新确认、两层更新、运行时同步或宿主执行能力时读取本文件。普通写作、审阅、拆文、扫榜和自由目标路由不得预读本契约。

## 启动自检与项目识别

- 只以当前工作目录为书籍根；不得向上查找父目录、书库目录或相邻书籍，不得把父目录或书库目录的 `.story-deployed` 当作当前书状态。`.story-deployed`、`.book-state.json`，或 `正文/`、`大纲/`、`设定/`、`追踪/` 中任意两个目录，均识别为写作项目；含 `CLAUDE.md` 的 legacy 目录同样成立。
- 项目缺少 `.story-deployed` 时按 `status=not_deployed` 处理，不能因为未部署而跳过启动自检或读取章节状态。
- 可执行环境允许时直接运行一条命令：`node <当前 skill 包>/scripts/novel-assistant-update-check.js <project-root> --json`。脚本从自身安装目录发现相邻 manifest；不得先 `cd` 到 skill 目录，不得追加 `&&`、管道、重定向、命令替换或 `|| true`。优先使用当前 skill 包中的脚本，项目脚本仅为 fallback。
- 无法运行 `novel-assistant-update-check.js` 时，直接读取 `.story-deployed` 与 `novel-assistant-manifest.json` 比较 bundleId；不一致即为 `update_available`。启动自检不得把 Bash 权限确认作为第一屏：优先用 Read/LS，不得先用 Bash cat。

## 更新确认响应

`current` 继续路由；`not_deployed` 与 `update_available` 必须暂停正常路由。确认点必须保存：

```json
{
  "type": "update_environment",
  "interaction_renderer": "host_select_preferred",
  "render_mode": "text_numbers",
  "fallback": "text_numbers",
  "expected_reply_set": ["1", "2", "确认", "是", "yes", "y", "不", "否", "no", "n", "later"]
}
```

可见菜单固定为：

```text
1. 现在更新写作协作环境
2. 暂不更新，继续原意图
```

`确认/是/yes/y` 等同于 1，`不/否/no/n/later` 等同于 2；不得只输出“回复确认”。

## 宿主选择器适配协议

可见回复只问是否现在更新写作协作环境，先给稳定数字选项；`interaction_renderer=host_select_preferred`、`render_mode=text_numbers`、`fallback=text_numbers`，宿主支持时优先渲染 host_select，出现 `host_select_failed` 时退回数字文本。不得直接调用原始 AskUserQuestion，不得把 pending_action 原始结构打印给用户。

在用户回答前，不读取 `.book-state.json`、`追踪/workflow/current-task.json`、章节交接包、拆文 `_progress.md`、章节状态或当前书写作进度；不得同时给出“继续写/审阅/回炉/下一章”等候选。误读到业务状态时丢弃它并回到更新确认。

用户回答 `1`、确认、是、yes 或 y 时，只读取 `story-setup` 更新协作环境；回答 `2`、否、no、n 或 later 时，保留原意图后再读项目状态，并只提示协作环境可能落后。运行时更新只同步 hooks / agents / rules / scripts / references / `.story-deployed`，不修改正文、大纲、细纲；目录迁移、章节重排、资产移动或冲突始终另行确认。

## 两层更新协议

检查更新、更新本地 skill 与更新书籍协作环境不能混为一步：不得把 skill 更新和当前书籍项目的协作环境更新混为一步。用户说“检查更新 / 有没有新版”时只执行：

```bash
node scripts/novel-assistant-self-update.js --skill-dir <当前 skill 包> --project-root <当前书籍项目> --json
```

结果必须区分 `stable_update_available`、`development_update_available`、`current` 与 `blocked_dirty_worktree`。用户明确说“更新 skill / 更新本地 skill / 更新 novel-assistant”时先检查，再经确认执行：

```bash
node scripts/novel-assistant-self-update.js --skill-dir <当前 skill 包> --apply --channel stable --json
```

开发版只在明确确认后使用 `--channel development`。本地 skill 更新只更新发行包与安装目录，不修改书目创作资产。

当前书籍协作环境更新使用单条同步入口：

```bash
node scripts/novel-assistant-sync-runtime.js --project-root . --json
```

该命令必须在当前书籍项目根目录逐字执行。不得把 `<当前 skill 包>`、`<当前书籍项目>` 等占位符原样传给 shell；同步脚本会自动发现本机最新安装包。

只有脚本缺失、Node 不可用或返回结构化错误时才进入 `story-setup` 手工部署分支。更新完成后运行 `workflow-entry-guard.js --write --json` 并逐字使用 `visible_response.text`；停在任务收件箱，不自动执行旧任务。重建任务、具体任务卡和推荐必须等用户选择后展示。

`blocked_pending_feedback_unreconciled`、会话租约待接管等带有确定性候选的状态属于“等待用户选择”，不是 shell 执行错误。入口守卫应以 0 退出，并在 `visible_response.options[].execution_command` 给出唯一恢复命令。宿主不得把 `action` 名称拼成 entry guard 参数，也不得重复打印任务卡编号后再给操作编号。

任务收件箱展开页也必须自带选择协议。`show_unfinished_tasks` 返回 `selection_contract=execute_task_card_command_or_route_intent` 时，任务卡数字只触发卡片的 `activate` 命令；激活后的运行阶段依靠 `stage_execution.resume_hint` 恢复。任务卡数字不是 pending-action 数字，严禁用空的 `pending_action_id` 调 `resolve-action`。

## 宿主与执行能力

纯 Claude CLI 场景优先用 Read/LS 读取部署状态，避免 Bash 权限确认成为第一屏。runner 可后台执行检查并注入 JSON；无 runner 时，只在用户明确选择检查、更新或诊断部署状态后运行脚本。无人值守授权预算由 runner 统一管理；同一 workflow 不得让用户反复点允许，超出预算必须返回 `permission_budget_exceeded` 并保存可信断点。

### Claude Code / Codex CLI / Codex Desktop / ZCode 统一适配

- 状态机返回给交互宿主的后续命令必须使用 `--project-root .`，并同时返回 `execution_workdir=.`。这里的 `.` 始终指用户启动 `/novel-assistant` 时所在的当前书籍根目录。脚本自身仍兼容外部调用者传绝对路径。
- 四种宿主都必须先把执行目录设为当前书籍根，再逐字执行命令；不得把绝对书籍路径重新拼回工具参数。宿主已经位于书籍根时，省略工具调用中的显式 `workdir`；宿主必须传目录时只传 `.`，不得重新生成中文绝对路径。这样项目复制、改名、中文长路径和跨工具接力都不会破坏任务恢复。
- `selection_contract=resume_running_stage` 表示确认已经完成，并触发同轮原子执行：宿主先逐字执行 `stage_execution.context_read_command`，按 `resume_hint` 限制在 `write_set`，随后必须在任何普通可见回复之前执行 `stage_completion_command`/`execution_command` 并消费返回结果。不得复制或重写 `packet_md` 路径，不得重新显示旧菜单，也不得把 finalize 命令提前到暂存资产修改之前执行。暂存文件写完不等于阶段完成；预期结果包尚未被接受时禁止回复“只差提交”。
- 当前消息只有 `/novel-assistant` 或 skill mention 时，`--user-intent` 必须为空，不得复用上一轮意图。若存在运行中阶段，入口显示固定四项：继续当前阶段（推荐）/ 查看当前进度与依据 / 暂停并保存断点 / 输入其他要求。只有选择 1 后返回的 `resume_running_stage` 才允许无二次确认执行；2/3/4 不能被解释成继续。
- Codex Desktop 的工具调用若在命令启动前出现 JavaScript/JSON 参数解析错误，属于 `host_tool_call_malformed`，不是业务脚本语法错误。只允许在继承当前书籍根目录的前提下，用原始相对短命令重试一次；不得重新生成绝对 `workdir`。再次失败时保留断点，并显示固定恢复菜单：`1. 重试当前阶段（推荐） / 2. 查看当前进度与依据 / 3. 暂停并保存断点 / 4. 输入其他要求`；不得把内部命令甩给用户，也不得声称 workflow 脚本有语法错误。
- 命令真正启动后，才依据退出码和结构化 JSON 判断业务状态。`status=blocking`、`blocked_*`、质量门未通过属于正常工作流分支；Node `SyntaxError` 只有在 stderr 明确指向实际脚本文件与行号时才可报告为脚本语法错误。

每次调用必须给出中文可见回复。长回复、受污染输入和恢复文案遵循 `output-safety-contract.md`；候选和选择必须落入 workflow 状态文件。长任务由 runner 管理会话生命周期、恢复、工具调用、成本与完成证据，不依赖聊天记忆或多 agent 并写生产文件。
