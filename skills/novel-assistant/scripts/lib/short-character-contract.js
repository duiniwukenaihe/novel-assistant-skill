'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');

const PROTAGONIST_ROLE = /主角|女主|男主|第一人称/u;
const PRESSURE_ROLE = /对手|反派|阻力|压力|哥哥|姐姐|母亲|父亲|婆婆|老板|上司|前任|丈夫|妻子/u;
const CHARACTER_ROLE_LABEL = /主角|女主|男主|主要压力角色|压力角色|主要对手|对手|反派|主要阻力|支撑角色|配角|朋友|证人/u;
const CHARACTER_TITLE_PREFIX = /(?:(?:第一人称)?主角|女主|男主|主要压力角色|压力角色|主要对手|对手|反派|主要阻力|支撑角色|配角|朋友|证人)/u;

function analyzeShortCharacterContract(settingText) {
  const source = String(settingText || '');
  const tableCharacters = parseCharacterTable(source);
  const profiles = parseCharacterProfiles(source);
  const inlineCharacters = parseInlineCharacters(source);
  const characters = mergeCharacters(tableCharacters, profiles, inlineCharacters);
  const protagonist = findProtagonist(characters);
  const findings = [];
  const advisories = [];

  if (!characters.length) {
    findings.push({
      code: 'missing_character_roster',
      message: '设定尚未形成可执行人物表；至少锁定主角与主要压力角色。',
    });
  }

  if (!protagonist) {
    findings.push({
      code: 'missing_protagonist_identity',
      message: '未识别到主角及其叙事身份；请明确主角名、视角、年龄/社会位置。',
    });
  } else {
    const protagonistText = `${protagonist.profile || ''}\n${source}`;
    const missing = [];
    if (!hasIdentity(protagonist)) missing.push('identity');
    if (!hasGoal(protagonist, protagonistText)) missing.push('external_goal');
    if (!/(?:最怕|恐惧|害怕|失去|软肋|不愿承认|内在需求|渴望)/u.test(protagonistText)) missing.push('fear_or_inner_need');
    if (!/(?:缺陷|误区|误信|盲信|过度相信|无条件相信|弱点|软肋|习惯被|自我欺骗)/u.test(protagonistText)) missing.push('flaw_or_misbelief');
    if (!hasBoundary(protagonist, protagonistText)) missing.push('capability_boundary');
    if (!/(?:关键行动|主动选择|第一次主动|最终选择|不可替代|成长|从[^\n]{0,40}(?:到|走向)|终局必须|亲自撤回|亲自完成)/u.test(protagonistText)) missing.push('agency_arc');
    if (missing.length) {
      findings.push({
        code: 'missing_protagonist_engine',
        character: protagonist.name,
        missing_fields: missing,
        message: `主角 ${protagonist.name} 只有身份信息，尚未形成“目标-软肋-缺陷-能力边界-主动变化”的人物发动机。`,
      });
    }
  }

  const supporting = characters.filter(item => !protagonist || item.name !== protagonist.name);
  const pressureActor = supporting.find(item => isPressureActor(item));
  const nonHumanPressure = /(?:非人物阻力|环境压力|制度压力|生存压力|自然灾害|规则压力)/u.test(source);
  if (!pressureActor && !nonHumanPressure) {
    findings.push({
      code: 'missing_pressure_actor_engine',
      message: '未找到有独立目标、自洽理由、可用资源和行动边界的主要压力角色；配角不能只负责递证据或推动主角。',
    });
  }

  if (characters.length > 1 && !/(?:人物关系与责任债|关系压力|关系债|情绪债|利益冲突|互相[^\n]{0,20}(?:欠|需要|利用)|关系从[^\n]{0,30}(?:到|走向))/u.test(source)) {
    findings.push({
      code: 'missing_relationship_engine',
      message: '人物已列出，但没有锁定彼此的关系压力、责任债或关系变化终点。',
    });
  }

  for (const character of characters) {
    const missing = [];
    if (!hasIdentity(character)) missing.push('identity');
    if (!hasGoal(character, character.profile)) missing.push('goal');
    if (!hasBoundary(character, character.profile)) missing.push('boundary');
    if (missing.length && character.name !== String((protagonist || {}).name || '')) {
      advisories.push({
        code: 'supporting_character_underfilled',
        character: character.name,
        missing_fields: missing,
        message: `${character.name} 的人物卡仍偏功能化；补齐独立目标或行动边界可降低后续工具人化风险。`,
      });
    }
  }

  return {
    schema_version: '1.0.0',
    status: findings.length ? 'blocked' : 'pass',
    protagonist: protagonist ? protagonist.name : '',
    pressure_actor: pressureActor ? pressureActor.name : (nonHumanPressure ? 'non_human_pressure' : ''),
    characters,
    findings,
    advisories,
  };
}

