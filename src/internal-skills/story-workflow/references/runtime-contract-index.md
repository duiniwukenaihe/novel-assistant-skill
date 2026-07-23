# 运行时契约索引

此文件只负责定位，不复制协议正文。

| 运行阶段 | 权威协议 |
|---|---|
| 首屏、任务恢复、数字选择、状态机 | `task-inbox-protocol.md` |
| runner、agent、授权、成本、退化恢复 | `runner-execution-protocol.md` |
| 正文、大纲、设定、追踪资产事务写入 | `canonical-write-protocol.md` |
| result packet、验证、完成声明 | `completion-evidence-protocol.md` |
| 可见回复与污染隔离 | `output-safety-contract.md` |
| Token 成本来源与预算 | `token-cost-governance.md` |

运行时必须按当前阶段读取对应协议，不得在启动时加载全部 reference。

旧项目兼容锚点、菜单细节与阶段专用检索词位于 `phase-protocol-index.md`；仅在阶段确定后读取。
