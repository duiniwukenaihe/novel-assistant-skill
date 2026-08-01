#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { resolvePrivateModule } = require('./lib/private-runtime-resolver');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'material_learning'
      || String(execution.stage_id || '') !== 'material_learning'
      || String(execution.status || '') !== 'running') {
    return finish({ status: 'short_material_learning_stage_not_running', current_stage: String(task.current_stage || '') }, 0, args.json);
  }
  const runtime = resolvePrivateRuntime();
  if (!runtime) return finish({ status: 'private_short_runtime_missing' }, 1, args.json);
  const candidateRel = String(execution.material_learning_candidate || `${task.task_dir}/artifacts/material-learning/candidate-cards.json`);
  const contextRel = String(execution.material_learning_context || `${task.task_dir}/artifacts/material-learning/context.json`);
  const candidateFile = safeProjectFile(root, candidateRel);
  const contextFile = safeProjectFile(root, contextRel);
  const infoCards = readJsonl(path.join(root, '追踪/private-short-extension/cards/info-source-cards.jsonl'));
  const selected = selectInfoCards(infoCards);
  if (selected.length === 0) {
    return finish({
      status: 'short_material_learning_info_selection_required',
      workflow_id: String(task.workflow_id || ''),
      recovery: '先在“选择资讯素材”阶段明确选择一张或多张资讯卡，再生成素材、爆点和脑洞卡。',
    }, 0, args.json);
  }
  const contractRun = run(process.env.PYTHON || 'python3', [runtime.pipeline, 'contract'], root);
  const contract = parseJson(contractRun.stdout);
  if (contractRun.status !== 0 || !contract) {
    return finish({ status: 'short_material_learning_contract_unavailable', detail: String(contractRun.stderr || '').trim().slice(0, 300) }, 1, args.json);
  }
  const generationPlan = buildGenerationPlan(selected);
  applyGenerationPlan(contract, generationPlan);
  const context = {
    schemaVersion: '1.0.0',
    workflow_id: String(task.workflow_id || ''),
    stage_id: 'material_learning',
    target_platform: String(task.target_platform || '番茄短篇'),
    selected_info_cards: selected.map(compactInfoCard),
    generation_plan: generationPlan,
    output_path: candidateRel,
    contract,
    instruction: '资讯只是写作燃料，不是现成故事。只依据 selected_info_cards 生成少量高差异候选 JSON：每条已选资讯形成一张紧凑素材卡，再抽取 generation_plan 指定数量的不同爆点，最后生成同等数量的脑洞卡。不同卡必须改变人物关系、冲突发动机、反转机制或终局兑现，禁止只换职业、标题和道具。不得联网、读取 Skill/validator/workflow 源码或创建临时脚本。',
  };
  atomicWriteJson(contextFile, context);
  if (!args.apply) {
    return finish({ status: 'short_material_learning_context_ready', context_path: contextRel, candidate_path: candidateRel, ...context }, 0, args.json);
  }
  if (!isFile(candidateFile)) {
    return finish({
      status: 'short_material_learning_candidate_required',
      context_path: contextRel,
      candidate_path: candidateRel,
      instruction: '只读取 context_path，按其中合同写 candidate_path，然后重新运行同一 apply 命令。',
    }, 0, args.json);
  }
  let candidate = readJson(candidateFile);
  if (!candidate || typeof candidate !== 'object') {
    return finish({ status: 'short_material_learning_candidate_invalid', candidate_path: candidateRel }, 0, args.json);
  }
  candidate = normalizeLegacyCandidate(candidate, infoCards, String(task.target_platform || '番茄短篇'));
  atomicWriteJson(candidateFile, candidate);
  const validationFile = safeProjectFile(root, `${task.task_dir}/artifacts/material-learning/validation-input.json`);
  atomicWriteJson(validationFile, { info_source_cards: infoCards, ...candidate });
  const validation = run(process.env.PYTHON || 'python3', [runtime.pipeline, 'validate', validationFile], root);
  const validationJson = parseJson(validation.stdout) || { status: 'error', detail: String(validation.stderr || '').trim().slice(0, 500) };
  if (validation.status !== 0) {
    const attempts = recordValidationAttempt(root, task, candidateFile, validationJson);
    const exhausted = attempts.attempt_count >= 2;
    return finish({
      status: exhausted ? 'short_material_learning_manual_recovery_required' : 'short_material_learning_revision_required',
      candidate_path: candidateRel,
      attempt_count: attempts.attempt_count,
      retry_budget: 2,
      finding_count: Number(validationJson.finding_count || (validationJson.errors || []).length || 0),
      findings: summarizeValidationFindings(validationJson.errors),
      instruction: exhausted
        ? '停止自动重试。保留候选稿与资讯血缘，向用户展示阻塞原因；不得继续猜字段、扩读项目、重抓资讯或读取旧结果包。'
        : '按 findings 分组一次性修订对应卡片；保留资讯血缘和已通过卡片，不得逐字段循环、扩读项目或重抓资讯。',
    }, 0, args.json);
  }
  const imported = run(process.env.PYTHON || 'python3', [runtime.pipeline, 'story-pool', 'import', '--workspace', root, '--input', candidateFile], root);
  const importedJson = parseJson(imported.stdout) || { status: 'error', detail: String(imported.stderr || '').trim().slice(0, 500) };
  if (imported.status !== 0) return finish({ status: 'short_material_learning_import_blocked', import_result: importedJson }, 0, args.json);

  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/material_learning.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  const outputs = [
    '追踪/private-short-extension/cards/material-cards.jsonl',
    '追踪/private-short-extension/cards/hotspot-cards.jsonl',
    '追踪/private-short-extension/cards/topic-cards.jsonl',
  ];
  atomicWriteJson(packetFile, {
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'material_learning',
    step_id: 'material_learning',
    owner_module: String(execution.owner_module || 'private-short-extension'),
    step_status: 'completed',
    outputs,
    changed_files: outputs,
    created_files: [],
    evidence: [{ validation: validationJson, import_result: importedJson, selected_info_ids: selected.map(card => String(card.info_id || '')) }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: 'material_learning', completed_range: '脑洞卡池已通过故事价值门', remaining_range: '等待选择卡片', resume_from: '' },
    handoff_summary: `已生成 ${Number(importedJson.topic_cards || 0)} 张通过故事价值门的脑洞卡。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'), 'apply-result',
    '--project-root', root,
    '--workflow-id', String(task.workflow_id || ''),
    '--result', packetFile,
    '--compact', '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  return finish({
    status: outcome.applied ? 'short_material_learning_accepted' : 'short_material_learning_apply_blocked',
    workflow_id: String(task.workflow_id || ''),
    topic_cards: Number(importedJson.topic_cards || 0),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function resolvePrivateRuntime() {
  const root = resolvePrivateModule('private-short-extension', [path.join('scripts', 'card_pipeline.py')]);
  return root ? { pipeline: path.join(root, 'scripts', 'card_pipeline.py') } : null;
}
function selectInfoCards(cards) {
  return cards.filter(card => String((card || {}).pool_status || '') === 'selected').slice(0, 8);
}
function compactInfoCard(card) {
  const scorecard = isObject(card.scorecard) ? card.scorecard : {};
  const materialScore = Number(card.material_score || scorecard.material_score || 0);
  return {
    info_id: String(card.info_id || ''),
    title: String(card.title || '').slice(0, 120),
    factual_summary: String(card.factual_summary || '').slice(0, 600),
    human_conflict: String(card.human_conflict || '').slice(0, 400),
    route_fit: Array.isArray(card.route_fit) ? card.route_fit.slice(0, 4) : [],
    discussion_value: card.discussion_value || {},
    material_score: Number.isFinite(materialScore) ? materialScore : 0,
    verdict: String(card.verdict || 'backup'),
    learning_notes: compactLearningNotes(card.learning_notes),
    source_refs: Array.isArray(card.source_refs) ? card.source_refs.slice(0, 4) : [],
  };
}
function buildGenerationPlan(selected) {
  const selectedCount = Math.max(1, selected.length);
  const topicCardCount = Math.min(5, Math.max(3, selectedCount + 2));
  const strongSources = selected.filter(card => {
    const scorecard = isObject(card.scorecard) ? card.scorecard : {};
    const score = Number(card.material_score || scorecard.material_score || 0);
    return String(card.verdict || '') === 'write' && Number.isFinite(score) && score >= 8;
  });
  return {
    material_card_count: selectedCount,
    hotspot_card_count: topicCardCount,
    topic_card_count: topicCardCount,
    primary_candidate_limit: strongSources.length > 0 ? Math.min(2, strongSources.length) : 0,
    candidate_mode: strongSources.length > 0 ? 'recommendable' : 'exploratory_backup',
    scoring_mode: 'compact_numeric_with_one_reason',
    source_role_rule: '低分或 backup 资讯只能作为压力、证据或反转辅助，不得被硬抬成主故事',
    diversity_rule: '候选之间至少改变人物关系、冲突发动机、反转机制、终局兑现中的两项',
  };
}
function applyGenerationPlan(contract, plan) {
  const shape = isObject(contract.candidate_shape) ? contract.candidate_shape : {};
  if (isObject(shape.material_cards)) shape.material_cards.count = `exactly ${plan.material_card_count}`;
  if (isObject(shape.hotspot_cards)) shape.hotspot_cards.count = `exactly ${plan.hotspot_card_count}`;
  if (isObject(shape.topic_cards)) shape.topic_cards.count = `exactly ${plan.topic_card_count}`;
}
function compactLearningNotes(value) {
  if (typeof value === 'string') return value.slice(0, 300);
  if (!isObject(value)) return '';
  return Object.fromEntries(Object.entries(value).slice(0, 5).map(([key, item]) => [key, String(item || '').slice(0, 120)]));
}
function summarizeValidationFindings(errors) {
  const groups = new Map();
  for (const finding of Array.isArray(errors) ? errors : []) {
    const item = isObject(finding) ? finding : { code: String(finding || 'validation_error') };
    const code = String(item.code || 'validation_error');
    const current = groups.get(code) || { code, count: 0, cards: new Set(), fields: new Set() };
    current.count += 1;
    const card = item.topic || item.hotspot || item.card || item.material;
    if (card) current.cards.add(String(card));
    if (item.field) current.fields.add(String(item.field));
    groups.set(code, current);
  }
  return [...groups.values()]
    .sort((left, right) => right.count - left.count || left.code.localeCompare(right.code))
    .slice(0, 12)
    .map(item => ({
      code: item.code,
      count: item.count,
      cards: [...item.cards].slice(0, 8),
      fields: [...item.fields].slice(0, 8),
    }));
}
function normalizeLegacyCandidate(candidate, infoCards, targetPlatform) {
  const infoById = new Map(infoCards.map(card => [String(card.info_id || ''), card]));
  const materials = (Array.isArray(candidate.material_cards) ? candidate.material_cards : []).map((card, index) => {
    const canonicalId = String(card.canonical_id || card.material_id || card.id || `material-${index + 1}`);
    const sourceInfoIds = arrayOfStrings(card.source_info_ids).length
      ? arrayOfStrings(card.source_info_ids)
      : arrayOfStrings(card.source_info_id || card.source_info_ids);
    const sourceRefs = sourceInfoIds.flatMap(id => arrayOfObjects((infoById.get(id) || {}).source_refs));
    return {
      ...card,
      card_type: 'material_card',
      canonical_id: canonicalId,
      source_type: String(card.source_type || 'online'),
      source_refs: arrayOfObjects(card.source_refs).length ? arrayOfObjects(card.source_refs) : sourceRefs,
      source_info_ids: sourceInfoIds,
    };
  });
  const materialById = new Map(materials.map(card => [String(card.canonical_id || ''), card]));
  const hotspots = (Array.isArray(candidate.hotspot_cards) ? candidate.hotspot_cards : []).map((card, index) => ({
    ...card,
    card_type: 'hotspot_card',
    hotspot_id: String(card.hotspot_id || card.id || `hotspot-${index + 1}`),
    source_material_ids: arrayOfStrings(card.source_material_ids).length
      ? arrayOfStrings(card.source_material_ids)
      : arrayOfStrings(card.material_id || card.material_ids),
    platform_fit: arrayOfStrings(card.platform_fit),
  }));
  const hotspotByMaterial = new Map();
  for (const hotspot of hotspots) {
    for (const materialId of arrayOfStrings(hotspot.source_material_ids)) {
      const list = hotspotByMaterial.get(materialId) || [];
      list.push(String(hotspot.hotspot_id || ''));
      hotspotByMaterial.set(materialId, list);
    }
  }
  const topics = (Array.isArray(candidate.topic_cards) ? candidate.topic_cards : []).map((card, index) => {
    const materialIds = arrayOfStrings(card.material_ids || card.source_material_ids);
    const linkedHotspots = materialIds.flatMap(id => hotspotByMaterial.get(id) || []);
    const explicitHotspots = [card.primary_hotspot_id, ...arrayOfStrings(card.supporting_hotspot_ids || card.hotspot_ids)].filter(Boolean).map(String);
    const hotspotIds = [...new Set(explicitHotspots.length ? explicitHotspots : linkedHotspots)];
    const beats = arrayOfStrings(card.escalation_beats).length
      ? arrayOfStrings(card.escalation_beats)
      : arrayOfStrings(card.three_level_escalation);
    const referencedMaterials = materialIds.map(id => materialById.get(id)).filter(Boolean);
    const bridgeText = String(card.shared_causality || card.cross_card_bridge || card.core_premise || '');
    const safetySource = referencedMaterials.find(item => item.fictionalization || item.dignity_boundary || item.non_exploitation) || {};
    return {
      ...card,
      card_type: 'topic_card',
      topic_id: String(card.topic_id || card.id || `topic-${index + 1}`),
      primary_hotspot_id: String(card.primary_hotspot_id || hotspotIds[0] || ''),
      supporting_hotspot_ids: hotspotIds.slice(1),
      target_platform: String(card.target_platform || targetPlatform),
      title_candidates: arrayOfStrings(card.title_candidates || card.titles),
      genre_lane: String(card.genre_lane || card.platform_fit || ''),
      opening_scene: String(card.opening_scene || card.core_premise || ''),
      story_promise: String(card.story_promise || card.core_premise || ''),
      protagonist_pressure: String(card.protagonist_pressure || beats[0] || ''),
      antagonist_pressure: String(card.antagonist_pressure || beats[1] || beats[0] || ''),
      irreversible_choice: String(card.irreversible_choice || card.first_reversal || ''),
      escalation_beats: beats,
      first_reversal: String(card.first_reversal || ''),
      final_payoff: String(card.final_payoff || card.final_cashout || ''),
      expected_length: String(card.expected_length || '短篇 8000-12000 字'),
      ...(hotspotIds.length > 1 ? {
        combination_bridge: isObject(card.combination_bridge) ? card.combination_bridge : {
          primary_conflict: bridgeText,
          pressure_amplifier: bridgeText,
          evidence_or_reversal: bridgeText,
          causal_chain: bridgeText,
        },
      } : {}),
      ...((safetySource.fictionalization || safetySource.dignity_boundary || safetySource.non_exploitation) ? {
        fiction_safety: isObject(card.fiction_safety) ? card.fiction_safety : {
          fictionalization: String(safetySource.fictionalization || ''),
          dignity_boundary: String(safetySource.dignity_boundary || ''),
          non_exploitation: String(safetySource.non_exploitation || ''),
        },
      } : {}),
    };
  });
  return { ...candidate, material_cards: materials, hotspot_cards: hotspots, topic_cards: topics };
}
function arrayOfStrings(value) {
  if (Array.isArray(value)) return value.filter(item => item !== undefined && item !== null && String(item).trim()).map(item => String(item));
  if (value === undefined || value === null || String(value).trim() === '') return [];
  return [String(value)];
}
function arrayOfObjects(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function isObject(value) { return Boolean(value) && typeof value === 'object' && !Array.isArray(value); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readJsonl(file) {
  if (!isFile(file)) return [];
  return fs.readFileSync(file, 'utf8').split(/\r?\n/u).filter(Boolean).map(line => JSON.parse(line));
}
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }
function recordValidationAttempt(root, task, candidateFile, validation) {
  const file = safeProjectFile(root, `${task.task_dir}/artifacts/material-learning/validation-attempts.json`);
  const current = readJson(file) || {};
  const stageAttemptId = String(((task || {}).stage_execution || {}).stage_attempt_id || 'material-learning');
  const sameAttempt = String(current.stage_attempt_id || '') === stageAttemptId;
  const attemptCount = sameAttempt ? Number(current.attempt_count || 0) + 1 : 1;
  const candidateHash = crypto.createHash('sha256').update(fs.readFileSync(candidateFile)).digest('hex');
  atomicWriteJson(file, {
    schemaVersion: '1.0.0',
    stage_attempt_id: stageAttemptId,
    attempt_count: attemptCount,
    retry_budget: 2,
    candidate_hash: candidateHash,
    finding_count: Number(validation.finding_count || (validation.errors || []).length || 0),
    updated_at: new Date().toISOString(),
  });
  return { attempt_count: attemptCount };
}
function run(command, args, cwd) { return spawnSync(command, args, { cwd, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 }); }
function isFile(file) { return fs.existsSync(file) && fs.statSync(file).isFile(); }
function safeProjectFile(root, relative) {
  const file = path.resolve(root, relative);
  if (!file.startsWith(`${root}${path.sep}`)) throw new Error(`unsafe project path: ${relative}`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  return file;
}
function parseArgs(argv) {
  const out = { projectRoot: '.', workflowId: '', apply: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '.';
    else if (arg === '--workflow-id') out.workflowId = argv[++index] || '';
    else if (arg === '--apply') out.apply = true;
    else if (arg === '--prepare') out.apply = false;
    else if (arg === '--json') out.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!out.workflowId) throw new Error('--workflow-id is required');
  return out;
}
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : String(value.status || '')}\n`); return code; }

if (require.main === module) process.exitCode = main();

module.exports = { buildGenerationPlan, summarizeValidationFindings };
