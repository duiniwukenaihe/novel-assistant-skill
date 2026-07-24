#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "short project state keeps one movable project identity and blocks concurrent workflow takeover" {
  BOOK="$BATS_TEST_TMPDIR/project-identity-book"
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-short-a" "$BOOK/追踪/workflow/tasks/wf-short-b"
  printf '%s\n' '{"workflow_id":"wf-short-a","workflow_type":"short_write","task_dir":"追踪/workflow/tasks/wf-short-a","status":"running"}' > "$BOOK/追踪/workflow/tasks/wf-short-a/task.json"
  printf '%s\n' '{"workflow_id":"wf-short-b","workflow_type":"short_write","task_dir":"追踪/workflow/tasks/wf-short-b","status":"running"}' > "$BOOK/追踪/workflow/tasks/wf-short-b/task.json"
  printf '%s\n' '## 第1节：开场' '## 第2节：反转' > "$BOOK/小节大纲.md"
  run node - "$REPO/scripts/lib/short-project-state.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const state=require(process.argv[2]);const root=process.argv[3];
const first=state.ensureShortProjectState(root,{workflowId:'wf-short-a',title:'果汁事件'});
if(!first.project_id || first.project_title!=='果汁事件' || first.active_write_workflow_id!=='wf-short-a') throw new Error(JSON.stringify(first));
let blocked=false;
try { state.ensureShortProjectState(root,{workflowId:'wf-short-b'}); } catch(error) { blocked=error.code==='SHORT_PROJECT_OWNERSHIP_CONFLICT'; }
if(!blocked) throw new Error('concurrent short workflow takeover was not blocked');
const one=state.advanceShortPlanRevision(root,{workflowId:'wf-short-a',outlinePath:'小节大纲.md'});
const same=state.advanceShortPlanRevision(root,{workflowId:'wf-short-a',outlinePath:'小节大纲.md'});
if(one.plan_revision!==1 || same.plan_revision!==1 || same.planned_sections!==2) throw new Error(JSON.stringify({one,same}));
fs.writeFileSync(path.join(root,'小节大纲.md'),'## 第1节：开场\n## 第2节：反转\n## 第3节：收束\n');
const changed=state.advanceShortPlanRevision(root,{workflowId:'wf-short-a',outlinePath:'小节大纲.md'});
if(changed.plan_revision!==2 || changed.planned_sections!==3 || changed.project_id!==first.project_id) throw new Error(JSON.stringify(changed));
NODE
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}

@test "short brief freshness is bound to project identity and plan revision" {
  BOOK="$BATS_TEST_TMPDIR/brief-revision-book"
  mkdir -p "$BOOK/追踪/private-short-extension"
  printf '%s\n' '{"project_id":"short-project-a","plan_revision":2}' > "$BOOK/追踪/private-short-extension/project-state.json"
  printf '%s\n' '素材' > "$BOOK/素材卡.md"
  printf '%s\n' '设定' > "$BOOK/设定.md"
  printf '%s\n' '## 第1节：开场' > "$BOOK/小节大纲.md"
  printf '%s\n' '第1节写作提要。' > "$BOOK/写作Brief_第001节.md"
  run node - "$REPO/scripts/lib/short-brief-freshness.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const written=api.writeBriefFreshnessSnapshot({projectRoot:root,briefPath:'写作Brief_第001节.md',sectionIndex:1});
if(written.status!=='snapshot_written' || written.snapshot.project_id!=='short-project-a' || written.snapshot.plan_revision!==2) throw new Error(JSON.stringify(written));
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),'{"project_id":"short-project-a","plan_revision":3}\n');
const stale=api.checkBriefFreshness({projectRoot:root,briefPath:'写作Brief_第001节.md',sectionIndex:1});
if(stale.status!=='stale' || !stale.stale_dependencies.includes('project-state.plan_revision')) throw new Error(JSON.stringify(stale));
NODE
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}

@test "integration outbox emits idempotent project events for the external manager" {
  BOOK="$BATS_TEST_TMPDIR/outbox-book"
  mkdir -p "$BOOK"
  run node - "$REPO/scripts/lib/integration-outbox.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const outbox=require(process.argv[2]);const root=process.argv[3];
const event={event_type:'section_accepted',workflow_id:'wf-short',project_id:'project-a',project_title:'果汁事件',artifact_path:'正文/第001节.md',artifact_digest:'sha256:abc',summary:'第1节已采用',tags:['short_write']};
const first=outbox.appendIntegrationEvent(root,event);const second=outbox.appendIntegrationEvent(root,event);
if(first.status!=='appended' || second.status!=='duplicate_ignored' || first.event.event_id!==second.event.event_id) throw new Error(JSON.stringify({first,second}));
const rows=fs.readFileSync(path.join(root,'追踪/integration/outbox.jsonl'),'utf8').trim().split(/\n/).map(JSON.parse);
if(rows.length!==1 || rows[0].event_type!=='section_accepted' || rows[0].project_id!=='project-a' || !rows[0].evidence_hash) throw new Error(JSON.stringify(rows));
NODE
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}

