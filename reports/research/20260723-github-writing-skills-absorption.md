# GitHub 写作 Skill 参考评审

日期：2026-07-23

## 结论

本轮以 GitHub 原仓库为唯一源码锚。SkillHub 只用于发现候选与诊断镜像漂移，不作为版本、许可证或吸收依据。

立即吸收一项：将 `serial-novel-architect` 中“先建立故事承重结构”的方法 clean-room 重写为共享 `story-load-bearing-contract.md`，供 workflow、短篇、长篇和审阅按需读取。没有新增用户可见 skill，没有复制外部 prompt。

## GitHub 锚点

| 候选 | GitHub 原仓库 | 默认分支 / HEAD | Tag | 许可证 | 结论 |
|---|---|---|---|---|---|
| `short-drama-writer` / `story-writer` | `bytesagain/ai-skills` | `main` / `aba92922e3f0` | 无 | 未发现仓库许可证 | 包装与命令说明多，专业方法浅；不进入运行时 |
| `chinese-novelist-skill` | `PenglongHuang/chinese-novelist-skill` | `master` / `6c507e0221cc` | `v1.0` | README 标注 MIT，但当前 HEAD 未包含 LICENSE 文件，按未知许可处理 | 分层问答和断点检测可参考；拒绝全书无确认生成、固定字数和三轮自动重写 |
| `novel-outliner` | `Shine8592/novel-writer-skills` | `main` / `fd60fbdd4d25` | 无 | 未发现仓库许可证 | 仅登记“多格式大纲归一化”为后续适配器候选；拒绝固定 12000 字、逐章 prompt 文件和粗糙质量脚本 |
| `serial-novel-architect` | `DaveRoey96/serial-novel-architect` | `main` / `3dbef782a64d` | 无 | 未发现仓库许可证 | clean-room 吸收故事脊柱、压力系统、揭示后果；不复制目录与文案 |

## 吸收映射

| GitHub 方法 | 本项目落点 | 边界 |
|---|---|---|
| 故事脊柱 | workflow 共享合同 | 事件、卷入原因、不可退出、不可逆选择 |
| 压力系统 | 短篇规划、长篇大纲/卷纲/细纲 | 外部、内部、关系、价值与拖延代价按任务选用，不机械填表 |
| 真相必须昂贵 | Brief、Chapter Contract、故事门、审阅 | 重大揭示必须改变危险、关系、判断或选择成本 |
| 多尺度结构 | 短篇“全篇 + 小节”；长篇“全书 + 卷/阶段 + 章节” | 不写死章节数或字数 |
| 多格式大纲输入 | 仅登记候选 | 等真实导入需求出现后再做结构化 adapter，不提前增加脚本 |

## 明确拒绝

- 不吸收“一次确认后自动写完整本书”。长任务仍由 workflow 的阶段完成策略控制。
- 不吸收固定 3000、5000、12000 字等硬编码篇幅。
- 不吸收“所有数字必须中文”“固定主角名/境界词”一类题材污染检查。
- 不为每章生成独立 prompt 文件；使用阶段 context packet 和正式任务快照。
- 不把字段名缺失等同于故事缺失；只读审阅先做语义映射。
- 不新增 `short-drama-writer`、`story-writer` 或 `novel-outliner` 用户入口。

## 其他 GitHub 增量

- `wen1701/FanqieRankTracker` 从 `fb1abf86aceab` 到 `442a08176825` 只有三次自动榜单数据更新，没有脚本或协议变化。本轮更新观察基线，不吸收代码。
- `Narcooo/inkos` 从 v1.7.0 到 v1.7.1 主要发布了非正史分支推演、后台生产任务、任务重试/恢复、整书备份和写锁边界。当前项目已有候选规划隔离、任务族、持久回执、租约与正式资产事务；本轮登记为对照验收项，不再引入第二套状态系统。后续若实现“多路线并排比较”，只复用现有 task branch 与 pending design，不复制 InkOS 实现。

## 分发镜像附录

已发现 `short-drama-writer` 与 `story-writer` 的目录版本、制品内版本不一致。两项镜像均标记为 `quarantined`，后续只观察对应 GitHub 原仓库。其他镜像也只用于发现与指纹核对，不参与吸收决策。
