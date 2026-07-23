# novel-project 持久化接管契约

## 目的

`novel-assistant` 定义写作业务契约和默认本地实现；`novel-project` 负责 PostgreSQL、用户权限、跨设备同步和前端展示。二者通过 adapter 与事件通信，skill 不直接依赖数据库驱动。

## 接管原则

1. 单一权威：一个项目同一时刻只能由 `local-file` 或 `novel-project-pg` 之一承担写入权威。
2. 身份与路径分离：领域主键使用 `project_id + project_instance_id + record_id`；本地绝对路径不得入库。
3. 任务与剧情分离：任务生命周期、剧情事实、制品版本、用户偏好分别存储，不共用一张万能 JSON 表。
4. 先提交后投影：正文/大纲采用事务成功后，才投影 StoryMemory 和下游制品索引。
5. 幂等同步：切换后端或离线恢复通过 outbox 事件重放，不能双主写入。

## 建议表域

| 域 | 最小表 | 关键字段 |
| --- | --- | --- |
| TaskStore | `workflow_task`、`workflow_stage`、`workflow_session_lease` | `workflow_id`、`task_family_id`、`stage_id`、`state_version`、`status` |
| StoryMemory | `story_fact`、`story_entity`、`story_promise`、`memory_revision` | `record_id`、`valid_from`、`valid_to`、`evidence`、`accepted_commit_id` |
| ArtifactStore | `artifact`、`artifact_revision`、`review_cache` | `relative_path`、`content_digest`、`planning_digest`、`memory_revision` |
| UserProfile | `user_preference`、`model_profile` | `scope`、`status`、`source_kind`、`version` |
| Integration | `integration_outbox`、`integration_inbox` | `event_id`、`aggregate_id`、`event_type`、`payload_digest`、`processed_at` |

正文等大文件可留在对象存储或工作区；数据库保存相对路径、内容摘要、版本和事务状态。私人语料由 novel-project 保存，skill 仅接收当前任务所需的最小快照。

## Adapter 能力

novel-project 注入的 adapter 必须满足 `scripts/lib/storage-backend-contract.js`：

- `capabilities()`：声明协议版本、authority 与事务能力。
- `projectIdentity()`：返回稳定项目身份。
- `readJson()` / `readText()` / `readJsonlLatest()`：兼容现有 repository 的只读接口。
- `sourceRevision()`：返回可比较的稳定 revision。

后续写入接口应提供 compare-and-swap、append-event 和 transaction；在这些能力落地前，PG adapter 只能作为只读副本，不能宣称已接管写入。

## 同步状态机

```text
local authority
  -> checkpoint
  -> flush outbox
  -> novel-project 导入并核对 revision
  -> 用户/宿主确认切换
  -> PG authority
  -> local backend 只读缓存
```

切换期间发生 revision 冲突时保持原 authority，生成冲突清单；不得选择“最后写入覆盖”。宿主掉线时写操作停靠或进入明确的本地分支，不能悄悄形成第二权威。

## 安全与隐私

- 数据库地址、账号、密码和令牌由 novel-project 管理，不写入 skill、作品目录或日志。
- Result Packet 和 outbox 默认不携带完整正文，只携带 artifact 引用、摘要和必要事实增量。
- 用户私有短篇增强、资讯池、作者画像与训练样本不得进入公开 bundle。

## 验收

1. 同一项目移动目录后 `project_id` 与任务/记忆身份不变。
2. 本地和 PG 对同一查询返回等价的类型化结果与 revision 语义。
3. 焦点切换不改变其他 workflow 的任务快照。
4. 记忆变更只使依赖该 revision 的 Brief/审阅缓存失效。
5. outbox 重放两次不会重复创建事实、承诺或任务阶段。
6. 断网、重启或多会话竞争不会产生两个可写 authority。