function projectShortCharacterMemory(projectRoot, options = {}) {
  const root = path.resolve(projectRoot || '');
  const settingRel = String(options.settingPath || '设定.md').replace(/\\/g, '/').replace(/^\.\//, '');
  const settingFile = safeProjectFile(root, settingRel);
  if (!settingFile || !fs.existsSync(settingFile) || !fs.statSync(settingFile).isFile()) {
    return { status: 'blocked_character_setting_missing', setting_path: settingRel };
  }
  const settingText = fs.readFileSync(settingFile, 'utf8');
  const analysis = analyzeShortCharacterContract(settingText);
  if (analysis.status !== 'pass') return { status: 'blocked_character_contract', ...analysis };

  const targetRel = '追踪/memory/active-cast.json';
  const targetFile = path.join(root, targetRel);
  const existing = readJson(targetFile) || {};
  const existingCharacters = existing.characters && typeof existing.characters === 'object' && !Array.isArray(existing.characters)
    ? existing.characters
    : {};
  const characters = {};
  for (const character of analysis.characters) {
    const previous = existingCharacters[character.name] && typeof existingCharacters[character.name] === 'object'
      ? existingCharacters[character.name]
      : {};
    characters[character.name] = {
      ...previous,
      role: character.role,
      aliases: character.aliases,
      identity: compact(character.identity || character.age_job),
      relationship: compact(character.relationship),
      goal: compact(character.goal || sentence(character.profile, /(?:想|要|目标|为了|保住|查清|保护|完成)/u)),
      fear_or_stake: compact(sentence(`${character.profile}\n${settingText}`, /(?:最怕|恐惧|害怕|失去|软肋|担心)/u)),
      flaw_or_misbelief: compact(sentence(`${character.profile}\n${settingText}`, /(?:缺陷|误区|误信|盲信|过度相信|无条件相信|弱点|软肋|习惯被)/u)),
      capability_boundary: compact(character.boundary || sentence(character.profile, /(?:不懂|不会|不能|能力有限|行动边界)/u)),
      change_arc: compact(sentence(`${character.profile}\n${settingText}`, /(?:关键行动|主动选择|第一次主动|最终选择|不可替代|成长|终局必须|亲自撤回|亲自完成)/u)),
      voice: compact(character.voice),
      evidence_anchor: compact(character.evidence),
      source_path: settingRel,
    };
  }
  atomicWriteJson(targetFile, {
    schema_version: '1.0.0',
    source_kind: 'canonical_setting',
    workflow_id: String(options.workflowId || existing.workflow_id || ''),
    source_path: settingRel,
    source_revision: `sha256:${sha256(settingText)}`,
    protagonist: analysis.protagonist,
    pressure_actor: analysis.pressure_actor,
    presentCharacters: Array.isArray(existing.presentCharacters) ? existing.presentCharacters : [],
    characters,
    updated_at: new Date().toISOString(),
  });
  return {
    status: 'projected',
    memory_path: targetRel,
    character_count: Object.keys(characters).length,
    protagonist: analysis.protagonist,
  };
}

function parseCharacterTable(source) {
  const lines = String(source || '').split(/\r?\n/);
  const result = [];
  for (let index = 0; index < lines.length - 2; index += 1) {
    const header = tableCells(lines[index]);
    if (!header.length || !header.some(cell => /角色/u.test(cell)) || !/^\s*\|?\s*:?-{3,}/u.test(lines[index + 1])) continue;
    const columns = header.map(normalizeColumn);
    for (let rowIndex = index + 2; rowIndex < lines.length; rowIndex += 1) {
      const cells = tableCells(lines[rowIndex]);
      if (!cells.length) break;
      const row = {};
      for (let columnIndex = 0; columnIndex < columns.length; columnIndex += 1) {
        if (columns[columnIndex]) row[columns[columnIndex]] = String(cells[columnIndex] || '').trim();
      }
      const name = cleanName(row.name);
      if (name) result.push({ name, ...row, aliases: aliasesFor(row, lines[rowIndex]), profile: '', role: roleFor(row, lines[rowIndex]) });
    }
    if (result.length) break;
  }
  return result;
}

function parseCharacterProfiles(source) {
  const heading = /^(#{2,3})\s+([^\n]+)$/gmu;
  const matches = Array.from(String(source || '').matchAll(heading)).map((match) => ({
    level: String(match[1] || '').length,
    title: String(match[2] || '').trim(),
    index: Number(match.index || 0),
    raw: match[0],
  }));
  return matches.map((match, index) => {
    const title = match.title;
    const nextPeer = matches.slice(index + 1).find((candidate) => candidate.level <= match.level);
    const body = String(source || '').slice(match.index + match.raw.length, nextPeer ? nextPeer.index : source.length).trim();
    const name = cleanName(title);
    return { name, profile: body, title, aliases: aliasesFor({}, title), role: roleFor({}, `${title}\n${body}`) };
  }).filter(item => {
    if (!item.name) return false;
    if (/^(?:锚点|场景|阶段|步骤|风险|边界|故事承诺|情绪目标)/u.test(item.title)) return false;
    if (CHARACTER_ROLE_LABEL.test(item.title) || PRESSURE_ROLE.test(item.title)) return true;
    return /(?:\d{2}\s*岁|多岁|岁左右|出头|已离世|总经理|总监|经理|导播|工人|律师|学生|职员|设计师|文案|创始人|标注员)/u.test(`${item.title}\n${item.profile}`);
  });
}

function parseInlineCharacters(source) {
  const result = [];
  for (const match of String(source || '').matchAll(/^\s*[-*]\s*(主角|女主|男主|哥哥|姐姐|母亲|父亲|对手|反派|主要阻力)\s*[：:]\s*([^\n]+)$/gmu)) {
    const name = cleanName(match[2]);
    if (!name) continue;
    result.push({
      name,
      profile: String(match[2] || '').trim(),
      title: String(match[1] || ''),
      aliases: unique([String(match[1] || '')]),
      role: PROTAGONIST_ROLE.test(match[1]) ? 'protagonist' : 'supporting',
    });
  }
  return result;
}

function mergeCharacters(...groups) {
  const merged = new Map();
  for (const group of groups) {
    for (const item of group) {
      const name = cleanName(item.name);
      if (!name) continue;
      const current = merged.get(name) || { name, aliases: [], profile: '', role: '' };
      merged.set(name, {
        ...current,
        ...Object.fromEntries(Object.entries(item).filter(([, value]) => value !== undefined && value !== '')),
        name,
        profile: [current.profile, item.profile].filter(Boolean).join('\n'),
        aliases: unique([...(current.aliases || []), ...(item.aliases || [])]),
        role: current.role === 'protagonist' || item.role === 'protagonist' ? 'protagonist' : (item.role || current.role || 'supporting'),
      });
    }
  }
  return [...merged.values()];
}

function findProtagonist(characters) {
  return characters.find(item => item.role === 'protagonist' || PROTAGONIST_ROLE.test(`${item.title || ''}\n${item.identity || ''}\n${item.profile || ''}`)) || null;
}

function isPressureActor(character) {
  const text = `${character.title || ''}\n${character.profile || ''}\n${character.goal || ''}\n${character.relationship || ''}`;
  return hasGoal(character, text)
    && hasBoundary(character, text)
    && (PRESSURE_ROLE.test(text) || /(?:为了|认为|担心|害怕|保住|控制权|利益|代价)/u.test(text));
}

function hasIdentity(character) {
  return Boolean(compact(character.identity || character.age_job) || /(?:\d{2}\s*岁|第一人称|毕业生|总经理|学生|职员|母亲|父亲|哥哥|姐姐)/u.test(character.profile || ''));
}

function hasGoal(character, text) {
  return Boolean(compact(character.goal) || /(?:目标|想要|想保住|要保住|查清|保护|完成|阻止|争取|为了)/u.test(text || ''));
}

function hasBoundary(character, text) {
  return Boolean(compact(character.boundary) || /(?:行动边界|能力边界|不会|不能|不懂|不突然|能力有限|不得)/u.test(text || ''));
}

function roleFor(row, text) {
  const value = `${row.identity || ''}\n${row.relationship || ''}\n${text || ''}`;
  return PROTAGONIST_ROLE.test(value) ? 'protagonist' : 'supporting';
}

function aliasesFor(row, text) {
  const aliases = [];
  for (const match of `${row.identity || ''}\n${row.relationship || ''}\n${text || ''}`.matchAll(/[“"]([^”"]{1,12})[”"]/gu)) aliases.push(match[1]);
  for (const label of ['我', '哥', '哥哥', '姐', '姐姐', '妈', '母亲', '爸', '父亲', '丈夫', '妻子', '老板', '上司']) {
    if (`${row.identity || ''}\n${row.relationship || ''}\n${text || ''}`.includes(label)) aliases.push(label);
  }
  return unique(aliases);
}

function tableCells(line) {
  const value = String(line || '').trim();
  if (!value.includes('|')) return [];
  return value.replace(/^\|/, '').replace(/\|$/, '').split('|').map(item => item.trim());
}

function normalizeColumn(value) {
  const text = String(value || '');
  if (/^角色(?:名)?$|人物/u.test(text)) return 'name';
  if (/性别|称谓|视角身份/u.test(text)) return 'identity';
  if (/年龄|职业|社会位置/u.test(text)) return 'age_job';
  if (/与主角关系|人物关系/u.test(text)) return 'relationship';
  if (/目标|想要/u.test(text)) return 'goal';
  if (/边界|不会做什么/u.test(text)) return 'boundary';
  if (/声口|说话|语言/u.test(text)) return 'voice';
  if (/证据|物件|事件/u.test(text)) return 'evidence';
  return '';
}

function cleanName(value) {
  let text = String(value || '').trim().replace(/[*_`]/g, '');
  text = text.replace(/^[一二三四五六七八九十百]+\s*[、.．]\s*/u, '');
  const rolePrefix = new RegExp(`^${CHARACTER_TITLE_PREFIX.source}\\s*[：:]\\s*(.+)$`, 'u').exec(text);
  if (rolePrefix) text = rolePrefix[1].trim();
  const labelledParts = text.split(/[｜|]/u).map(item => item.trim()).filter(Boolean);
  if (labelledParts.length > 1) {
    const namedPart = labelledParts.find(item => !/^(?:主角|女主|男主|主要压力角色|压力角色|对手|反派|主要阻力|支撑角色|配角|朋友|证人|不可越界)$/u.test(item));
    if (namedPart) text = namedPart;
  }
  text = text.replace(new RegExp(`^${CHARACTER_TITLE_PREFIX.source}\\s+`, 'u'), '');
  const match = text.match(/^([\p{Script=Han}A-Za-z][\p{Script=Han}A-Za-z·]{1,15})(?=\s*[，,（(：:]|\s+\d|$)/u);
  return match ? match[1] : '';
}

function sentence(text, pattern) {
  return String(text || '').split(/(?<=[。！？；\n])/u).map(item => item.trim()).find(item => pattern.test(item)) || '';
}

function compact(value, limit = 220) {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function safeProjectFile(root, relative) {
  if (!relative || path.isAbsolute(relative) || String(relative).split(/[\\/]+/).includes('..')) return '';
  const file = path.resolve(root, relative);
  return file === root || file.startsWith(`${root}${path.sep}`) ? file : '';
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex');
}

function unique(values) {
  return [...new Set((values || []).map(item => String(item || '').trim()).filter(Boolean))];
}

module.exports = {
  analyzeShortCharacterContract,
  parseCharacterProfiles,
  parseCharacterTable,
  projectShortCharacterMemory,
};
