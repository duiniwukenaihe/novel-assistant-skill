'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');
const { SHORT_WORKFLOW_TYPES: SHORT_WORKFLOWS } = require('./short-workflow-types');
const ACCEPTED_STAGES = new Set([
  'short_setting',
  'rhythm_pattern_selection',
  'section_outline',
  'section_plan_lock',
  'feedback_apply_patch',
]);
const SOURCE_FILES = ['素材卡.md', '设定.md', '小节大纲.md'];

function projectShortReaderPromise(projectRoot, task = {}, result = {}) {
  const workflowType = String(task.workflow_type || '');
  const stageId = String(result.stage_id || task.current_stage || '');
  if (!SHORT_WORKFLOWS.has(workflowType)
      || !ACCEPTED_STAGES.has(stageId)
      || String(result.step_status || 'completed') !== 'completed') {
    return { status: 'not_applicable' };
  }

  const root = path.resolve(projectRoot || '');
  const sources = Object.fromEntries(SOURCE_FILES.map(relative => [relative, readText(root, relative)]));
  if (!Object.values(sources).some(Boolean)) return { status: 'not_applicable', reason: 'planning_sources_missing' };

  const titlePromise = findLabeledValue(sources['素材卡.md'], ['标题承诺', '故事承诺', '核心卖点', '核心冲突']);
  const targetEmotion = findLabeledValue(sources['素材卡.md'], ['目标情绪', '情绪承诺', '读者情绪']);
  const protagonistDesire = findLabeledValue(sources['设定.md'], ['主角渴望', '人物渴望', '核心渴望']);
  const protagonistFear = findLabeledValue(sources['设定.md'], ['主角恐惧', '人物恐惧', '核心恐惧']);
  const relationshipDebt = findLabeledValue(sources['设定.md'], ['关系债', '关系压力', '情感债']);
  const finalPayoff = firstNonEmpty([
    findLabeledValue(sources['设定.md'], ['终局兑现', '最终兑现', '结局兑现', '终局回应']),
    findLastLabeledValue(sources['小节大纲.md'], ['终局兑现', '最终兑现', '结局兑现', '终局回应']),
  ]);
  const sections = extractSections(sources['小节大纲.md']);
  const sourceRefs = SOURCE_FILES.map(relative => sourceRef(root, relative)).filter(Boolean);
  const missingFields = readerPromiseMissingFields({
    titlePromise,
    targetEmotion,
    protagonistDesire,
    protagonistFear,
    finalPayoff,
    sections,
  });
  const projectionStatus = missingFields.length ? 'partial' : 'active';
  const previous = readJson(path.join(root, '追踪', 'memory', 'reader-promise.json')) || {};
  const revision = digest(JSON.stringify({
    titlePromise,
    targetEmotion,
    protagonistDesire,
    protagonistFear,
    relationshipDebt,
    finalPayoff,
    sections,
    sourceRefs,
    projectionStatus,
    missingFields,
  }));
  if (String(previous.revision || '') === revision) {
    return { status: 'current', memory_file: '追踪/memory/reader-promise.json', revision };
  }

  const now = new Date().toISOString();
  const payload = {
    schema_version: '1.0.0',
    type: 'short_reader_promise',
    status: projectionStatus,
    missing_fields: missingFields,
    revision,
    workflow_id: String(task.workflow_id || ''),
    task_family_id: String(task.task_family_id || ''),
    accepted_stage: stageId,
    title_promise: titlePromise,
    target_emotion: targetEmotion,
    protagonist_desire: protagonistDesire,
    protagonist_fear: protagonistFear,
    relationship_debt: relationshipDebt,
    final_payoff: finalPayoff,
    section_obligations: sections,
    source_refs: sourceRefs,
    result_packet_path: String(result.result_packet_path || ''),
    accepted_at: now,
    updated_at: now,
  };
  const relative = '追踪/memory/reader-promise.json';
  atomicWriteJson(path.join(root, relative), payload);
  return {
    status: projectionStatus === 'active' ? 'reader_promise_projected' : 'reader_promise_projection_incomplete',
    memory_file: relative,
    revision,
    section_count: sections.length,
    missing_fields: missingFields,
  };
}

