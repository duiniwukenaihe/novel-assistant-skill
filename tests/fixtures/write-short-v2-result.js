#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++index] || '';
    else if (arg === '--json') args.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.projectRoot || !args.workflowId) throw new Error('usage: write-short-v2-result.js --project-root <book> --workflow-id <id> [--json]');
  return args;
}

function projectFile(root, relativePath) {
  const file = path.resolve(root, String(relativePath || ''));
  if (file === root || !file.startsWith(`${root}${path.sep}`)) throw new Error(`unsafe project path: ${relativePath}`);
  return file;
}

function readTask(root, workflowId) {
  const pointerFile = path.join(root, '追踪', 'workflow', 'current-task.json');
  const pointer = JSON.parse(fs.readFileSync(pointerFile, 'utf8'));
  const taskFile = projectFile(root, pointer.task_dir);
  const task = JSON.parse(fs.readFileSync(path.join(taskFile, 'task.json'), 'utf8'));
  if (String(task.workflow_id || '') !== workflowId) throw new Error(`focused workflow mismatch: expected ${workflowId}`);
  return task;
}

function stageOutputs(root, task) {
  const execution = task.stage_execution || {};
  const writeSet = Array.isArray(execution.write_set) ? execution.write_set : [];
  const planningTargets = new Set([
    String(execution.planning_target || ''),
    ...(Array.isArray(execution.planning_targets) ? execution.planning_targets.map(item => String((item || {}).staged || '')) : []),
  ].filter(Boolean));
  const outputs = [];
  for (const relativePath of writeSet) {
    const value = String(relativePath || '');
    if (!value || value.includes('*')) continue;
    if (!value.startsWith(`${task.task_dir}/`) && !planningTargets.has(value) && !/^草稿_第\d+节_候选\.md$/u.test(value)) continue;
    const file = projectFile(root, value);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (value.endsWith('.json')) fs.writeFileSync(file, `${JSON.stringify({ schemaVersion: '1.0.0', stage_id: execution.stage_id, status: 'fixture_output' })}\n`);
    else fs.writeFileSync(file, planningArtifact(execution.stage_id));
    outputs.push(value);
  }
  return outputs;
}

