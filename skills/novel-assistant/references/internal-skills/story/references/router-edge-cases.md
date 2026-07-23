# story router 边界路由契约

<!-- edge-reference-contract
{
  "schema_version": "1.0.0",
  "reference": "story/references/router-edge-cases.md",
  "routes": [
    {"intent": "短回复、裸更新、单字母阶段续跑", "contract_anchor": "短回复、裸更新与阶段续跑", "trigger_samples": ["继续", "更新", "e"]},
    {"intent": "短篇去 AI 味", "contract_anchor": "长篇稳定性与短篇去 AI 味", "trigger_samples": ["短篇去 AI 味"]},
    {"intent": "常规长篇续写/稳定性", "contract_anchor": "长篇稳定性与短篇去 AI 味", "trigger_samples": ["继续写下一章", "日更"]},
    {"intent": "范围审阅（如审阅 1-200）", "contract_anchor": "中文自然语言意图归一化：范围诊断、自由文本纠偏与回炉", "trigger_samples": ["审阅 1-200 章"]},
    {"intent": "低置信度纠偏、自由文本修正与回炉", "contract_anchor": "中文自然语言意图归一化：范围诊断、自由文本纠偏与回炉", "trigger_samples": ["不是这个意思，重列方案", "回炉第 3 章"]}
  ]
}
edge-reference-contract -->

仅在顶层 router 命中短回复、裸更新、单字母阶段续跑、短篇去 AI 味、长篇稳定性、范围诊断、自由文本纠偏或可见输出污染时读取本文件。普通意图匹配不得预读。

## 可见回复与污染恢复

任何进入 `/novel-assistant` 的消息必须得到中文可见回复，不得输出 `No response requested`、`No response needed`、`No reply requested` 或变体。长报告、候选项和受污染输入在输出前按 `output-safety-contract.md` 检查；命中污染时停止、定位最后可信事实、丢弃污染段、分块重写，连续失败则保存 `paused_after_output_pollution` 断点并给短版结论。不得把污染段、内部工具输出或长报告塞进选项。

## 短回复、裸更新与阶段续跑

- 短回复先绑定最新有效 `pending_action`，它必须匹配当前 `workflow_id`、`book_root`、`expires_at`、`visible_choice_hash` 与 `expected_reply_set`。优先级为破坏性确认 > 目标书 > skill/协作环境更新 > Phase/编号 > 普通继续；过期或不匹配就清理并重列候选。
- `确认/是/好/yes/y/ok` 接受最近确认；`不/否/no/n/later` 采用安全默认；`继续/下一步` 继续最近未完成项；暂停保存断点；取消不写入。没有有效 pending_action 才回退阶段表或任务列表。
- `裸更新歧义`：只有存在 `pending_action.type=phase_choice` 且最近选项明确是更新大纲/细纲或 Phase F 更新时，才把“更新”解释为阶段续跑；否则默认进入检查/更新本地 skill 或写作协作环境。两个确认同时存在时先收束协作环境。
- 单字母阶段续跑：有可见阶段表或编号候选时，`a/b/c/d/e`、`1/2/3`、继续或下一步绑定最新候选边界；完成项转向同一列表下一个未完成项。无可读边界时重列选项，不猜测；裸数字不得越过“只写第 6 节停下”等范围。

## 长篇稳定性与短篇去 AI 味

长篇、连载、下一章、日更、回炉和重写默认使用 `story-long-write`：先确认章纲、约束、状态输入，再依次执行 `Chapter Contract -> 正文写作 -> Plot Drift Gate -> State Delta Ledger -> Chapter Handoff Pack`；多章结束运行 Longform Daily Stability Audit，失败进入 Stability Repair Loop，50+ 章或章节移动后维护章节索引。

短篇去 AI 味先判断短篇项目、`正文.md` / `小节大纲.md` 与短篇语境。本地 private owner 存在时走 `private-short-extension` 加 `short-deslop.md`；公开 fallback 为 `story-short-write` Phase 4。不要先路由到长篇通用 story-deslop：只有未知来源片段且没有短篇证据时才走通用 `story-deslop`；后续识别为短篇必须切回短篇模式。

## 中文自然语言意图归一化：范围诊断、自由文本纠偏与回炉

范围诊断（阅读/检查动作 + 明确章节/卷/全书范围 + 问题维度）路由 `story-review`，先锁定范围与批次计划，输出修复方案和受影响产物清单；只有明确要求落盘改正文才进入写作/回炉。执行改稿、重写、扩容、插章、后移或合并章节路由 `story-long-write`，若同一请求要求先诊断则先审阅。

纯文字“改自然、改人味、润色、去掉破折号、去解释腔”且没有范围诊断时走 `story-deslop`；带 1-200 章、钩子、情节控制或主线偏离等结构词时仍先审阅。个人风格学习只更新风格档案和规则，不直接改正文；同时要求改第 X 章时先学习偏好，再走受控修订。

阶段上下文或用户评价当前大纲、细纲、正文产物时，先接收并落盘阶段反馈；只有明确说执行重写正文、批量改文件、重排章节或按影响分析开改，才做 Revision Impact Analysis。RIA 必须明确章节、人物、伏笔、设定与主线承诺影响，修改后运行稳定性复检，未通过复检不得宣布完成。