@test "accepted short feedback emits one task-scoped outbox event" {
  BOOK="$BATS_TEST_TMPDIR/feedback-outbox-book"
  mkdir -p "$BOOK/追踪/private-short-extension"
  printf '%s\n' '{"project_id":"short-project-feedback","project_title":"果汁事件","plan_revision":3}' > "$BOOK/追踪/private-short-extension/project-state.json"
  printf '%s\n' '已按意见修订当前小节。' > "$BOOK/正文.md"
  run node - "$REPO/scripts/lib/short-feedback-outbox.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const {recordAcceptedShortFeedback}=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short-feedback',workflow_type:'private_short_startup',pending_feedback:{feedback_id:'feedback-001',text:'删掉哥哥救过公司的设定。'},short_feedback_impact:{impact_level:'expression_only'}};
const result={stage_id:'section_repair_loop',step_status:'completed',changed_files:['正文.md'],result_packet_path:'追踪/workflow/tasks/wf-short-feedback/result-packets/repair.result.json'};
const first=recordAcceptedShortFeedback(root,task,result);const second=recordAcceptedShortFeedback(root,task,result);
if(first.status!=='appended'||second.status!=='duplicate_ignored') throw new Error(JSON.stringify({first,second}));
const rows=fs.readFileSync(path.join(root,'追踪/integration/outbox.jsonl'),'utf8').trim().split(/\n/).map(JSON.parse);
if(rows.length!==1||rows[0].event_type!=='user_feedback_accepted'||rows[0].workflow_id!=='wf-short-feedback'||rows[0].project_id!=='short-project-feedback') throw new Error(JSON.stringify(rows));
if(!rows[0].tags.includes('feedback-001')||rows[0].artifact_path!=='正文.md') throw new Error(JSON.stringify(rows[0]));
NODE
  [ "$status" -eq 0 ]
}

@test "short section canonical artifact has one stable heading and structured memory facts" {
  run node - "$REPO/scripts/lib/short-section-commit-store.js" <<'NODE'
const assert = require('assert');
const store = require(process.argv[2]);
const text = store.buildCanonicalSectionText({ sectionIndex: 7, title: '父亲留下的字', text: '## 第7节 临时标题\n\n正文第一段。\n\n正文第二段。\n' });
assert.equal(text, '## 第007节 父亲留下的字\n\n正文第一段。\n\n正文第二段。\n');
assert.equal(store.canonicalSectionPath(7), '正文/第007节.md');
const facts = store.buildSectionFacts({
  sectionIndex: 7,
  canonicalPath: '正文/第007节.md',
  title: '父亲留下的字',
  projectTitle: '果汁事件',
  metadata: {
    section_summary: '林照确认父亲曾要求停用鲜榨字样。',
    present_characters: ['林照', '母亲'],
    revealed_information: ['母亲早已知道手写要求'],
    character_state: { 林照: ['不再接受家人代替她决定'] },
    relationship_state: { '林照-母亲': '从等待解释转为要求公开承担责任' },
    knowledge_state: { 母亲: '知道父亲要求停用鲜榨字样，但尚未说明隐瞒原因' },
    world_state: { '鲜榨产线': '尚未恢复，采购记录待公开' },
    decisions: ['公开采购记录并拒绝删除直播回放'],
    causal_links: [{ cause: '发现停用鲜榨字样的手写要求', effect: '转向追查母亲知情时间' }],
    protagonist: '林照',
    open_hook: '母亲为什么隐瞒三年仍未解释。',
  },
});
assert.ok(facts.length >= 11, JSON.stringify(facts));
for (const fact of facts) assert.equal(fact.evidence[0].path, '正文/第007节.md');
assert.ok(facts.some((fact) => fact.predicate === '第7节关系状态'), JSON.stringify(facts));
assert.ok(facts.some((fact) => fact.predicate === '第7节出场' && fact.subject === '母亲'), JSON.stringify(facts));
assert.ok(facts.some((fact) => fact.predicate === '第7节认知边界'), JSON.stringify(facts));
assert.ok(facts.some((fact) => fact.predicate === '第7节世界状态'), JSON.stringify(facts));
assert.ok(facts.some((fact) => fact.predicate === '第7节做出选择'), JSON.stringify(facts));
assert.ok(facts.some((fact) => fact.predicate.includes('因发现停用鲜榨字样')), JSON.stringify(facts));
const nested = store.buildSectionFacts({
  sectionIndex: 8,
  canonicalPath: '正文/第008节.md',
  title: '关系变化',
  metadata: { character_state: { 林照: { relation: { 母亲: '决裂' }, decision: '公开证据' } } },
});
assert.ok(nested.some((fact) => fact.object.includes('"母亲":"决裂"')), JSON.stringify(nested));
assert.ok(nested.every((fact) => !fact.predicate.includes('第本节')), JSON.stringify(nested));
NODE
  [ "$status" -eq 0 ]
}

@test "later short section context includes the exact outline block and pending feedback" {
  BOOK="$BATS_TEST_TMPDIR/later-context-book"
  mkdir -p "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow/tasks/wf-later"
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"project_id":"short-later-context","project_title":"果汁事件","plan_revision":1,"current_section_index":9,"accepted_sections":[{"section_index":1},{"section_index":2},{"section_index":3},{"section_index":4},{"section_index":5},{"section_index":6}],"narrative":{"planned_sections":9}}
JSON
  cat > "$BOOK/小节大纲.md" <<'MD'