function planningArtifact(stageId) {
  if (stageId === 'material_card') return '# 素材卡\n\n- 标题承诺：直播鲜榨工厂的镜头里没有水果，主持人必须公开真实生产。\n- 核心冲突：家人要求林照继续替失实宣传背书，她选择核验采购与质检。\n- 终局兑现：恢复真实鲜果入厂、压榨、检测和公开追溯。\n';
  if (stageId === 'short_setting' || stageId === 'platform_genre_lock' || stageId === 'rhythm_pattern_selection') return '# 设定\n\n- 总小节数：2 节。\n- 主节奏：公开审判。\n- 辅节奏：亲情断亲。\n- 目标总字数：4000 字。\n- 核心冲突：家族要林照继续遮掩浓缩原料，她要让消费者看见真实生产。\n- 剧情升级：空仓库质疑升级为公开采购证据，最终升级为公开召回和复产。\n- 关键反转：哥哥隐瞒原料是为了支付工资，却不能因此继续欺骗消费者。\n- 结局兑现：真实鲜果重新进厂，压榨与检测公开可查。\n\n### 林照｜主角\n林照，22 岁，第一人称直播主持。她的目标是查清并公开生产真相；最怕家人失业，软肋是总想替哥哥遮掩，缺陷是误信亲情可以代替责任。能力边界：她只能使用公开直播、采购单和质检编号，不能伪造证据或替代监管。关键行动：她主动公开采购收据并最终选择召回。\n\n### 林建川｜主要压力角色\n林建川，37 岁，林照的哥哥和工厂负责人。他的目标是保住订单与员工工资，认为暂时隐瞒能救工厂；可用资源是经营权限和停播令，行动边界是不能伪造质检编号、不能伤害家人。\n\n## 人物关系与责任债\n林照欠哥哥曾经保住工资的情分，哥哥欠她被借用的公众信用；关系从保护转为公开对立。\n';
  if (stageId === 'section_outline') return '# 小节大纲\n\n- 总小节数：2 节\n- 目标总字数：4000 字\n- 发布形态：两节完结短篇\n- 核心路线：林照用可核验证据拆穿工厂谎言，承担公开纠错的代价后恢复真实生产。\n\n## 第1节：空仓库直播\n- 结构功能：开篇危机。\n- 开篇钩子：直播镜头扫过空仓库，观众追问水果在哪里。\n- 故事承诺：林照必须用采购与质检证据让消费者看见真实生产。\n- 场景动作：林照在直播间调取当天采购收据。\n- 子事件：\n  1. 林照发现收据原料是浓缩浆。\n  2. 林建川要求她立刻断播。\n- 情绪目标：怀疑转为决绝。\n- 压力变化：家人劝说转为停播施压。\n- 因果链：空仓库被看见 -> 收据被调取 -> 哥哥断播。\n- 角色选择：林照拒绝关闭直播并公开收据编号。\n- 可见阻力：林建川以员工工资逼她沉默。\n- 本节兑现：收据证明工厂没有当天鲜果原料。\n- 关系变化：兄妹从保护关系转为公开对立。\n- 代价升级：林照失去直播权限。\n- 节尾钩子：收据联系人写着母亲的名字。\n\n## 第2节：公开复产\n- 结构功能：结局兑现。\n- 承接上节：母亲的名字迫使林照追问采购链。\n- 场景动作：林照在公开说明会上展示采购、检测与召回记录。\n- 子事件：\n  1. 林照宣布停售、退款和独立检测。\n  2. 林建川承认隐瞒原料并交出经营权限。\n- 情绪目标：决绝转为承担。\n- 压力变化：家族封口转为公开问责与复产成本。\n- 因果链：采购链被公开 -> 必须召回 -> 真实鲜果重新入厂。\n- 角色选择：林照选择公开召回并重启可追溯鲜榨。\n- 可见阻力：员工担心停产，林建川仍想延期公布。\n- 本节兑现：消费者在镜头里看见鲜果、压榨和检测。\n- 核心承诺兑现：公开反证与真实生产落地。\n- 决定性行动：林照提交召回和独立质检方案。\n- 现实后果：停售退款、哥哥停职、母亲退出治理。\n- 关系收束：兄妹保持裂痕但不再互相遮掩。\n- 主题回扣：理解亲人不等于替他们遮掩责任。\n- 节尾钩子：新的直播镜头里终于有了果子。\n';
  return `# ${stageId}\n\n真实 V2 回执测试当前阶段的受控输出。\n`;
}

function runProductionFinalizer(root, task) {
  const execution = task.stage_execution || {};
  const stageId = String(execution.stage_id || '');
  if (['material_card', 'short_setting', 'platform_genre_lock', 'rhythm_pattern_selection', 'section_outline'].includes(stageId)) {
    const command = [path.resolve(__dirname, '..', '..', 'scripts', 'short-planning-stage-finalize.js'), '--project-root', root, '--workflow-id', task.workflow_id, '--json'];
    if (stageId !== 'short_setting' || String(((task.short_setting_candidate || {}).status) || '') === 'confirmed_pending_commit') command.push('--apply');
    const completed = spawnSync(process.execPath, command, { encoding: 'utf8' });
    const result = JSON.parse(String(completed.stdout || '{}'));
    const status = String(result.status || '');
    return {
      status: completed.status === 0 && ['applied', 'short_setting_candidate_ready'].includes(status) ? (status === 'applied' ? 'stage_applied' : 'stage_ready_for_confirmation') : 'stage_apply_blocked',
      workflow_id: task.workflow_id,
      stage_id: stageId,
      apply_result: result,
    };
  }

  if (stageId === 'short_structure_impact_audit') return runScript(root, task, 'short-structure-impact-finalize.js', ['--apply']);
  if (stageId === 'hook_value_gate') {
    const preview = runScript(root, task, 'short-hook-value-finalize.js', []);
    if (String((preview.apply_result || {}).status || '') !== 'short_hook_value_review_required') return preview;
    const request = preview.apply_result;
    const cardFile = projectFile(root, request.review_card);
    const checks = (request.review_card_schema.checks || []).map(item => ({ ...item, status: 'pass', evidence: '两节大纲已明确冲突、选择、代价和兑现。', repair_direction: '' }));
    fs.mkdirSync(path.dirname(cardFile), { recursive: true });
    fs.writeFileSync(cardFile, `${JSON.stringify({ ...request.review_card_schema, decision: 'pass', repair_layer: 'none', summary: '标题承诺、冲突升级和结局兑现均已覆盖。', checks }, null, 2)}\n`);
    return runScript(root, task, 'short-hook-value-finalize.js', ['--apply']);
  }
  if (['section_brief', 'next_section_brief'].includes(stageId)) {
    writeBrief(root, task);
    return runScript(root, task, 'short-section-brief-finalize.js', ['--apply']);
  }
  if (['draft_section', 'draft_next_section'].includes(stageId)) {
    writeDraft(root, task);
    return runScript(root, task, 'short-section-draft-finalize.js', ['--apply']);
  }
  if (stageId === 'section_machine_gate') return runScript(root, task, 'short-section-machine-gate.js', ['--apply']);
  if (['quality_gate', 'story_value_gate'].includes(stageId)) {
    const preview = runScript(root, task, 'short-section-quality-gate.js', []);
    if (String((preview.apply_result || {}).status || '') !== 'quality_evidence_required') return preview;
    writeQualityEvidence(root, task, preview.apply_result);
    return runScript(root, task, 'short-section-quality-gate.js', ['--apply']);
  }
  if (stageId === 'section_accept_anchor') return runScript(root, task, 'short-section-accept-finalize.js', ['--apply']);
  if (stageId === 'full_story_assembly') return runScript(root, task, 'short-story-assembly-finalize.js', ['--apply']);
  return null;
}

