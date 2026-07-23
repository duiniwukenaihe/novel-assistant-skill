# 旧项目生命周期索引迁移协议

适用入口：`node scripts/workflow-legacy-migrate.js --project-root <book-root> --source <source> --json`。

## 来源与预演

- 只接受显式的受支持来源：`worldwonderer/oh-story-claudecode`（可写为 `oh-story`）和旧 `novel-assistant`（可写为 `novel-assistant` 或 `novel-assistant-previous`）。
- `long_write` 旧任务还必须在任务元数据或 `.story-deployed` 中留下受支持来源证据；`--source` 只声明期望来源，不能单独充当来源证明。
- `.story-deployed` 只接受明确仓库标识，或同时包含合法 bundle ID 与 `novel-assistant` bundle 名称的已知 JSON / key-value 格式；任意单独 bundle 字段和未知格式一律阻断。
- 未带 `--write` 时永远是预演，不创建文件。预演输出固定包含 `source`、`detected_assets`、`inferred_maturity`、`proposed_lifecycle_node`、`unresolved_conflicts` 和 `creative_files_changed:false`。

## 写入边界

- 写入必须同时带 `--write --workflow-id <id>`，且只对预演中的 `legacy_longform_lifecycle_index` 项生效。
- `workflow_id` 必须是非空、安全 basename，并且只含受支持的 ASCII 字母、数字、点、下划线和连字符；不符合时不得生成快照路径或进入写入边界。
- 写入只创建 `追踪/workflow/longform-lifecycle.json` 和 `追踪/workflow/archived/<workflow-id>.lifecycle-migration-snapshot.json`。
- 迁移器不得修改 `正文/`、`大纲/`、细纲或设定；`creative_files_changed` 恒为 `false`。旧任务进入只读历史状态，新的当前协议继任任务成为焦点。
- 已存在生命周期索引是未解决冲突，迁移器不得覆盖它。

## 任务族与控制面迁移

`task-family-migrate.js` 只处理 workflow 控制面元数据：任务族、分支身份、任务权威标记和焦点指针。它必须在预演中声明 `metadata_only=true` 和 `authority_metadata_changes[]`，并在写入后证明 `creative_assets_unchanged=true`。

- 耐久任务快照 `追踪/workflow/tasks/<workflow_id>/task.json` 是唯一任务权威；迁移写入 `task_family_id`、`branch_id`、`branch_status` 与 `authority_metadata`。
- `追踪/workflow/current-task.json` 只能作为 UI 焦点指针，字段限于 `schemaVersion`、`workflow_id`、`task_dir`、`focused_at`、`state_version`。迁移不得把完整任务重新写回 current-task。
- 迁移不得修改 `正文/`、`大纲/`、`细纲/`、`设定/`、`追踪/伏笔.md`、`追踪/上下文.md` 或审查报告正文。
- 旧 `current-task.json` 若仍是完整任务，可作为输入读取；迁移后必须转换为 pointer-only。缺少耐久任务快照时，应创建或修复 `tasks/<workflow_id>/task.json`，不得继续让 current-task 充当事实来源。

## 推断规则

- 生命周期资产只从既有可信路径发现；发现到的创作资产写为 `needs_review`，未发现的资产写为 `missing`。
- `inferred_maturity` 由索引状态推导；`proposed_lifecycle_node` 是最近需要审阅、修复或生产的节点。
- 旧任务中的固定 50 章批次、四 agent 配置和章节队列只保存于历史快照，绝不复制进生命周期索引。迁移必须创建新的当前协议继任任务；继任任务从最早未可信验收节点继续，不能在旧任务上补字段后冒充升级完成。
- 发现到的文件默认是 `needs_review`，只有明确的当前验收回执才能继承为 `accepted`。旧任务、历史快照、生命周期索引和继任任务通过 `previous_workflow_id / superseded_by / source_workflow_id` 保持可追溯关系。