## 第1节：错误入口
不要注入后续章节。
## 第2节：二
## 第3节：三
## 第4节：四
## 第5节：五
## 第6节：六
## 第7节：公开账本
- 结构功能：升级与关系决裂。
- 承接上节：上一节留下的采购异常迫使林照公开完整账本。
- 场景动作：林照在直播现场公开采购账本，并让母亲当面选择是否继续隐瞒。
- 角色选择：林照拒绝删掉直播回放，坚持让账本接受公开核验。
- 可见阻力：母亲以家族名誉和员工生计要求她立即停播。
- 本节兑现：账本证明企业长期采购成品原浆而非现场鲜榨。
- 关系变化：林照从等待母亲解释转为公开要求母亲承担责任。
- 代价升级：她失去家族支持并承担直播失实责任。
- 子事件：
  1. 林照把采购账本投到直播画面。
  2. 母亲在镜头前拒绝继续替公司圆谎。
- 情绪目标：犹疑到决绝。
- 压力变化：家庭争执升级为公众问责。
- 因果链：发现账本 -> 公开账本 -> 母亲表态。
- 节尾钩子：母亲承认三年前就知道生产线停用。
## 第8节：八
## 第9节：九
MD
  printf '%s\n' '设定摘要。' > "$BOOK/设定.md"
  printf '%s\n' '素材摘要。' > "$BOOK/素材卡.md"
  printf '%s\n' '## 第7节写作提要' '保留公开账本。' > "$BOOK/写作Brief_第007节.md"
  printf '%s\n' '候选正文。' > "$BOOK/草稿_第007节_候选.md"
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const {buildStageContextPacket}=require(process.argv[2]);const root=process.argv[3];
const out=buildStageContextPacket({projectRoot:root,task:{workflow_id:'wf-later',workflow_type:'short_write',current_stage:'feedback_apply_patch',scope:'第7节',task_dir:'追踪/workflow/tasks/wf-later',stage_execution:{stage_attempt_id:'sa-feedback-7'},pending_feedback:{feedback_id:'fb-7',section_index:7,text:'删除哥哥救过公司的设定，改为母亲主动隐瞒。'}},stage:'feedback_apply_patch'});
if(out.status!=='assembled'||out.section_index!==7) throw new Error(JSON.stringify(out));
const text=fs.readFileSync(path.join(root,out.packet_md),'utf8');
if(!text.includes('删除哥哥救过公司的设定，改为母亲主动隐瞒。')) throw new Error(text);
if(!text.includes('林照在直播现场公开采购账本')) throw new Error(text);
if(text.includes('错误入口')) throw new Error(text);
NODE
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}

@test "short stage context derives its fallback budget from required assets instead of a fixed 3600 tokens" {
  BOOK="$BATS_TEST_TMPDIR/adaptive-context-book"
  mkdir -p "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow/tasks/wf-adaptive"
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"project_id":"short-adaptive-context","project_title":"果汁事件","plan_revision":1,"current_section_index":2,"accepted_sections":[{"section_index":1}],"narrative":{"planned_sections":3}}
JSON
  cat > "$BOOK/小节大纲.md" <<'MD'
## 第1节：误切
## 第2节：收据
- 结构功能：冲突升级。
- 承接上节：空车间画面迫使主角核对原料采购。
- 场景动作：主角把采购收据推到会议桌中央要求逐项核验。
- 角色选择：主角拒绝签署把责任推给员工的说明。
- 可见阻力：管理层用停职和赔偿压力逼她沉默。
- 本节兑现：收据证明原料来自外部成品供应商。
- 关系变化：主角不再信任负责采购的亲属。
- 代价升级：她被撤销系统权限。
- 核心承诺兑现：主角第一次用公开证据反制家族施压。
- 决定性行动：她把收据交给独立审查方并拒绝撤回。
- 即时代价：她当场被撤销系统权限并承担调查责任。
- 子事件：
  1. 主角核对收据与直播日期。
  2. 管理层当场撤销她的权限。
- 情绪目标：怀疑到确认。
- 压力变化：网络质疑升级为内部封锁。
- 因果链：核对收据 -> 发现供应商 -> 权限被撤。
- 节尾钩子：供应商联系人正是母亲旧友。
## 第3节：公开
MD
  printf '%s\n' '## 本节任务' '完成一次真实行动。' '## 视角与称谓' '第一人称。' '## 禁止漂移' '不得新增亲属。' '## 验收标准' '行动产生结果。' > "$BOOK/写作Brief_第002节.md"
  printf '%s\n' '## 第002节' '' '我把收据推到桌面正中。' > "$BOOK/草稿_第002节_候选.md"
  cat > "$BOOK/追踪/workflow/tasks/wf-adaptive/gate.json" <<'JSON'
{"machine_gate_result":"blocking","blocking_findings":[{"code":"not-is-comparison","message":"改为动作证据。"}],"evidence":[{"check":"not-is-comparison","status":"blocking","blocking":true,"finding_count":1}]}
JSON
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const {buildStageContextPacket}=require(process.argv[2]);const root=process.argv[3];
const out=buildStageContextPacket({projectRoot:root,task:{workflow_id:'wf-adaptive',workflow_type:'short_write',current_stage:'section_repair_loop',scope:'第2节',task_dir:'追踪/workflow/tasks/wf-adaptive',machine:{last_result_packet:'追踪/workflow/tasks/wf-adaptive/gate.json'},stage_execution:{stage_attempt_id:'sa-adaptive'}},stage:'section_repair_loop'});
if(out.status!=='assembled') throw new Error(JSON.stringify(out));
if(out.token_budget===3600) throw new Error(JSON.stringify(out));
if(out.token_budget<out.estimated_tokens) throw new Error(JSON.stringify(out));
if(out.budget_source!=='adaptive_required_assets') throw new Error(JSON.stringify(out));
NODE
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}