function runScript(root, task, script, extra) {
  const completed = spawnSync(process.execPath, [path.resolve(__dirname, '..', '..', 'scripts', script), '--project-root', root, '--workflow-id', task.workflow_id, ...extra, '--json'], { encoding: 'utf8' });
  const result = JSON.parse(String(completed.stdout || '{}'));
  return {
    status: completed.status === 0 && ['applied', 'short_structure_impact_completed', 'short_hook_value_completed'].includes(String(result.status || '')) ? 'stage_applied' : 'stage_apply_blocked',
    workflow_id: task.workflow_id,
    stage_id: String((task.stage_execution || {}).stage_id || ''),
    apply_result: result,
  };
}

function writeBrief(root, task) {
  const execution = task.stage_execution || {};
  const scopeMatch = String(task.scope || '').match(/第\s*0*(\d+)\s*节/u);
  const sectionIndex = Number(execution.section_index || (scopeMatch && scopeMatch[1]) || 1);
  const contractApi = require(path.resolve(__dirname, '..', '..', 'scripts', 'lib', 'short-section-outline-contract.js'));
  const contract = contractApi.buildShortSectionOutlineContract(root, sectionIndex);
  if (contract.status !== 'current') throw new Error(`outline contract unavailable: ${contract.code || contract.status}`);
  const mapping = contract.obligations.map(item => `- ${item.id}：${item.source_text}`).join('\n');
  const ids = contract.obligations.map(item => `[${item.id}]`).join(' ');
  const brief = [
    `# 第${sectionIndex}节写作提要`,
    '> 目标 1400-1800 个中文字符',
    '## 视角与人物',
    '第一人称林照，只写她能看见、核对和选择的事实；哥哥的压力必须通过当面行动呈现。',
    '## 大纲覆盖映射', mapping,
    '## 因果动作链', `${ids}\n林照先核对证据，再在哥哥施压时做出公开选择，并承担即时后果。`,
    '## 禁止漂移', '不引入新人，不提前替哥哥洗白，不跳过公开证据与代价。',
    '## 节尾钩子', '把本节大纲规定的未决问题保留到最后一句。',
    '## 验收', '视角、人物动机、因果变化、大纲义务和节尾钩子均可在正文逐项核验。',
  ].join('\n\n');
  fs.writeFileSync(projectFile(root, `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`), `${brief}\n`);
}

