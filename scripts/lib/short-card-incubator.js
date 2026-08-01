'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson, atomicWriteText } = require('./workflow-state-store');
const { ensureShortProjectState, readShortProjectState } = require('./short-project-state');
const { ensureCanonicalWritePolicy } = require('./canonical-write-policy');

const INCUBATOR_STATE_REL = '追踪/story-system/incubator/card-pool.json';
const MATERIAL_SNAPSHOT_REL = '追踪/story-system/short/material-snapshot.json';

function readIncubatorState(projectRoot) {
  const file = path.join(path.resolve(projectRoot), INCUBATOR_STATE_REL);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return {
      schema_version: '1.0.0',
      status: 'active',
      rejected_card_ids: [],
      promotions: [],
    };
  }
}

function rejectedCardIds(projectRoot) {
  return new Set((readIncubatorState(projectRoot).rejected_card_ids || []).map(String));
}

function rejectCard(projectRoot, card, workflowId) {
  const root = path.resolve(projectRoot);
  const state = readIncubatorState(root);
  const cardId = cardIdentity(card);
  const rejected = new Set((state.rejected_card_ids || []).map(String));
  rejected.add(cardId);
  const next = {
    ...state,
    schema_version: '1.0.0',
    status: 'active',
    source_workflow_id: String(workflowId || state.source_workflow_id || ''),
    rejected_card_ids: [...rejected],
    updated_at: new Date().toISOString(),
  };
  atomicWriteJson(path.join(root, INCUBATOR_STATE_REL), next);
  return next;
}

function writeProjectSeed(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const card = options.card || {};
  const workflowId = String(options.workflowId || '').trim();
  const cardId = cardIdentity(card);
  const title = cardTitle(card);
  if (!workflowId) throw seedError('SHORT_PROJECT_SEED_WORKFLOW_REQUIRED', 'project seed requires workflow_id');
  if (!cardId) throw seedError('SHORT_PROJECT_SEED_CARD_REQUIRED', 'project seed requires card identity');
  fs.mkdirSync(root, { recursive: true });
  const currentState = readShortProjectState(root) || {};
  const projectId = String(currentState.project_id || options.projectId || crypto.randomUUID());
  const selectedMaterial = {
    card_id: cardId,
    label: title,
    card_type: String(card.card_type || 'topic_card'),
    target_platform: String(card.target_platform || ''),
    genre_lane: String(card.genre_lane || ''),
    primary_hotspot_id: String(card.primary_hotspot_id || ''),
    supporting_hotspot_ids: Array.isArray(card.supporting_hotspot_ids) ? card.supporting_hotspot_ids.map(String) : [],
    selected_at: String(options.selectedAt || new Date().toISOString()),
  };
  const snapshot = {
    schema_version: '1.0.0',
    project_id: projectId,
    workflow_id: workflowId,
    source_workflow_id: String(options.sourceWorkflowId || workflowId),
    source_project_root: String(options.sourceProjectRoot || ''),
    selected_material: selectedMaterial,
    card_snapshot: card,
    card_digest: sha256(JSON.stringify(card)),
    created_at: new Date().toISOString(),
  };
  atomicWriteText(path.join(root, '素材卡.md'), renderMaterialCard(card, title, cardId));
  atomicWriteJson(path.join(root, MATERIAL_SNAPSHOT_REL), snapshot);
  const projectState = ensureShortProjectState(root, {
    workflowId,
    title,
    status: 'planning',
    projectId: snapshot.project_id,
    selectedMaterial,
    sourceIncubator: {
      workflow_id: snapshot.source_workflow_id,
      project_root: snapshot.source_project_root,
      card_digest: snapshot.card_digest,
    },
  });
  const writePolicy = ensureCanonicalWritePolicy(root, {
    mode: 'strict',
    initializedFor: 'managed_short_project_seed',
  });
  return { project_state: projectState, snapshot, material_path: '素材卡.md', write_policy: writePolicy };
}