@test "repair context accepts the current six-part Brief contract" {
  BOOK="$BATS_TEST_TMPDIR/current-brief-contract"
  mkdir -p "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow/tasks/wf-current-brief"
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"project_id":"short-current-brief","project_title":"短篇测试","plan_revision":1,"current_section_index":1,"accepted_sections":[],"narrative":{"planned_sections":1}}
JSON
  cat > "$BOOK/写作Brief_第001节.md" <<'MD'
# 写作 Brief：第 1 节《直播》

## 大纲覆盖映射
- B01：主角主动进入直播间。

## 因果动作链
[B01] -> [H01]

## 承接
- 开篇直接进入当前冲突。

## 目标与阻力
- 主角要公开事实，管理层试图阻止。

## 人物与视角锁
- 第一人称，只使用当前已确认人物。

## 禁写项
- 不提前揭晓下一节证据。

## 节尾钩子
- 直播画面出现无法解释的空车间。
MD
  printf '%s\n' '# 第001节' '我把镜头转向空车间。' > "$BOOK/草稿_第001节_候选.md"
  cat > "$BOOK/追踪/workflow/tasks/wf-current-brief/gate.json" <<'JSON'
{"machine_gate_result":"blocking","blocking_findings":[{"code":"sentence-pattern","message":"修订句式。"}],"evidence":[{"check":"sentence-pattern","status":"blocking","blocking":true,"finding_count":1}]}
JSON
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const {buildStageContextPacket}=require(process.argv[2]);const root=process.argv[3];
const out=buildStageContextPacket({projectRoot:root,task:{workflow_id:'wf-current-brief',workflow_type:'short_write',current_stage:'section_repair_loop',scope:'第1节',task_dir:'追踪/workflow/tasks/wf-current-brief',machine:{last_result_packet:'追踪/workflow/tasks/wf-current-brief/gate.json'},stage_execution:{stage_attempt_id:'sa-current-brief'}},stage:'section_repair_loop'});
if(out.status!=='assembled') throw new Error(JSON.stringify(out));
if(!(out.source_files||[]).some(item=>item.kind==='repair_constraints')) throw new Error(JSON.stringify(out));
const packet=require('fs').readFileSync(require('path').join(root,out.packet_md),'utf8');
if(packet.includes('B01：主角主动进入直播间')) throw new Error('repair context must omit duplicate outline mapping');
NODE
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}

@test "short stage context blocks when an explicit budget cannot hold required assets" {
  BOOK="$BATS_TEST_TMPDIR/blocked-context-book"
  mkdir -p "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow/tasks/wf-blocked"
  printf '%s\n' '{"project_id":"short-blocked-context","project_title":"果汁事件","plan_revision":1,"current_section_index":1,"accepted_sections":[],"narrative":{"planned_sections":1}}' > "$BOOK/追踪/private-short-extension/project-state.json"
  printf '%s\n' '## 本节任务' "$(printf '关键约束%.0s' {1..100})" > "$BOOK/写作Brief_第001节.md"
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const {buildStageContextPacket}=require(process.argv[2]);const root=process.argv[3];
const out=buildStageContextPacket({projectRoot:root,task:{workflow_id:'wf-blocked',workflow_type:'short_write',current_stage:'draft_first_section',scope:'第1节',task_dir:'追踪/workflow/tasks/wf-blocked',stage_execution:{stage_attempt_id:'sa-blocked'}},stage:'draft_first_section',options:{tokenBudget:10}});
if(out.status!=='blocked_required_context_budget') throw new Error(JSON.stringify(out));
if(!Array.isArray(out.required_context)||out.required_context.length<1) throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ]
}

@test "whole-story result packets do not inherit a stale section scope" {
  run node - "$REPO/scripts/lib/workflow-result-packet-identity.js" <<'NODE'
const {validateResultPacketUnitBinding}=require(process.argv[2]);
const task={workflow_type:'short_write',current_stage:'short_deslop',scope:'全篇',lifecycle:{scope:'第5节'},unit_lifecycle:{unit_type:'story',current_scope:'全篇'},stage_execution:{stage_id:'short_deslop'}};
const issue=validateResultPacketUnitBinding(task,{stage_id:'short_deslop',scope:'全篇'});
if(issue) throw new Error(JSON.stringify(issue));
NODE
  [ "$status" -eq 0 ]
}

@test "short title lock rejects gaps and duplicate titles before confirmation" {
  BOOK="$BATS_TEST_TMPDIR/book"
  mkdir -p "$BOOK"
  cat > "$BOOK/小节大纲.md" <<'MD'
## 第1节：同一个标题
## 第3节：同一个标题
MD
  run node "$REPO/scripts/short-section-title-lock.js" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.status!=="short_section_title_plan_invalid") process.exit(1); if(!x.findings.some(f=>f.code==="section_sequence_gap") || !x.findings.some(f=>f.code==="duplicate_section_title")) process.exit(2)' "$output"
}

