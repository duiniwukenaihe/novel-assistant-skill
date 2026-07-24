'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const REQUIREMENT_HEADINGS = [
  ['承接', ['承接', '上节承接']],
  ['目标与阻力', ['目标与阻力', '本节目标']],
  ['因果动作', ['因果动作', '因果动作链', '情节节拍']],
  ['人物与视角锁', ['人物与视角锁', '人物锁', '视角锁']],
  ['禁写项', ['禁写项', '禁止漂移']],
  ['节尾钩子', ['节尾钩子', '结尾钩子']],
];

function buildShortRevisionRequirementView(projectRoot, task = {}, sectionIndex) {
  const root = path.resolve(projectRoot || '');
  const index = Number(sectionIndex || 0);
  if (!Number.isInteger(index) || index < 1) return { status: 'missing', reason: 'section_index_missing' };
  const pad = String(index).padStart(3, '0');
  const briefPath = `写作Brief_第${pad}节.md`;
  const brief = readText(path.join(root, briefPath));
  const requirements = REQUIREMENT_HEADINGS.flatMap(([label, aliases]) => {
    const content = headingBody(brief, aliases);
    return content ? [{ label, content }] : [];
  });
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : {};
  const item = (Array.isArray(queue.items) ? queue.items : [])
    .find(row => Number((row || {}).section_index || 0) === index) || {};
  const plan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : {};
  const planApplies = !Array.isArray(plan.affected_sections)
    || !plan.affected_sections.length
    || plan.affected_sections.map(Number).includes(index)
    || (Array.isArray(queue.affected_sections) && queue.affected_sections.map(Number).includes(index));
  const sources = [
    brief ? { kind: 'current_brief', path: briefPath, digest: sha256(brief) } : null,
    fs.existsSync(path.join(root, '小节大纲.md')) ? { kind: 'section_outline', path: '小节大纲.md' } : null,
    index > 1 && fs.existsSync(path.join(root, `追踪/private-short-extension/section-${String(index - 1).padStart(3, '0')}-anchor.json`))
      ? { kind: 'previous_anchor', path: `追踪/private-short-extension/section-${String(index - 1).padStart(3, '0')}-anchor.json` }
      : null,
    planApplies && String(plan.plan_id || '') ? { kind: 'accepted_plan', path: String(task.accepted_plan_path || '任务已确认方案'), id: String(plan.plan_id) } : null,
  ].filter(Boolean);
  const title = briefTitle(brief) || `第 ${index} 节`;
  const requirementVersion = `requirement-${sha256(JSON.stringify({ index, requirements, sources, queue_id: queue.queue_id || '' })).slice(0, 12)}`;
  const lines = [
    `第 ${index} 节当前回炉要求｜${title}`,
    `要求版本：${requirementVersion}`,
    '',
    ...(requirements.length
      ? requirements.flatMap(row => [`${row.label}：`, row.content, ''])
      : ['当前尚无完整 Brief 要求；你的意见仍只绑定本节，系统会先重建本节 Brief。', '']),
    '调整边界：默认只更新本节要求、Brief 与正文复检；如意见实际改变全篇设定、人物长期动机、后续钩子或章节结构，系统必须先提示影响升级。',
    '',
    '请直接输入对本节要求的修改意见。',
  ];
  return {
    status: 'current',
    section_index: index,
    section_title: title,
    requirement_version: requirementVersion,
    requirements,
    sources,
    queue_item_status: String(item.status || ''),
    scope_mode: 'current_section_only',
    text: lines.join('\n').replace(/\n{3,}/g, '\n\n').trim(),
  };
}

function headingBody(markdown, aliases) {
  const lines = String(markdown || '').split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const heading = lines[index].match(/^#{2,6}\s*(.*?)\s*$/u);
    if (!heading || !aliases.includes(String(heading[1] || '').trim())) continue;
    const body = [];
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      if (/^#{2,6}\s/u.test(lines[cursor])) break;
      body.push(lines[cursor]);
    }
    return compactBody(body.join('\n'));
  }
  return '';
}

function compactBody(value) {
  return String(value || '').trim().split(/\r?\n/).map(line => line.trim()).filter(Boolean).join('\n');
}

function briefTitle(markdown) {
  const match = String(markdown || '').match(/^#\s*写作\s*Brief[：:]\s*第\s*0*\d+\s*节(?:《([^》]+)》)?/mu);
  return String((match || [])[1] || '').trim();
}

function readText(file) {
  try { return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : ''; } catch (_) { return ''; }
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex');
}

module.exports = { buildShortRevisionRequirementView };