function writeDraft(root, task) {
  const execution = task.stage_execution || {};
  const scopeMatch = String(task.scope || '').match(/第\s*0*(\d+)\s*节/u);
  const sectionIndex = Number(execution.section_index || (scopeMatch && scopeMatch[1]) || 1);
  const draftRel = String(execution.draft_target || ('草稿_第' + String(sectionIndex).padStart(3, '0') + '节_候选.md'));
  const allowed = Array.isArray(execution.write_set) ? execution.write_set.map(String) : [];
  if (!allowed.includes(draftRel)) throw new Error('draft target is outside write_set: ' + draftRel);
  const contractApi = require(path.resolve(__dirname, '..', '..', 'scripts', 'lib', 'short-section-outline-contract.js'));
  const contract = contractApi.buildShortSectionOutlineContract(root, sectionIndex);
  if (contract.status !== 'current') throw new Error('outline contract unavailable: ' + (contract.code || contract.status));
  const obligations = contract.obligations.filter((item) => item.required_in_draft);
  const paragraphs = [
    sectionIndex === 1
      ? '镜头扫过空仓库时，我把手机举得更稳，弹幕里那句“水果呢”像一颗钉子，正好钉在家里一直不肯碰的地方。冷库的风吹过来，只有纸箱摩擦的声音，没有一颗果子肯替我们圆谎。'
      : '说明会的灯比直播间白得多，我把采购单、检测单和退款表平码在桌上，忽然明白公开不是一句漂亮话，而是把每一笔代价都留在镜头里。',
    '我没有急着解释，只把当天的收据摊开，先核对编号，再把屏幕对准最不该被看见的那一行。林建川站在我身后，手指压着桌角，声音低得像是怕惊动员工，可他越是叫我停，我越知道这次不能替任何人把责任藏起来。',
    '我让每个问题都落到能查的地方：谁签了单，哪一批原料进了门，谁决定把沉默当成补救。观众不再替我猜答案，车间里的工人也开始抬头看那张收据；他们害怕停工，我也害怕，但害怕不能成为继续骗人的理由。',
    '林建川终于说出工资和订单的窟窿。我听着，心里那点替哥哥找借口的念头一点点塌下去。理解他为什么慌，和替他把谎话说完，是两回事。',
    ...obligations.map((item, index) => [
      '收据上的字把事实钉死：',
      '我在镜头前说清楚：',
      '林建川听见后沉下脸：',
      '弹幕替我重复了一遍：',
      '门外的工人也终于明白：',
      '这张单据留下的结论是：',
      '我把号码念出来时，所有人都看见：',
      '停播前的最后几秒证明了：',
      '哥哥不肯承认，却绕不开：',
      '我没有删掉这段直播，因为：',
      '冷库的回声提醒我：',
      '屏幕暗下去前，唯一留下的是：',
    ][index % 12] + item.source_text + '。'),
    sectionIndex === 1
      ? '我按下公开按钮，收据编号被放大在屏幕中央。直播权限下一秒就被切断，可断掉之前，我看见联系人那一栏写着母亲的名字。她为什么会在这里，等着我去问。'
      : '我在镜头前宣布停售、退款和独立检测。林建川把经营权限交出来时没有看我，工人们却把第一筐鲜果推向传送带。压榨机重新响起，检测编号贴上箱子，我终于把镜头对准真正的果子。',
  ];
  fs.writeFileSync(projectFile(root, draftRel), paragraphs.join('\n\n') + '\n');
}