@test "next section context reads the previous immutable section and keeps attempt history" {
  BOOK="$BATS_TEST_TMPDIR/context-book"
  mkdir -p "$BOOK/正文" "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow/tasks/wf-short"
  printf '%s\n' '错误的累计正文尾巴' > "$BOOK/正文.md"
  cat > "$BOOK/正文/第001节.md" <<'MD'
## 第001节 开场

上一节真正的结尾。
MD
  cat > "$BOOK/追踪/private-short-extension/section-001-anchor.json" <<'JSON'
{"workflow_id":"wf-short","section_index":1,"status":"accepted","canonical_path":"正文/第001节.md","section_commit_id":"chapter-short-001","section_summary":"主角公开质疑宣传。","revealed_information":["生产线已经出售"],"character_state":{"林照":"决定继续查证"},"open_hook":"哥哥拿出工资账本。","next_section_handoff":{"must_carry":"工资账本"},"quality_result":{"machine_gate":"pass"}}
JSON
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"project_id":"short-next-context","project_title":"果汁事件","plan_revision":1,"current_section_index":1,"accepted_sections":[{"section_index":1,"canonical_path":"正文/第001节.md","anchor_path":"追踪/private-short-extension/section-001-anchor.json"}],"narrative":{"planned_sections":3}}
JSON
  cat > "$BOOK/小节大纲.md" <<'MD'
## 第1节：开场
## 第2节：账本
- 结构功能：证据升级。
- 承接上节：哥哥拿出的工资账本成为下一轮核验入口。
- 场景动作：主角逐页比对工资账本与生产线停工日期。
- 角色选择：主角拒绝只听哥哥解释，决定把账本交给员工代表复核。
- 可见阻力：哥哥要求她先删除直播回放再看账本。
- 本节兑现：账本证明停工后仍有人领取虚构生产补贴。
- 关系变化：主角与哥哥从合作查证转为公开对立。
- 代价升级：她失去家族提供的法律支持。
- 核心承诺兑现：主角把家族内部账本交给员工代表共同核验。
- 决定性行动：她拒绝删除回放并公开提交账本副本。
- 即时代价：她失去家族法律支持并被要求独自应诉。
- 子事件：
  1. 主角核对工资账本与停工日期。
  2. 员工代表确认补贴名单存在冒名记录。
- 情绪目标：期待到警觉。
- 压力变化：产品质疑升级为内部账目造假。
- 因果链：接过账本 -> 比对日期 -> 发现冒名补贴。
- 节尾钩子：补贴审批人是母亲。
## 第3节：反转
MD
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const { buildStageContextPacket } = require(process.argv[2]);
const root = process.argv[3];
const out = buildStageContextPacket({ projectRoot: root, task: {
  workflow_id: 'wf-short', workflow_type: 'short_write', current_stage: 'next_section_brief', scope: '第2节',
  task_dir: '追踪/workflow/tasks/wf-short', stage_execution: { stage_attempt_id: 'sa-next-2' },
}, stage: 'next_section_brief' });
if (out.status !== 'assembled') throw new Error(JSON.stringify(out));
if (!out.packet_md.includes('/section-002/sa-next-2/')) throw new Error(out.packet_md);
const markdown = fs.readFileSync(path.join(root, out.packet_md), 'utf8');
if (!markdown.includes('上一节真正的结尾')) throw new Error(markdown);
if (!markdown.includes('生产线已经出售') || !markdown.includes('工资账本')) throw new Error(markdown);
if (markdown.includes('错误的累计正文尾巴')) throw new Error(markdown);
NODE
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}

@test "public and private short workflows declare the same production kernel" {
  run node - "$REPO/scripts/lib/workflow-template-registry.js" <<'NODE'
const registry = require(process.argv[2]);
const publicTemplates = registry.buildEffectiveTemplates('', true).templates;
const privateTemplates = registry.buildEffectiveTemplates('', false).templates;
if (publicTemplates.short_write.production_kernel !== 'short-section-production-v2') throw new Error(JSON.stringify(publicTemplates.short_write));
if (privateTemplates.short_write.production_kernel !== 'short-section-production-v2') throw new Error(JSON.stringify(privateTemplates.short_write));
for (const stage of ['section_machine_gate', 'section_accept_anchor', 'full_story_assembly']) {
  if (!privateTemplates.short_write.stages.some((item) => item.stage_id === stage)) throw new Error(`private workflow missing ${stage}`);
}
NODE
  [ "$status" -eq 0 ]
}

@test "bundle manifest carries section migration and deterministic assembly" {
  grep -q 'short-section-artifact-migrate.js' "$REPO/config/novel-assistant-bundle-files.json"
  grep -q 'short-story-assembly-finalize.js' "$REPO/config/novel-assistant-bundle-files.json"
}