function recordPromotions(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const state = readIncubatorState(root);
  const existing = Array.isArray(state.promotions) ? state.promotions.slice() : [];
  const byCard = new Map(existing.map(item => [String(item.card_id || ''), item]));
  for (const item of options.promotions || []) byCard.set(String(item.card_id || ''), item);
  const next = {
    ...state,
    schema_version: '1.0.0',
    status: options.status || 'active',
    source_workflow_id: String(options.workflowId || state.source_workflow_id || ''),
    promotions: [...byCard.values()],
    updated_at: new Date().toISOString(),
  };
  atomicWriteJson(path.join(root, INCUBATOR_STATE_REL), next);
  return next;
}

function childProjectRoot(incubatorRoot, card, occupied = new Set()) {
  const baseRoot = path.join(path.resolve(incubatorRoot), '短篇项目');
  const baseName = safeDirectoryName(cardTitle(card)) || `短篇-${cardIdentity(card).slice(0, 8)}`;
  let candidate = path.join(baseRoot, baseName);
  let suffix = 2;
  while (occupied.has(candidate) || incompatibleExistingProject(candidate, cardIdentity(card))) {
    candidate = path.join(baseRoot, `${baseName}-${suffix}`);
    suffix += 1;
  }
  occupied.add(candidate);
  return candidate;
}

function incompatibleExistingProject(projectRoot, cardId) {
  if (!fs.existsSync(projectRoot)) return false;
  try {
    const snapshot = JSON.parse(fs.readFileSync(path.join(projectRoot, MATERIAL_SNAPSHOT_REL), 'utf8'));
    return String(((snapshot.selected_material || {}).card_id) || '') !== String(cardId || '');
  } catch (_) {
    return fs.readdirSync(projectRoot).length > 0;
  }
}

function renderMaterialCard(card, title, cardId) {
  const lines = [
    '# 素材卡',
    '',
    `- 暂定作品名：${title}`,
    `- 卡片 ID：${cardId}`,
    `- 目标平台：${String(card.target_platform || '待确认')}`,
    `- 题材方向：${String(card.genre_lane || '待确认')}`,
    `- 预计篇幅：${String(card.expected_length || '待确认')}`,
    '',
    '## 开场画面',
    String(card.opening_scene || '待补充'),
    '',
    '## 故事承诺',
    String(card.story_promise || '待补充'),
    '',
    '## 主角压力',
    String(card.protagonist_pressure || '待补充'),
    '',
    '## 对手压力',
    String(card.antagonist_pressure || '待补充'),
    '',
    '## 不可逆选择',
    String(card.irreversible_choice || '待补充'),
    '',
    '## 压力升级',
    ...(Array.isArray(card.escalation_beats) && card.escalation_beats.length
      ? card.escalation_beats.map((beat, index) => `${index + 1}. ${String(beat)}`)
      : ['1. 待补充']),
    '',
    '## 第一反转',
    String(card.first_reversal || '待补充'),
    '',
    '## 终局兑现',
    String(card.final_payoff || '待补充'),
    '',
    '## 血缘',
    `- 主资讯：${String(card.primary_hotspot_id || '未记录')}`,
    `- 辅助资讯：${(Array.isArray(card.supporting_hotspot_ids) ? card.supporting_hotspot_ids : []).join('、') || '无'}`,
  ];
  return `${lines.join('\n')}\n`;
}

function cardIdentity(card) {
  return String((card || {}).topic_id || (card || {}).canonical_id || '').trim();
}

function cardTitle(card) {
  return String((((card || {}).title_candidates || [])[0]) || (card || {}).title || cardIdentity(card) || '未命名短篇').trim();
}

function safeDirectoryName(value) {
  return String(value || '')
    .replace(/[\0/\\:*?"<>|]/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/^\.+|\.+$/g, '')
    .trim()
    .slice(0, 80);
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest('hex');
}

function seedError(code, message) {
  const error = new Error(message);
  error.code = code;
  error.status = code.toLowerCase();
  return error;
}

module.exports = {
  INCUBATOR_STATE_REL,
  MATERIAL_SNAPSHOT_REL,
  cardIdentity,
  cardTitle,
  childProjectRoot,
  readIncubatorState,
  recordPromotions,
  rejectCard,
  rejectedCardIds,
  renderMaterialCard,
  writeProjectSeed,
};