function writeQualityEvidence(root, task, request) {
  const execution = task.stage_execution || {};
  const sectionIndex = Number(request.section_index || execution.section_index || 1);
  const evidenceRel = String(request.evidence_file || execution.quality_evidence_target || '');
  const allowed = Array.isArray(execution.write_set) ? execution.write_set.map(String) : [];
  if (!evidenceRel || !allowed.includes(evidenceRel)) throw new Error('quality evidence is outside write_set: ' + evidenceRel);
  const schema = request.evidence_schema || {};
  const draftRel = String(execution.draft_target || ('草稿_第' + String(sectionIndex).padStart(3, '0') + '节_候选.md'));
  const draft = fs.readFileSync(projectFile(root, draftRel), 'utf8');
  const quotes = draft.includes('镜头扫过空仓库时')
    ? ['镜头扫过空仓库时', '我没有急着解释，只把当天的收据摊开', '理解他为什么慌，和替他把谎话说完，是两回事', '我按下公开按钮，收据编号被放大在屏幕中央']
    : ['说明会的灯比直播间白得多', '我没有急着解释，只把当天的收据摊开', '理解他为什么慌，和替他把谎话说完，是两回事', '我在镜头前宣布停售、退款和独立检测'];
  const contractApi = require(path.resolve(__dirname, '..', '..', 'scripts', 'lib', 'short-section-outline-contract.js'));
  const contract = contractApi.buildShortSectionOutlineContract(root, sectionIndex);
  const obligations = new Map((contract.obligations || []).map((item) => [String(item.id), String(item.source_text)]));
  const evidence = {
    schemaVersion: '1.0.0',
    workflow_id: task.workflow_id,
    section_index: sectionIndex,
    draft_digest: schema.draft_digest,
    outline_contract_digest: schema.outline_contract_digest,
    checks: (schema.checks || []).map((item, index) => ({ id: item.id, status: 'pass', evidence: '正文以具体行动完成该项验收。', evidence_quote: quotes[index % quotes.length] })),
    outline_coverage: (schema.outline_coverage || []).map((item) => ({ ...item, status: 'pass', evidence_quote: obligations.get(String(item.id)) || '' })),
    summary: '本节以可核验的行动、代价和未决问题完成质量验收。',
    acceptance_metadata: {
      revealed_information: ['采购收据与真实原料去向已经公开。'],
      character_state: { 林照: '从犹豫转为公开承担后果', 林建川: '无法再用亲情要求隐瞒' },
      open_hook: sectionIndex === 1 ? '母亲为何出现在收据联系人栏里？' : '',
    },
  };
  if (schema.reader_milestone) {
    evidence.reader_milestone = {
      reviewer: 'professional-reader',
      kind: schema.reader_milestone.kind,
      status: 'pass',
      would_continue: 'yes',
      strongest_pull: '收据联系人把家庭责任推向下一节。',
      biggest_resistance: '公开代价仍需在后续承担。',
      evidence_quote: quotes[3],
      repair_direction: '',
    };
  }
  fs.writeFileSync(projectFile(root, evidenceRel), JSON.stringify(evidence, null, 2) + '\n');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot);
  const task = readTask(root, args.workflowId);
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running') throw new Error('current stage is not running');
  const outputs = stageOutputs(root, task);
  const finalizer = runProductionFinalizer(root, task);
  if (finalizer) {
    process.stdout.write(`${args.json ? JSON.stringify(finalizer) : finalizer.status}\n`);
    process.exitCode = finalizer.status === 'stage_apply_blocked' ? 2 : 0;
    return;
  }
  const packetRel = String(execution.expected_result_packet || '');
  if (!packetRel) throw new Error('missing expected_result_packet');
  const packet = {
    packetVersion: 'v2',
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: execution.stage_id,
    step_id: execution.step_id,
    owner_module: execution.owner_module,
    stage_attempt_id: execution.stage_attempt_id,
    step_status: 'completed',
    result_packet_path: packetRel,
    outputs,
    changed_files: outputs,
    evidence: [],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { status: 'completed' },
  };
  const packetFile = projectFile(root, packetRel);
  fs.mkdirSync(path.dirname(packetFile), { recursive: true });
  fs.writeFileSync(packetFile, `${JSON.stringify(packet, null, 2)}\n`);
  const stateMachine = path.resolve(__dirname, '..', '..', 'scripts', 'workflow-state-machine.js');
  const applied = spawnSync(process.execPath, [stateMachine, 'apply-result', '--project-root', root, '--workflow-id', task.workflow_id, '--result', packetFile, '--json'], { encoding: 'utf8' });
  const result = JSON.parse(String(applied.stdout || '{}'));
  const response = { status: applied.status === 0 && ['advanced', 'stage_started', 'workflow_choice_required'].includes(String(result.status || '')) ? 'stage_applied' : 'stage_apply_blocked', workflow_id: task.workflow_id, stage_id: execution.stage_id, outputs, apply_result: result };
  process.stdout.write(`${args.json ? JSON.stringify(response) : response.status}\n`);
  process.exitCode = response.status === 'stage_applied' ? 0 : 2;
}

try { main(); } catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 2; }