@test "structured workflow blocks stay visible without becoming shell errors" {
  run node - "$REPO/scripts/lib/workflow-apply-result.js" <<'NODE'
const { classifyWorkflowApply } = require(process.argv[2]);
const blocked = classifyWorkflowApply({ status: 0, stdout: '{"status":"blocked_stale_visible_choice"}' });
if (blocked.applied || blocked.exitCode !== 0 || blocked.workflowStatus !== 'blocked_stale_visible_choice') throw new Error(JSON.stringify(blocked));
const started = classifyWorkflowApply({ status: 0, stdout: JSON.stringify({ status:'stage_started', stage_execution:{ status:'running', stage_id:'next_stage', execution_command:'node next.js', context_read_command:'node context.js', stage_context_packet:{ huge:'x'.repeat(20000) }, memory_context:{ huge:'y'.repeat(20000) } }, visible_response:{ selection_contract:'resume_running_stage' }, interaction_contract:'continue_confirmed_internal_stage' }) });
if (!started.applied || started.exitCode !== 0 || started.workflowStatus !== 'stage_started') throw new Error(JSON.stringify(started));
if ((started.presentation.stage_execution||{}).stage_id !== 'next_stage') throw new Error(JSON.stringify(started.presentation));
if ((started.presentation.stage_execution||{}).execution_command !== 'node next.js') throw new Error(JSON.stringify(started.presentation));
if ('stage_context_packet' in started.presentation.stage_execution || 'memory_context' in started.presentation.stage_execution) throw new Error(JSON.stringify(started.presentation));
if ((started.presentation.visible_response||{}).selection_contract !== 'resume_running_stage') throw new Error(JSON.stringify(started.presentation));
const failed = classifyWorkflowApply({ status: 2, stdout: '', stderr: 'process failed' });
if (failed.exitCode !== 2) throw new Error(JSON.stringify(failed));
NODE
  [ "$status" -eq 0 ]
}

@test "recoverable stage validation resumes internally and duplicate outline headings aggregate once" {
  run node - "$REPO/scripts/lib/workflow-apply-result.js" "$REPO/scripts/lib/short-plan-contract.js" <<'NODE'
const { stageRecoveryPresentation } = require(process.argv[2]);
const { analyzeShortOutlineNarrativeQuality } = require(process.argv[3]);
const recovery = stageRecoveryPresentation({ stage_execution:{ status:'running', stage_id:'outline', execution_command:'node finalize.js' } }, { instruction:'修复暂存大纲后重试。' });
if ((recovery.visible_response||{}).selection_contract !== 'resume_running_stage') throw new Error(JSON.stringify(recovery));
if (recovery.interaction_contract !== 'continue_confirmed_internal_stage') throw new Error(JSON.stringify(recovery));
if (recovery.completion_required_before_reply !== true || (recovery.visible_response||{}).completion_required_before_reply !== true) throw new Error(JSON.stringify(recovery));
if (!((recovery.stage_execution||{}).execution_sequence||[]).includes('execute_completion_command')) throw new Error(JSON.stringify(recovery));
const outline = '# 第 1 节\n\n场景行动：第一次。\n\n# 第 1 节\n\n场景行动：修订版。\n';
const checked = analyzeShortOutlineNarrativeQuality(outline, 1);
const duplicates = checked.findings.filter((item) => item.code === 'duplicate_section_outline' && item.section === 1);
if (duplicates.length !== 1 || duplicates[0].occurrences !== 2) throw new Error(JSON.stringify(checked));
if (checked.section_roles.filter((item) => item.section === 1).length !== 1) throw new Error(JSON.stringify(checked.section_roles));
NODE
  [ "$status" -eq 0 ]
}

@test "strict short planning writes a staged material card through a canonical transaction" {
  BOOK="$BATS_TEST_TMPDIR/strict-planning-book"
  mkdir -p "$BOOK/追踪/story-system" "$BOOK/追踪/workflow"
  printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$BOOK/追踪/story-system/write-policy.json"
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$BOOK" --scope "新短篇" --user-goal "创建短篇" --no-private-registry --json > "$BATS_TEST_TMPDIR/strict-create.json"
  WORKFLOW_ID="$(node -e 'console.log(require(process.argv[1]).task.workflow_id)' "$BATS_TEST_TMPDIR/strict-create.json")"
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const taskFile=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const staged=`${task.task_dir}/artifacts/planning/material_card/sa-material/素材卡.md`;
fs.mkdirSync(path.dirname(path.join(root,staged)),{recursive:true});
fs.writeFileSync(path.join(root,staged),'# 素材卡\n\n现实入口：消费者质疑果汁宣传。\n核心冲突：企业必须公开生产线证据。\n');
task.current_stage='material_card';task.current_step='material_card';task.status='running';
const stages=Object.keys((task.unit_lifecycle||{}).stage_roles||{});const current=stages.indexOf('material_card');
if(current<0) throw new Error(JSON.stringify(task));
task.machine.completed_stages=stages.slice(0,current);
task.machine.remaining_stages=stages.slice(current+1);
task.stage_execution={status:'running',stage_attempt_id:'sa-material',stage_id:'material_card',step_id:'material_card',owner_module:task.workflow_owner||'story-short-write',expected_result_packet:`${task.task_dir}/result-packets/material_card.result.json`,planning_target:staged,planning_canonical_target:'素材卡.md',write_set:[staged]};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE

  run node "$REPO/scripts/short-planning-stage-finalize.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.status!=="applied") { console.error(JSON.stringify(x)); process.exit(1); }' "$output"
  [ -f "$BOOK/素材卡.md" ]
  grep -q '消费者质疑果汁宣传' "$BOOK/素材卡.md"
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
if(task.current_stage!=='short_setting') throw new Error(JSON.stringify(task));
const state=JSON.parse(fs.readFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),'utf8'));
if(!state.project_id || state.active_write_workflow_id!==id || state.schema_version!=='2.0.0') throw new Error(JSON.stringify(state));
const events=fs.readFileSync(path.join(root,'追踪/integration/outbox.jsonl'),'utf8').trim().split(/\n/).map(JSON.parse);
if(events.length!==1 || events[0].event_type!=='material_accepted' || events[0].project_id!==state.project_id) throw new Error(JSON.stringify(events));
const commits=fs.readdirSync(path.join(root,'追踪/story-system/commits')).map((name)=>JSON.parse(fs.readFileSync(path.join(root,'追踪/story-system/commits',name),'utf8')));
if(!commits.some((commit)=>(commit.artifacts||[]).some((artifact)=>artifact.target==='素材卡.md'))) throw new Error(JSON.stringify(commits));
NODE
}

