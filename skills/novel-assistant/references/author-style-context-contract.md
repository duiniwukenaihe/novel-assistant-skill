# Author Style Context Contract

本契约只在宿主平台向当前请求附带作者个人风格上下文，或要求返回个人校准结果时读取。它定义请求边界，不定义个人数据的采集、存储或画像编译。

## Capabilities

- `author_style_context_v1`：消费宿主在当前请求中附带的只读作者风格规则。
- `personal_calibration_v1`：返回结构化规则校准结果，供宿主决定是否持久化。

## Platform Envelope Mode

平台 envelope 必须是 JSON fenced context，并满足以下最小形状：

```json
{
  "schema": "author_style_context_v1",
  "storageOwner": "novel-project-postgresql",
  "profileId": "profile-optional",
  "rules": [
    {
      "id": "rule-1",
      "scope": "global|genre|work",
      "category": "lexical|grammar|rhythm|paragraph|dialogue|ai_flavour",
      "instruction": "可执行的写作或审核规则"
    }
  ],
  "outputContract": "personal_calibration_v1"
}
```

- `storageOwner: novel-project-postgresql` 是平台 envelope 模式的固定值；其他值视为未提供本契约上下文。
- skill 只在本次请求中读取 `rules`，不得把它们写入 skill 仓库、书籍目录、项目状态、追踪文件或任何本地缓存。
- skill 不得写入个人正文摘录、偏好、画像或校准结果。正文片段只能作为当前请求的临时上下文，不得被复制为长期资产。
- skill 不负责把规则升级、降级、合并或学习；这些决策和所有持久化均由 `novel-project-postgresql` 的宿主平台完成。

## Structured Calibration Result

skill returns a structured calibration result only for the current request.

当 `outputContract` 为 `personal_calibration_v1` 时，skill 只返回结构化校准结果，不自行应用规则或写回正文。结果应使用如下语义：

```json
{
  "schema": "personal_calibration_v1",
  "status": "completed|needs_author_decision",
  "items": [
    {
      "ruleId": "rule-1",
      "verdict": "supported|false_positive|needs_author_decision",
      "anchor": "当前正文中的短定位信息",
      "reason": "简短、可执行的判断理由",
      "suggestedAction": "保留|修改|忽略"
    }
  ]
}
```

`anchor` 仅用于让宿主定位当前请求内的内容，不应返回正文全文或建立可复用的摘录库。宿主负责展示结果、收集作者反馈并写入其 PostgreSQL。

## Standalone CLI Compatibility

独立 CLI 在无 envelope 时保持现有行为兼容：不要求连接 `novel-project`，不要求读取平台数据库，也不因本契约阻塞既有写作、审阅、回炉或恢复流程。普通请求没有本契约上下文时，不生成 `personal_calibration_v1` 结果。

本契约不新增项目目录中的个人资产文件，也不替代既有项目工作流或输出健康契约。
