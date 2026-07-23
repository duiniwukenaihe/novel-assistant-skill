# novel-project 出站事件消费契约

日期：2026-07-20

## 边界

`novel-assistant` 只管理当前目录内的一部短篇，并把已接受的业务事实追加到 `追踪/integration/outbox.jsonl`。

`novel-project` 后续可以消费这些事件，用于作品列表、素材库、跨作品学习、进度展示和长期作者偏好；相关数据库、接口、页面、轮询和迁移由 `novel-project` 自己实现，不属于本 skill 的运行依赖。

没有 `novel-project` 时，当前短篇仍必须能够从素材规划到全文完成。

## 事件

支持以下 `event_type`：

- `material_accepted`
- `setting_accepted`
- `outline_accepted`
- `section_accepted`
- `user_feedback_accepted`
- `story_completed`

每行是一个独立 JSON 对象，至少包含：

```json
{
  "schema_version": "1.0.0",
  "event_id": "...",
  "event_type": "section_accepted",
  "workflow_id": "wf-...",
  "project_id": "...",
  "project_title": "作品名",
  "artifact_path": "正文/第001节.md",
  "artifact_digest": "sha256:...",
  "evidence_hash": "sha256:...",
  "summary": "第1节已采用",
  "tags": ["short_write", "section_001"],
  "occurred_at": "2026-07-20T00:00:00.000Z"
}
```

## 消费规则

1. 以 `event_id` 幂等消费；不得依赖行号。
2. `artifact_path` 是相对作品根目录的路径，移动整个项目后仍然有效。
3. `project_id` 是作品身份，目录名和标题变化不能创建重复作品。
4. `workflow_id` 用于追踪事件来源，不代表当前界面焦点。
5. 只把 `section_accepted` 和 `story_completed` 当成正式正文事实；草稿或聊天回复不进入 outbox。
6. `user_feedback_accepted` 表示意见已经执行并通过工作流协议，不表示用户随口提出了意见。
7. 消费失败由外部管理器重试；不得删除、重排或改写 outbox。
8. 外部学习结果不得直接回写当前正文、设定、大纲或 workflow。需要影响当前作品时，必须作为新的用户可见建议进入反馈影响流程。

## 明确不提供

- 数据库表结构和 ORM。
- HTTP/WebSocket 接口。
- 前端卡片和页面状态。
- 跨作品素材去重算法。
- 外部消费确认或清理 outbox 的命令。

这些能力留给 `novel-project` 根据自身架构实现。