@test "accepted whole-story feedback patches multiple planning assets through one transaction" {
  BOOK="$BATS_TEST_TMPDIR/feedback-planning-book"
  mkdir -p "$BOOK/追踪/story-system" "$BOOK/追踪/workflow" "$BOOK/追踪/private-short-extension"
  printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$BOOK/追踪/story-system/write-policy.json"
  cat > "$BOOK/设定.md" <<'EOF'
# 设定

作品名：果汁事件
计划 2 节
叙事方式：第一人称
主节奏：揭露后承担现实代价
EOF
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲

核心路线：直播揭穿假鲜榨，再用真实生产恢复消费者选择权。

## 第1节：镜头里没有水果
- 结构功能：黄金开篇，兑现标题画面
- 情绪目标：疑惑到警觉
- 因果链：直播扫到空线，林照拒绝关播并追查
- 场景动作：林照移动镜头，当面拒绝哥哥关播
- 主角选择：她选择保留直播回放
- 子事件：
  1. 林照直播时看见压榨线旁没有水果
  2. 哥哥逼她关播，她拒绝并公开追问
- 节尾钩子：哥哥承认仓库只有浓缩原料

## 第2节：让水果重新进厂
- 结构功能：结尾收束责任与产品承诺
- 情绪目标：压力升高到责任落地
- 因果链：承接哥哥承认浓缩原料，林照推动召回和真实鲜榨复产
- 承接上节：哥哥承认仓库只有浓缩原料
- 场景动作：林照在董事会提交召回和停职方案
- 主角选择：她选择召回旧货并公开新线
- 子事件：
  1. 林照提交召回退款方案并暂停哥哥职务
  2. 她启动真实鲜果入厂直播，承担渠道损失
- 现实后果：旧货召回退款，哥哥停职，渠道和工资承压
- 关系收束：林照与家人保持裂痕，不用亲情替责任结账
- 结尾回扣：镜头里终于有真实水果，消费者可以自行核验
- 节尾钩子：真实鲜榨线接受长期公开监督
EOF
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$BOOK" --scope "全篇" --user-goal "整篇回炉" --no-private-registry --json > "$BATS_TEST_TMPDIR/feedback-create.json"
  WORKFLOW_ID="$(node -e 'console.log(require(process.argv[1]).task.workflow_id)' "$BATS_TEST_TMPDIR/feedback-create.json")"
  node - "$BOOK" "$WORKFLOW_ID" "$REPO/scripts/lib/short-project-state.js" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id,stateModule]=process.argv.slice(2);const state=require(stateModule);
state.ensureShortProjectState(root,{workflowId:id,title:'果汁事件'});state.advanceShortPlanRevision(root,{workflowId:id,outlinePath:'小节大纲.md'});
const taskFile=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const attempt='sa-feedback-patch';const base=`${task.task_dir}/artifacts/planning/feedback_apply_patch/${attempt}`;
const targets=['设定.md','小节大纲.md'].map(canonical=>({canonical,staged:`${base}/${canonical}`}));
for(const target of targets){fs.mkdirSync(path.dirname(path.join(root,target.staged)),{recursive:true});fs.copyFileSync(path.join(root,target.canonical),path.join(root,target.staged));}
const feedbackId='feedback-batch-plan';const planId='accepted-plan.feedback-batch-plan';
task.current_stage='feedback_apply_patch';task.current_step='feedback_apply_patch';task.status='running';task.scope='全篇';
task.pending_feedback={feedback_id:feedbackId,text:'恢复真实鲜榨并重做结尾。',scope_snapshot:'全篇',status:'pending'};
task.short_feedback_impact={status:'ok',feedback_id:feedbackId,impact_level:'planning',affected_sections:[1,2],downstream_impact:{invalidate_briefs:['写作Brief_第001节.md','写作Brief_第002节.md'],recheck_prose:['正文/第001节.md','正文/第002节.md']}};
task.accepted_plan={plan_id:planId,status:'accepted_pending_projection',feedback_id:feedbackId,impact_level:'planning',summary:'恢复真实鲜榨并重做结尾。',requirements:[{requirement_id:'req-1',text:'旧货召回退款，新线恢复真实鲜果并公开生产。',impact_level:'planning'}],affected_sections:[1,2],projection_plan:{planning_assets:['设定.md','小节大纲.md'],invalidate_briefs:['写作Brief_第001节.md','写作Brief_第002节.md'],recheck_prose:['正文/第001节.md','正文/第002节.md']}};
task.accepted_plan_path=`${task.task_dir}/artifacts/accepted-plan.json`;fs.mkdirSync(path.dirname(path.join(root,task.accepted_plan_path)),{recursive:true});fs.writeFileSync(path.join(root,task.accepted_plan_path),JSON.stringify(task.accepted_plan,null,2)+'\n');
const token='feedback-confirmation';const expires=new Date(Date.now()+3600000).toISOString();const hash='feedback-choice';
task.pending_action={id:'pa-feedback',status:'resolved',visible_choice_hash:hash};task.last_selection={confirmation_token:token,selected_number:1,action_id:'continue_next_stage',visible_choice_hash:hash,requires_user_confirm:true};
task.stage_execution={status:'running',stage_attempt_id:attempt,stage_id:'feedback_apply_patch',step_id:'feedback_apply_patch',action_id:'continue_next_stage',selected_number:1,owner_module:'story-short-write',expected_result_packet:`${task.task_dir}/result-packets/feedback_apply_patch.result.json`,planning_targets:targets,write_set:targets.map(item=>item.staged),confirmation_token:token,confirmation_context:{status:'confirmed',workflow_id:id,workflow_type:'short_write',stage_id:'feedback_apply_patch',step_id:'feedback_apply_patch',selection_id:'pa-feedback',selected_number:1,selected_action_id:'continue_next_stage',expires_at:expires,visible_choice_hash:hash,confirmation_token:token}};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE

  run node "$REPO/scripts/short-planning-stage-finalize.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.status!=="applied"||x.planning_assets.length!==2||x.next_stage!=="section_plan_lock") { console.error(JSON.stringify(x)); process.exit(1); }' "$output"
  task_file="$BOOK/追踪/workflow/tasks/$WORKFLOW_ID/task.json"
  [ "$(jq -r '.feedback_revision_queue.affected_sections|join(",")' "$task_file")" = "1,2" ]
  [ "$(jq -r '.accepted_plan.projection_status' "$task_file")" = "completed" ]
  grep -q '旧货召回退款' "$BOOK/追踪/memory/planning-constraints.jsonl"
  node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const commits=fs.readdirSync(path.join(root,'追踪/story-system/commits')).map(name=>JSON.parse(fs.readFileSync(path.join(root,'追踪/story-system/commits',name),'utf8')));