function compactReaderPromiseForSection(value, sectionIndex) {
  const source = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  if (String(source.status || '') !== 'active' || !String(source.revision || '')) return null;
  const current = (Array.isArray(source.section_obligations) ? source.section_obligations : [])
    .filter(row => Number(row.section_index || 0) === Number(sectionIndex || 0))
    .map(row => ({
      section_index: Number(row.section_index || 0),
      title: String(row.title || ''),
      escalation: String(row.escalation || ''),
      payoff: String(row.payoff || ''),
      hook: String(row.hook || ''),
    }));
  return {
    revision: String(source.revision || ''),
    title_promise: String(source.title_promise || ''),
    target_emotion: String(source.target_emotion || ''),
    protagonist_desire: String(source.protagonist_desire || ''),
    protagonist_fear: String(source.protagonist_fear || ''),
    relationship_debt: String(source.relationship_debt || ''),
    current_section: current,
    final_payoff: String(source.final_payoff || ''),
  };
}

function extractSections(text) {
  const lines = String(text || '').split(/\r?\n/);
  const sections = [];
  let current = null;
  for (const line of lines) {
    const heading = line.trim().match(/^#{1,6}\s*第\s*0*(\d+)\s*节(?:\s*[：:·.、-]\s*(.*))?$/u);
    if (heading) {
      current = { section_index: Number(heading[1]), title: String(heading[2] || '').trim(), escalation: '', payoff: '', hook: '' };
      sections.push(current);
      continue;
    }
    if (!current) continue;
    const pair = labeledPair(line);
    if (!pair) continue;
    if (/(?:本节升级|压力升级|升级动作|核心动作|场景动作)/u.test(pair.label) && !current.escalation) current.escalation = pair.value;
    if (/(?:本节兑现|核心承诺兑现|终局兑现|最终兑现|结局兑现)/u.test(pair.label) && !current.payoff) current.payoff = pair.value;
    if (/(?:节尾钩子|下节承接|承接钩子)/u.test(pair.label) && !current.hook) current.hook = pair.value;
  }
  return sections.filter(row => row.section_index && (row.title || row.escalation || row.payoff || row.hook));
}

function findLabeledValue(text, labels) {
  for (const line of String(text || '').split(/\r?\n/)) {
    const pair = labeledPair(line);
    if (pair && labels.some(label => pair.label === label || pair.label.includes(label))) return pair.value;
  }
  return '';
}

function findLastLabeledValue(text, labels) {
  let found = '';
  for (const line of String(text || '').split(/\r?\n/)) {
    const pair = labeledPair(line);
    if (pair && labels.some(label => pair.label === label || pair.label.includes(label))) found = pair.value;
  }
  return found;
}

function labeledPair(line) {
  const cleaned = String(line || '').trim().replace(/^[-*+]\s*/, '').replace(/^\*\*(.+?)\*\*\s*[：:]/u, '$1：');
  const table = cleaned.match(/^\|\s*([^|]{2,24}?)\s*\|\s*([^|]+?)\s*\|$/u);
  if (table && !/^[-:]+$/u.test(table[1].trim()) && !/^[-:]+$/u.test(table[2].trim())) {
    return { label: table[1].trim(), value: table[2].trim() };
  }
  const match = cleaned.match(/^([^：:]{2,24})[：:]\s*(.+)$/u);
  return match ? { label: match[1].trim(), value: match[2].trim() } : null;
}

function readerPromiseMissingFields(value) {
  const missing = [];
  if (!String(value.titlePromise || '').trim()) missing.push('title_promise');
  if (!String(value.targetEmotion || '').trim()) missing.push('target_emotion');
  if (!String(value.protagonistDesire || '').trim()) missing.push('protagonist_desire');
  if (!String(value.protagonistFear || '').trim()) missing.push('protagonist_fear');
  if (!String(value.finalPayoff || '').trim()) missing.push('final_payoff');
  if (!Array.isArray(value.sections) || !value.sections.length) missing.push('section_obligations');
  return missing;
}

function sourceRef(root, relative) {
  const file = path.join(root, relative);
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return null;
  return { path: relative, hash: `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}` };
}

function readText(root, relative) { try { return fs.readFileSync(path.join(root, relative), 'utf8'); } catch (_) { return ''; } }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function digest(value) { return crypto.createHash('sha256').update(String(value || '')).digest('hex'); }
function firstNonEmpty(values) { return values.find(value => String(value || '').trim()) || ''; }

module.exports = { compactReaderPromiseForSection, projectShortReaderPromise };
