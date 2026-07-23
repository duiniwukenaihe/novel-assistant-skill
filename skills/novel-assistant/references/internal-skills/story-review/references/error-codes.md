# error-codes.md：审查错误码

本文件定义 `story-review`、`story-long-write` 稳定性门控和后续自动化脚本共用的错误码。报告可以写中文解释，但机器可读字段必须使用本文件中的英文 code。

## 严重度

| 严重度 | 含义 | 处理 |
|---|---|---|
| S1 | 破坏主线、角色动机、世界规则或读者信任 | 必须修复后才能继续 |
| S2 | 明显影响章节效果、留存、节奏或一致性 | 必须修复，或由用户明确确认保留 |
| S3 | 局部质量问题 | 可排入待修清单 |
| S4 | 建议项或风格微调 | 不阻断 |

## 长篇稳定性错误码

| Code | Category | 默认严重度 | 触发条件 | 修复方向 |
|---|---|---|---|---|
| `Plot_Drift` | structure | S1/S2 | 正文偏离当前卷目标、本章核心事件或章尾期待 | 回到 Chapter Contract，删除或改写偏离段落 |
| `Beat_Missing` | structure | S1/S2 | Chapter Contract 或细纲中的必须情节点没有在正文中出现 | 补写缺失 beat，或修改 contract 并说明原因 |
| `Beat_Compressed` | structure | S2 | 多个重要情节点被一句摘要带过，缺少过程、冲突或反馈 | 拆成可感场景，补行动、阻碍、代价和反馈 |
| `Canon_Conflict` | consistency | S1 | 违反既有设定、时间线、能力限制、平台硬约束或写作宪法 | 统一事实来源，并同步正文/设定/追踪 |
| `Motivation_Drift` | character | S1/S2 | 角色行为不符合底层欲望、当前目标、关系压力或已写性格 | 补足动机链，或改回符合角色的行动 |
| `Knowledge_Leak` | character | S1 | 角色知道了其当前认知边界外的信息 | 删除泄漏信息，或补充合理获知过程 |
| `Foreshadow_Early_Payoff` | structure | S1/S2 | 伏笔提前兑现、提前泄底或破坏后续期待 | 改为推进/误导/半兑现，保留后续期待 |
| `Untracked_Addition` | consistency | S2 | 新增人物、设定、支线、势力、规则或重要物件但未进入设定/追踪文件 | 将新增项写入角色/设定/伏笔/时间线/上下文 |
| `State_Not_Updated` | consistency | S2 | 正文改变了角色、关系、资源、能力、伏笔或时间线，但追踪文件未同步 | 写 State Delta，并同步对应追踪文件 |

## 通用审稿错误码

| Code | Category | 默认严重度 | 触发条件 | 修复方向 |
|---|---|---|---|---|
| `Weak_Hook` | structure | S2/S3 | 章首或章尾没有形成问题、期待或情绪拉力 | 加入冲突、信息差、未完成动作或明确代价 |
| `Emotion_Flat` | structure | S2/S3 | 情绪没有铺垫、升温、释放或反转 | 重排情绪曲线，补触发事件和反馈 |
| `Dialogue_InfoDump` | prose | S2/S3 | 对话承担说明书功能，缺少潜台词和角色差异 | 改为冲突式对话，用动作和误解承载信息 |
| `AI_Slop` | prose | S2/S3 | 出现模板化句式、总结体、泛化词或 AI 腔 | 转 `/novel-assistant 去AI味` 或按 anti-ai-writing 规则改写 |
| `Format_Blocker` | format | S2/S3 | 格式影响阅读，例如段落过长、空行混乱、正文混入说明 | 按目标平台格式重排 |

## Findings Schema

```yaml
- severity: S1 | S2 | S3 | S4
  code: Plot_Drift | Beat_Missing | Canon_Conflict | Motivation_Drift | AI_Slop
  category: structure | character | prose | consistency | platform | factual | format
  location: 文件路径:行号 或 章节/段落描述
  evidence: "引用原文或具体证据"
  issue: "问题描述"
  fix: "可执行修改建议"
```