const commit=commits.find(item=>(item.artifacts||[]).filter(artifact=>['设定.md','小节大纲.md'].includes(artifact.target)).length===2);
if(!commit) throw new Error(JSON.stringify(commits));
NODE
}

@test "private short project seed uses the same staged planning transaction" {
  if [ ! -f "$REPO/src/private-internal-skills/private-short-extension/SKILL.md" ]; then
    skip "public release intentionally excludes the private short enhancement"
  fi
  BOOK="$BATS_TEST_TMPDIR/private-planning-book"
  mkdir -p "$BOOK/追踪/story-system" "$BOOK/追踪/workflow"
  printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$BOOK/追踪/story-system/write-policy.json"
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$BOOK" --scope "新短篇" --user-goal "创建私有短篇" --json > "$BATS_TEST_TMPDIR/private-create.json"
  WORKFLOW_ID="$(node -e 'console.log(require(process.argv[1]).task.workflow_id)' "$BATS_TEST_TMPDIR/private-create.json")"
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const taskFile=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(task.workflow_profile!=='private') throw new Error(JSON.stringify(task));
const stages=task.machine.remaining_stages.slice();const current=stages.indexOf('project_seed');
if(current<0) throw new Error(JSON.stringify(stages));
const staged=`${task.task_dir}/artifacts/planning/project_seed/sa-seed/素材卡.md`;
fs.mkdirSync(path.dirname(path.join(root,staged)),{recursive:true});fs.writeFileSync(path.join(root,staged),'# 素材卡\n\n热点冲突：消费者追问果汁生产证据。\n');
task.current_stage='project_seed';task.current_step='project_seed';task.status='running';task.machine.completed_stages=stages.slice(0,current);task.machine.remaining_stages=stages.slice(current+1);
const token='test-confirmation-token';const expires=new Date(Date.now()+3600000).toISOString();const choiceHash='test-choice-hash';
task.pending_action={id:'pa-project_seed',status:'resolved',visible_choice_hash:choiceHash};
task.last_selection={confirmation_token:token,selected_number:1,action_id:'continue_next_stage',visible_choice_hash:choiceHash,requires_user_confirm:true};
const confirmation={status:'confirmed',workflow_id:id,workflow_type:'short_write',stage_id:'project_seed',step_id:'project_seed',selection_id:'pa-project_seed',selected_number:1,selected_action_id:'continue_next_stage',expires_at:expires,visible_choice_hash:choiceHash,confirmation_token:token};
task.stage_execution={status:'running',stage_attempt_id:'sa-seed',stage_id:'project_seed',step_id:'project_seed',action_id:'continue_next_stage',selected_number:1,owner_module:'private-short-extension',expected_result_packet:`${task.task_dir}/result-packets/project_seed.result.json`,planning_target:staged,planning_canonical_target:'素材卡.md',write_set:[staged],confirmation_token:token,confirmation_context:confirmation};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
  run node "$REPO/scripts/short-planning-stage-finalize.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.status!=="applied") { console.error(JSON.stringify(x)); process.exit(1); }' "$output"
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));if(task.current_stage!=='short_setting') throw new Error(JSON.stringify(task));if(!fs.readFileSync(path.join(root,'素材卡.md'),'utf8').includes('果汁生产证据')) throw new Error('material card missing');const state=JSON.parse(fs.readFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),'utf8'));if(!state.project_id||state.active_write_workflow_id!==id) throw new Error(JSON.stringify(state));
NODE
}
