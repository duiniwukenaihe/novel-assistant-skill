'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');

const CHARACTER_FILE = /(?:人物|角色|关系|故事圣经|story[-_ ]?bible|设定)/iu;
const PROTAGONIST = /(?:主角|男主|女主|第一视角)/u;
const OPPOSITION = /(?:主要对手|核心对手|反派|阻力角色|宿敌)/u;

function checkLongCharacterContract(projectRoot, options = {}) {
  const source = collectCharacterSources(projectRoot, options.files);
  const characters = parseCharacters(source.text);
  const protagonist = characters.find(item => PROTAGONIST.test(item.role)) || null;
  const opponent = characters.find(item => OPPOSITION.test(item.role)) || null;
  const findings = [];
  const advisories = [];

  if (!source.files.length || !characters.length) {
    findings.push({
      code: 'missing_character_roster',
      message: '长篇故事圣经尚未形成可执行人物档案；至少需要主角、主要压力角色与关键关系。',
    });
  }

  if (!protagonist) {
    findings.push({ code: 'missing_protagonist_identity', message: '未识别到长篇主角及其稳定叙事身份。' });
  } else {
    const missing = [];
    if (!has(protagonist.body, /(?:年龄|岁|身份|职业|出身|弟子|学生|职员|修士|第一人称|第三人称)/u)) missing.push('identity');
    if (!has(protagonist.body, /(?:外部目标|目标|想要|要查清|要保住|为了|脱离|争取)/u)) missing.push('external_goal');
    if (!has(protagonist.body, /(?:内在渴望|内在需求|最怕|恐惧|害怕|软肋|失去)/u)) missing.push('fear_or_inner_need');
    if (!has(protagonist.body, /(?:缺陷|误区|误信|盲信|弱点|习惯|自我欺骗)/u)) missing.push('flaw_or_misbelief');
    if (!has(protagonist.body, /(?:能力边界|行动边界|不会|不能|不懂|代价|限制)/u)) missing.push('capability_boundary');
    if (missing.length) {
      findings.push({
        code: 'missing_protagonist_engine',
        character: protagonist.name,
        missing_fields: missing,
        message: `主角 ${protagonist.name} 尚未形成可持续的目标、软肋、缺陷与能力边界。`,
      });
    }
  }

  if (!opponent) {
    findings.push({ code: 'missing_pressure_actor_engine', message: '未识别到主要压力角色及其独立利益。' });
  } else {
    const missing = [];
    if (!has(opponent.body, /(?:目标|想要|要保住|为了|认为|相信)/u)) missing.push('goal_and_logic');
    if (!has(opponent.body, /(?:资源|权限|人脉|名义|修为|权力|证据|渠道)/u)) missing.push('usable_resources');
    if (!has(opponent.body, /(?:边界|不能|不会|代价|损失|失败)/u)) missing.push('boundary_and_cost');
    if (!has(opponent.body, /(?:升级|从.+到|试探|施压|围杀|断供|加码)/u)) missing.push('escalation_path');
    if (missing.length) {
      findings.push({
        code: 'missing_pressure_actor_engine',
        character: opponent.name,
        missing_fields: missing,
        message: `主要压力角色 ${opponent.name} 缺少自洽动机、可用资源、边界或升级路径。`,
      });
    }
  }

  const supporting = characters.filter(item => item !== protagonist && item !== opponent);
  if (!supporting.some(item => has(item.body, /(?:想要|目标|为了|查清|保住|获得|争取)/u)
      && has(item.body, /(?:不能|不会|边界|代价|限制)/u))) {
    advisories.push({
      code: 'supporting_cast_independence_weak',
      message: '关键配角尚未体现独立欲望与行动边界，后续容易退化为递证据或推动主角的工具人。',
    });
  }

  if (!has(source.text, /(?:人物关系与责任债|关系压力|关系债|利益冲突|互相.+(?:欠|需要|利用)|关系从.+(?:到|走向))/u)) {
    findings.push({ code: 'missing_relationship_engine', message: '未锁定人物之间持续生效的关系压力、利益冲突或责任债。' });
  }

  if (!has(source.text, /(?:成长里程碑|人物里程碑|第一卷|第[一二三四五六七八九十\d]+卷).*(?:成长|变化|主动|承担|失去|选择)|终局.*(?:选择|完成|兑现)/su)) {
    findings.push({
      code: 'missing_longform_growth_map',
      message: '未建立跨阶段/跨卷人物变化里程碑；长篇容易只升级能力、不推进人格与关系。',
    });
  }

  return {
    schema_version: '1.0.0',
    status: findings.length ? 'blocked' : 'pass',
    source_files: source.files,
    source_revision: `sha256:${sha256(source.text)}`,
    protagonist: protagonist ? protagonist.name : '',
    pressure_actor: opponent ? opponent.name : '',
    characters,
    findings,
    advisories,
  };
}

