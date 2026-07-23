#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/short-section-brief-finalize.js"
}

@test "short brief quality budget scales with planned prose instead of accepting an analysis dump" {
  run node - "$SCRIPT" <<'NODE'
const { analyzeBriefQuality } = require(process.argv[2]);
const concise = `# 第7节写作提要\n> 目标 1500-1700 个中文字符\n## 视角与人物\n第一人称。\n## 因果\n1. 承接证据。\n2. 主角作出选择。\n3. 对手施压。\n4. 留下节尾钩子。\n## 禁止漂移\n不越权。\n## 验收\n钩子成立。`;
const bloated = `${concise}\n${Array.from({ length: 18 }, (_, i) => `${i + 5}. 重复规划同一事实与验收项。`).join('\n')}\n${'重复信息。'.repeat(900)}`;
const good = analyzeBriefQuality(concise);
const bad = analyzeBriefQuality(bloated);
if (good.status !== 'pass') throw new Error(JSON.stringify(good));
if (bad.status !== 'blocking' || !bad.findings.includes('brief_repeats_or_exceeds_dynamic_budget')) throw new Error(JSON.stringify(bad));
NODE
  [ "$status" -eq 0 ]
}

@test "short brief counts only causal beats instead of every numbered checklist item" {
  run node - "$SCRIPT" <<'NODE'
const { analyzeBriefQuality, countCausalBeats } = require(process.argv[2]);
const brief = `# 第7节写作提要
> 目标 1500-1700 个中文字符
## 因果动作链
主角追问；母亲改口；主角核对证据；对手发预告；主角准备反制。
## 禁写项
1. 不引入新人。
2. 不提前开播。
3. 不让对手认错。
## 验收
1. 视角稳定。
2. 节尾有钩子。`;
if (countCausalBeats(brief) !== 5) throw new Error(JSON.stringify(analyzeBriefQuality(brief)));
if (analyzeBriefQuality(brief).status !== 'pass') throw new Error(JSON.stringify(analyzeBriefQuality(brief)));
NODE
  [ "$status" -eq 0 ]
}

@test "expected brief overload is a normal revision status instead of a shell error" {
  BOOK="$BATS_TEST_TMPDIR/book"
  WF="wf-brief-recovery"
  mkdir -p "$BOOK/追踪/workflow/tasks/$WF" "$BOOK/追踪/private-short-extension"
  cat > "$BOOK/追踪/workflow/tasks/$WF/task.json" <<JSON
{"workflow_id":"$WF","workflow_type":"short_write","task_dir":"追踪/workflow/tasks/$WF","state_version":1,"current_stage":"next_section_brief","scope":"第7节","stage_execution":{"status":"running","stage_id":"next_section_brief","stage_attempt_id":"sa-brief-001","expected_result_packet":"追踪/workflow/tasks/$WF/result-packets/next_section_brief.result.json"}}
JSON
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"project_id":"brief-overload-test","plan_revision":1,"narrative":{"planned_sections":8},"current_section_index":7,"accepted_sections":[{"section_index":6}]}
JSON
  cat > "$BOOK/追踪/private-short-extension/section-title-lock.json" <<'JSON'
{"workflow_id":"wf-brief-recovery","project_id":"brief-overload-test","plan_revision":1,"sections":[{"section_index":7,"title":"第七节","confirmed":true}]}
JSON
  printf '# 素材卡\n测试素材。\n' > "$BOOK/素材卡.md"
  printf '# 设定\n第一人称。\n主节奏：调查反击。\n共8节。\n' > "$BOOK/设定.md"
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第7节：对抗
- 结构功能：中段升级。
- 承接上节：上一节留下的伪造合同迫使主角当面对质。
- 场景动作：主角把合同摊到桌上。
- 子事件：
  1. 对手抢夺合同。
  2. 主角保留备份。
- 情绪目标：怀疑到决绝。
- 压力变化：私下怀疑升级为失去工作权限的公开对抗。
- 因果链：发现异常 -> 当面对质 -> 保留备份。
- 角色选择：主角拒绝删除备份。
- 可见阻力：对手威胁停掉她的工作。
- 本节兑现：签名伪造得到证实。
- 关系变化：双方从暗中怀疑转为公开对抗。
- 代价升级：主角失去工作权限。
- 核心承诺兑现：主角当面拒绝继续包庇对手。
- 决定性行动：主角将原始邮件交给独立审查。
- 即时代价：主角失去工作权限。
- 节尾钩子：邮件抄送栏出现母亲的名字。
EOF
  {
    printf '# 第7节写作提要\n> 目标 1500-1700 个中文字符\n## 视角与人物\n第一人称，人物称谓固定，主角只能根据眼前证据判断。\n## 大纲覆盖映射\n- S00：中段升级。\n- B01：对手抢夺合同。\n- B02：主角保留备份。\n- C01：主角拒绝删除备份。\n- H01：邮件抄送栏出现母亲的名字。\n- Q01：上一节留下的伪造合同迫使主角当面对质。\n- V01：私下怀疑升级为失去工作权限的公开对抗。\n- A01：主角把合同摊到桌上。\n- O01：对手威胁停掉她的工作。\n- P01：签名伪造得到证实。\n- R01：双方从暗中怀疑转为公开对抗。\n- K01：主角失去工作权限。\n- X01：主角当面拒绝继续包庇对手。\n- D01：主角将原始邮件交给独立审查。\n## 因果动作链\n[Q01] [V01] [A01] [B01] [O01] [B02] [P01] [C01] [R01] [K01] [X01] [D01] [H01]\n'
    for i in $(seq 1 12); do printf '%s. 事件推进，主角根据上一项结果作出新的选择并承担代价。\n' "$i"; done
    printf '## 禁止漂移\n不越权，不引入新人物，不提前兑现后文反转。\n## 节尾钩子\n新证据出现，但真相尚未揭开。\n## 验收\n人物选择、因果变化和节尾钩子成立。\n'
  } > "$BOOK/写作Brief_第007节.md"

  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "$WF" --apply --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"brief_revision_required"'* ]]

  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "$WF" --apply --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"brief_revision_exhausted"'* ]]
  [[ "$output" == *'"requires_user_input":true'* ]]
}

@test "accepted brief projects portable next-section state for cross-host recovery" {
  BOOK="$BATS_TEST_TMPDIR/project-state"
  mkdir -p "$BOOK/追踪/private-short-extension"
  printf '%s\n' '{"working_title":"测试短篇","accepted_sections":[{"section_index":6}]}' > "$BOOK/追踪/private-short-extension/project-state.json"
  run node - "$SCRIPT" "$BOOK" <<'NODE'
const fs = require('fs');
const { writeBriefReadyProjectState } = require(process.argv[2]);
const out = writeBriefReadyProjectState(process.argv[3], 7, '追踪/workflow/tasks/wf/result-packets/next_section_brief.result.json');
const state = JSON.parse(fs.readFileSync(`${process.argv[3]}/追踪/private-short-extension/project-state.json`, 'utf8'));
if (out.status !== 'project_state_updated') throw new Error(JSON.stringify(out));
if (state.status !== 'section_007_brief_ready' || state.current_stage !== 'section_draft_ready' || state.current_section_index !== 7) throw new Error(JSON.stringify(state));
if (!Array.isArray(state.accepted_sections) || state.accepted_sections.length !== 1) throw new Error(JSON.stringify(state));
NODE
  [ "$status" -eq 0 ]
}
