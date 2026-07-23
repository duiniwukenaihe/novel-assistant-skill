# plot-drift-control.md：剧情漂移门控

Plot Drift Gate 在单章机器门禁通过后执行，用 Chapter Contract、细纲、追踪文件和角色不变量验证本章是否稳定推进。它不替代机器门禁；AI 句式、工程词、破折号密度、模型复读、正文路径、字数和格式问题必须先在 Chapter Machine Gate 修到 blocking 清零。

## 执行时机

- 每章正文写完并通过 Chapter Machine Gate 后、宣布章节完成前。
- 章节回炉或重写后。
- 用户要求“检查是否跑题”时。

## 检查顺序

1. 对照 Chapter Contract 检查必须 beat。
2. 对照当前卷纲检查卷目标推进。
3. 对照角色不变量检查动机和认知边界。
4. 对照伏笔文件检查提前兑现、遗忘和新增伏笔。
5. 对照追踪文件检查状态是否同步。

## 错误码

| Code | 默认严重度 | 判定 |
|---|---|---|
| `Plot_Drift` | S1/S2 | 正文偏离本章核心事件或当前卷目标 |
| `Beat_Missing` | S1/S2 | Chapter Contract 中的必须 beat 未出现 |
| `Beat_Compressed` | S2 | 必须 beat 被摘要化，没有形成可感场景 |
| `Canon_Conflict` | S1 | 与既有设定、时间线、宪法或能力限制冲突 |
| `Motivation_Drift` | S1/S2 | 角色行为缺少动机链或违反底层欲望 |
| `Knowledge_Leak` | S1 | 角色知道了当前阶段不该知道的信息 |
| `Foreshadow_Early_Payoff` | S1/S2 | 伏笔提前兑现、泄底或破坏期待 |
| `Untracked_Addition` | S2 | 新增人物、设定、支线、势力、规则但未入账 |
| `State_Not_Updated` | S2 | 正文发生状态变化但追踪文件未同步 |

## 输出模板

```md
## Plot Drift Gate：第 N 章

### 结论
- Gate: PASS / FAIL
- 需要修复的 S1/S2：

### Findings
| severity | code | evidence | issue | fix |
|---|---|---|---|---|

### 修复后复检
- 已修复：
- 用户确认保留：
```

## 通过规则

- 有 S1 时不得标记章节完成。
- 有 S2 时必须修复，或由用户明确确认保留。
- S3/S4 可进入待修清单，不阻断日更。