function projectLongCharacterMemory(projectRoot, options = {}) {
  const root = path.resolve(projectRoot || '');
  const analysis = checkLongCharacterContract(root, options);
  if (analysis.status !== 'pass') return { status: 'blocked_character_contract', ...analysis };
  const targetRel = '追踪/memory/active-cast.json';
  const target = path.join(root, targetRel);
  const existing = readJson(target) || {};
  const characters = {};
  for (const character of analysis.characters) {
    characters[character.name] = {
      ...(((existing.characters || {})[character.name]) || {}),
      role: character.role,
      identity: sentence(character.body, /(?:年龄|岁|身份|职业|出身|弟子|学生|职员|修士)/u),
      goal: sentence(character.body, /(?:外部目标|目标|想要|要查清|要保住|为了|脱离|争取)/u),
      fear_or_stake: sentence(character.body, /(?:内在渴望|内在需求|最怕|恐惧|害怕|软肋|失去)/u),
      flaw_or_misbelief: sentence(character.body, /(?:缺陷|误区|误信|盲信|弱点|习惯|自我欺骗)/u),
      capability_boundary: sentence(character.body, /(?:能力边界|行动边界|不会|不能|不懂|代价|限制)/u),
      change_arc: sentence(character.body, /(?:第一卷|第二卷|第三卷|终局|成长|从.+到|主动选择)/u),
      source_paths: analysis.source_files,
    };
  }
  atomicWriteJson(target, {
    schema_version: '1.0.0',
    source_kind: 'canonical_story_bible',
    workflow_id: String(options.workflowId || existing.workflow_id || ''),
    source_revision: analysis.source_revision,
    source_paths: analysis.source_files,
    protagonist: analysis.protagonist,
    pressure_actor: analysis.pressure_actor,
    presentCharacters: Array.isArray(existing.presentCharacters) ? existing.presentCharacters : [],
    characters,
    updated_at: new Date().toISOString(),
  });
  return {
    status: 'projected',
    memory_path: targetRel,
    character_count: analysis.characters.length,
    protagonist: analysis.protagonist,
  };
}

function collectCharacterSources(projectRoot, declaredFiles) {
  const root = path.resolve(projectRoot || '');
  const files = [];
  const add = (candidate) => {
    const relative = String(candidate || '').replace(/\\/g, '/').replace(/^\.\//, '');
    if (!relative || path.isAbsolute(relative) || relative.split('/').includes('..') || !CHARACTER_FILE.test(relative)) return;
    const file = path.resolve(root, relative);
    if (!file.startsWith(`${root}${path.sep}`) || !fs.existsSync(file) || !fs.statSync(file).isFile() || !/\.md$/iu.test(file)) return;
    if (!files.includes(relative)) files.push(relative);
  };
  for (const file of Array.isArray(declaredFiles) ? declaredFiles : []) add(file);
  for (const relative of ['设定.md', '故事圣经.md', '设定/故事圣经.md', '设定/人物.md', '设定/角色.md', '设定/角色档案.md', '设定/人物档案.md', '设定/关系.md']) add(relative);
  const settingDir = path.join(root, '设定');
  if (fs.existsSync(settingDir) && fs.statSync(settingDir).isDirectory()) {
    walkMarkdown(settingDir, root, add, 0);
  }
  const text = files.map(relative => `\n# 来源：${relative}\n${fs.readFileSync(path.join(root, relative), 'utf8')}`).join('\n');
  return { files, text };
}

function parseCharacters(text) {
  const source = String(text || '');
  const headings = Array.from(source.matchAll(/^#{1,4}\s+([^\n]+)$/gmu));
  const characters = [];
  for (let index = 0; index < headings.length; index += 1) {
    const title = String(headings[index][1] || '').trim();
    const roleMatch = title.match(/^(主角|男主|女主|第一视角|主要对手|核心对手|反派|阻力角色|宿敌|关键配角|主要配角)\s*[：:]\s*([\p{Script=Han}A-Za-z·]{2,20})/u);
    if (!roleMatch) continue;
    const bodyStart = headings[index].index + headings[index][0].length;
    const bodyEnd = headings[index + 1] ? headings[index + 1].index : source.length;
    characters.push({ name: roleMatch[2], role: roleMatch[1], body: source.slice(bodyStart, bodyEnd).trim() });
  }
  for (const match of source.matchAll(/^\s*[-*]\s*(主角|男主|女主|主要对手|核心对手|反派|关键配角)\s*[：:]\s*([\p{Script=Han}A-Za-z·]{2,20})\s*[，,：:]?([^\n]*)$/gmu)) {
    if (!characters.some(item => item.name === match[2])) characters.push({ name: match[2], role: match[1], body: match[3] });
  }
  for (const sourceBlock of source.split(/\n(?=# 来源：)/u)) {
    const block = sourceBlock.match(/^# 来源：([^\n]+)\n([\s\S]*)$/u);
    if (!block) continue;
    const relative = String(block[1] || '').trim();
    if (!/(?:^|\/)设定\/角色\//u.test(relative)) continue;
    const body = String(block[2] || '');
    const name = path.basename(relative, path.extname(relative));
    const roleMatch = body.match(/角色定位\s*[：:]\s*(主角|男主|女主|第一视角|主要对手|核心对手|反派|阻力角色|宿敌|关键配角|主要配角)/u);
    if (!roleMatch || characters.some(item => item.name === name)) continue;
    characters.push({ name, role: roleMatch[1], body });
  }
  return characters;
}

function walkMarkdown(directory, root, add, depth) {
  if (depth > 3) return;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) walkMarkdown(file, root, add, depth + 1);
    else if (entry.isFile() && /\.md$/iu.test(entry.name)) add(path.relative(root, file));
  }
}

function sentence(text, pattern, limit = 260) {
  const value = String(text || '').split(/(?<=[。！？；\n])/u).map(item => item.replace(/\s+/g, ' ').trim()).find(item => pattern.test(item)) || '';
  return value.length > limit ? `${value.slice(0, limit)}…` : value;
}

function has(text, pattern) {
  return pattern.test(String(text || ''));
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex');
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

module.exports = {
  checkLongCharacterContract,
  collectCharacterSources,
  parseCharacters,
  projectLongCharacterMemory,
};
