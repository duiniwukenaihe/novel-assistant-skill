'use strict';

const fs = require('fs');
const path = require('path');

const REQUIRED_ASSETS = Object.freeze(['素材卡.md', '设定.md', '小节大纲.md']);
const REQUIRED_SECTION_SIGNALS = Object.freeze([
  ['structure', /结构功能|结构段|五段功能|承接与场景动作|场景行动/],
  ['emotion', /情绪目标|目标情绪|情绪：|可见阻力与压力变化|压力变化/],
  ['causality', /因果链|因果推进|因果：/],
  ['handoff', /节尾钩子|承接钩子|结尾承接|节尾：|结尾回扣|结尾兑现|代价收束|关系后果、代价与钩子|承接上节/],
]);

const COMMON_STORY_SIGNALS = Object.freeze([
  ['scene_action', /场景动作|可见行动|关键动作/],
  ['protagonist_choice', /角色选择|主角选择|主动选择/],
]);

const MIDDLE_STORY_SIGNALS = Object.freeze([
  ['handoff_in', /承接上节|上节承接/],
  ['pressure_shift', /压力变化|局势起伏|情绪起伏/],
  ['visible_opposition', /可见阻力|对手施压|场景阻力/],
  ['section_payoff', /本节兑现|信息兑现|反转兑现|局势变化/],
  ['relationship_change', /关系变化|人物关系变化/],
  ['cost_escalation', /代价升级|选择代价|即时代价/],
]);

const OPENING_STORY_SIGNALS = Object.freeze([
  ['opening_hook', /开篇钩子|入场钩子/],
  ['story_promise', /故事承诺|核心承诺/],
]);

const CLIMAX_STORY_SIGNALS = Object.freeze([
  ['core_payoff', /核心承诺兑现|核心爆点兑现|高潮兑现/],
  ['decisive_action', /决定性行动|高潮行动/],
  ['immediate_cost', /即时代价|高潮代价|选择代价/],
]);

const ENDING_STORY_SIGNALS = Object.freeze([
  ['handoff_in', /承接上节|上节承接/],
  ['consequences', /现实后果|责任分配|代价收束/],
  ['relationship_closure', /关系收束|人物关系收束/],
  ['theme_callback', /主题回扣|结尾回扣|意义落点/],
]);

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (_) {
    return '';
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function outlineSections(text) {
  const source = String(text || '');
  const heading = /^#{1,6}\s*第\s*0*(\d+)\s*节[^\n]*$/gm;
  const matches = Array.from(source.matchAll(heading));
  return matches.map((match, index) => ({
    number: Number(match[1]),
    body: source.slice(match.index, matches[index + 1] ? matches[index + 1].index : source.length),
  }));
}

function legacyOutlineSectionNumbers(text) {
  const source = String(text || '');
  const numbers = new Set();
  for (const match of source.matchAll(/^#{1,6}\s*节\s*0*(\d+)[^\n]*$/gmu)) numbers.add(Number(match[1]));
  // Earlier short projects commonly used a compact table instead of per-section headings.
  for (const match of source.matchAll(/^\s*\|\s*0*(\d+)\s*\|/gmu)) numbers.add(Number(match[1]));
  return [...numbers].filter((number) => Number.isInteger(number) && number > 0).sort((a, b) => a - b);
}

function detectLegacyPlanShape(outlineText, modernSections, legacySections) {
  if (modernSections.length > 0) return false;
  const source = String(outlineText || '');
  return legacySections.length > 0 || /\|\s*节\s*\|\s*标题|正文\.md|路线重构版/u.test(source);
}

function inferPlannedSections(settingText, state, sections) {
  const fromState = Number((((state || {}).narrative || {}).planned_sections) || 0);
  if (Number.isInteger(fromState) && fromState > 0) return fromState;
  const match = String(settingText || '').match(/(?:共|计划|锁定)\s*(\d+)\s*节|(?:目标|体量)[^\n]{0,40}?\b(\d+)\s*节/u);
  if (match) return Number(match[1] || match[2]);
  return sections.length > 0 ? Math.max(...sections.map((item) => item.number)) : 0;
}

function checkShortPlanContract(projectRoot) {
  const root = path.resolve(projectRoot);
  const findings = [];
  for (const asset of REQUIRED_ASSETS) {
    const file = path.join(root, asset);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile() || !readText(file).trim()) {
      findings.push({ code: 'missing_plan_asset', asset, message: `${asset} 缺失或为空。` });
    }
  }

  const settingText = readText(path.join(root, '设定.md'));
  const outlineText = readText(path.join(root, '小节大纲.md'));
  const state = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const sections = outlineSections(outlineText);
  const outlined = Array.from(new Set(sections.map((item) => item.number))).sort((a, b) => a - b);
  const legacyOutlined = legacyOutlineSectionNumbers(outlineText);
  const legacyPlan = detectLegacyPlanShape(outlineText, sections, legacyOutlined);
  const planned = inferPlannedSections(settingText, state, sections.length ? sections : legacyOutlined.map((number) => ({ number })));
  const current = Number(state.current_section_index || 1);

  if (legacyPlan) {
    findings.push({
      code: 'legacy_plan_migration_required',
      legacy_format: 'table_or_节-number',
      planned_sections: planned,
      detected_sections: legacyOutlined,
      message: '检测到旧版短篇规划结构；先迁移为带锁定节号、节奏模型和逐节因果字段的新合同，禁止直接进入正文全量验收。',
    });
    return {
      schema_version: '1.1.0',
      status: 'legacy_plan_migration_required',
      plan_format: 'legacy',
      migration_required: true,
      planned_sections: planned,
      outlined_sections: legacyOutlined,
      current_section_index: current,
      accepted_sections: Array.isArray(state.accepted_sections) ? state.accepted_sections.length : 0,
      user_confirmed_sections: [],
      remaining_sections: Array.isArray(state.remaining_sections) ? state.remaining_sections : [],
      narrative_quality: { status: 'not_run', findings: [], advisories: [] },
      findings,
    };
  }

  if (!Number.isInteger(planned) || planned < 1) {
    findings.push({ code: 'missing_planned_section_count', message: '设定或项目状态未锁定总小节数。' });
  } else {
    const missing = Array.from({ length: planned }, (_, index) => index + 1).filter((number) => !outlined.includes(number));
    if (missing.length > 0) findings.push({ code: 'missing_outlined_sections', sections: missing, message: `小节大纲缺少第 ${missing.join('、')} 节。` });
    const overflow = outlined.filter((number) => number > planned);
    if (overflow.length > 0) findings.push({ code: 'outline_exceeds_plan', sections: overflow, message: '小节大纲存在尚未纳入总节数锁定的扩容小节。' });
    if (!Number.isInteger(current) || current < 1 || current > planned) {
      findings.push({ code: 'current_section_out_of_range', current_section_index: current, planned_sections: planned, message: '当前小节序号超出已锁定总节数。' });
    }
  }

  for (const section of sections) {
    const missingSignals = REQUIRED_SECTION_SIGNALS.filter(([, pattern]) => !pattern.test(section.body)).map(([name]) => name);
    if (missingSignals.length > 0) {
      findings.push({ code: 'section_blueprint_underfilled', section: section.number, missing_signals: missingSignals, message: `第 ${section.number} 节缺少可写蓝图字段。` });
    }
  }

  const preservedSections = new Set(
    (Array.isArray(state.accepted_sections) ? state.accepted_sections : [])
      .filter((item) => item && item.user_confirmed === true && String(item.source_kind || '') === 'user_confirmed')
      .map((item) => Number(item.section_index || 0))
      .filter((item) => Number.isInteger(item) && item > 0),
  );
  const narrative = analyzeShortOutlineNarrativeQuality(outlineText, planned, { preservedSections });
  findings.push(...narrative.findings);

  if (settingText && !/(第一人称|第三人称|叙事方式|视角)/.test(settingText)) {
    findings.push({ code: 'missing_pov_lock', message: '设定未锁定叙事视角。' });
  }
  if (settingText && !/(主节奏|节奏模型|节奏：)/.test(settingText)) {
    findings.push({ code: 'missing_rhythm_lock', message: '设定未锁定短篇节奏模型。' });
  }

  return {
    schema_version: '1.1.0',
    plan_format: 'current',
    migration_required: false,
    status: findings.length > 0 ? 'blocked' : 'current',
    planned_sections: planned,
    outlined_sections: outlined,
    current_section_index: current,
    accepted_sections: Array.isArray(state.accepted_sections) ? state.accepted_sections.length : 0,
    user_confirmed_sections: [...preservedSections].sort((a, b) => a - b),
    remaining_sections: Array.isArray(state.remaining_sections) ? state.remaining_sections : [],
    narrative_quality: narrative,
    findings,
  };
}

function analyzeShortOutlineNarrativeQuality(outlineText, plannedSections = 0, options = {}) {
  const rawSections = outlineSections(outlineText);
  const sectionGroups = new Map();
  for (const section of rawSections) {
    const group = sectionGroups.get(section.number) || [];
    group.push(section);
    sectionGroups.set(section.number, group);
  }
  // A duplicated heading is a planning conflict, but each section should still
  // produce only one diagnostic card. The last occurrence is the latest staged
  // revision and is used for the remaining checks.
  const sections = [...sectionGroups.values()]
    .map((group) => group[group.length - 1])
    .sort((left, right) => left.number - right.number);
  const planned = Number.isInteger(Number(plannedSections)) && Number(plannedSections) > 0
    ? Number(plannedSections)
    : (sections.length ? Math.max(...sections.map((item) => item.number)) : 0);
  const findings = [];
  const advisories = [];
  const sectionRoles = [];
  const signalMappings = [];
  const preservedSections = options.preservedSections instanceof Set
    ? options.preservedSections
    : new Set(Array.isArray(options.preservedSections) ? options.preservedSections.map(Number) : []);
  for (const [sectionNumber, group] of sectionGroups) {
    if (group.length <= 1) continue;
    findings.push({
      code: 'duplicate_section_outline',
      section: sectionNumber,
      occurrences: group.length,
      protected_user_confirmed: preservedSections.has(sectionNumber),
      message: `第 ${sectionNumber} 节在小节大纲中重复出现 ${group.length} 次；请合并为一个权威版本。`,
    });
  }
  for (const section of sections) {
    const role = sectionRole(section.number, planned);
    const preserved = preservedSections.has(section.number);
    sectionRoles.push({ section: section.number, role, preserved_user_confirmed: preserved });
    const required = [
      ...COMMON_STORY_SIGNALS,
      ...(role === 'opening' ? OPENING_STORY_SIGNALS : []),
      ...(role === 'middle' ? MIDDLE_STORY_SIGNALS : []),
      ...(role === 'climax' ? [...MIDDLE_STORY_SIGNALS, ...CLIMAX_STORY_SIGNALS] : []),
      ...(role === 'ending' ? ENDING_STORY_SIGNALS : []),
    ];
    const events = numberedEvents(section.body);
    const previous = sections.find((item) => item.number === section.number - 1) || null;
    const resolved = required.map(([name, pattern]) => ({ name, ...resolveNarrativeSignal({ name, pattern, section, previous, outlineText, events }) }));
    const missing = resolved.filter((item) => !item.matched).map((item) => item.name);
    signalMappings.push({
      section: section.number,
      mapped_aliases: resolved.filter((item) => item.matched && item.source !== 'exact_field').map((item) => ({ signal: item.name, source: item.source })),
    });
    const eventCount = events.length;
    if (eventCount < 2) missing.push('causal_events');
    const evidenceRun = longestEvidenceOnlyRun(events);
    if (evidenceRun >= 3 && !hasLiveSceneCollision(section.body, events)) missing.push('live_scene_collision');
    if (missing.length) {
      const finding = {
        code: 'section_narrative_engine_underfilled',
        section: section.number,
        role,
        protected_user_confirmed: preserved,
        missing_signals: [...new Set(missing)],
        evidence_only_run: evidenceRun,
        message: `第 ${section.number} 节只有信息顺序，尚未形成可执行的故事引擎；连续查表、看文件或解释记录不能代替人物碰撞。`,
      };
      findings.push(finding);
    }
  }
  const chain = analyzeHookAndPressureChain(sections, preservedSections);
  findings.push(...chain.findings);
  advisories.push(...chain.advisories);
  return {
    schema_version: '1.0.0',
    status: findings.length ? 'blocked' : 'pass',
    planned_sections: planned,
    section_roles: sectionRoles,
    signal_mappings: signalMappings,
    findings,
    advisories,
  };
}

function resolveNarrativeSignal({ name, pattern, section, previous, outlineText, events }) {
  const body = String(section.body || '');
  if (pattern.test(body)) return { matched: true, source: 'exact_field' };
  const structure = labeledValue(body, ['结构功能']);
  const mainEvent = labeledValue(body, ['主事件']);
  const emotion = labeledValue(body, ['情绪', '情绪目标', '目标情绪']);
  const causality = labeledValue(body, ['因果链', '因果推进']);
  const choice = labeledValue(body, ['角色选择', '主角选择', '主动选择']);
  const eventText = events.join('；');
  const combined = `${structure}；${mainEvent}；${causality}；${choice}；${eventText}`;
  switch (name) {
    case 'scene_action':
      return result(Boolean(mainEvent || events.length >= 2), mainEvent ? '主事件' : '子事件');
    case 'protagonist_choice':
      return result(/(?:她|他|主角)[^。；\n]{0,36}(?:选择|拒绝|提交|投票|公开|承认|追查|保留|暂不|不接|撤回|启动)/u.test(combined), '角色行动');
    case 'opening_hook':
      return result(/黄金开篇|开篇/u.test(structure) && events.length >= 1, '结构功能+子事件');
    case 'story_promise':
      return result(/核心路线|核心判断翻转|故事核|核心承诺/u.test(outlinePreamble(outlineText)), '全篇核心路线');
    case 'handoff_in': {
      const previousHook = previous ? labeledValue(previous.body, ['节尾钩子', '结尾回扣', '代价收束']) : '';
      const incoming = `${causality}；${events[0] || ''}`;
      return result(Boolean(previousHook && storySignalOverlap(previousHook, incoming) >= 0.08), '前节钩子+本节因果');
    }
    case 'pressure_shift':
      return result(Boolean(emotion && /->|→|到|转为|转向|骤然|逐渐|后/u.test(emotion)), '情绪变化');
    case 'visible_opposition':
      return result(/逼|要求|拒绝|质问|施压|阻止|停用|撤回|围住|交换|控制|迫使|断播|不让|威胁/u.test(combined), '事件冲突');
    case 'section_payoff':
      return result(/发现|确认|承认|公开|揭露|证明|闭合|落地|暴露|认错|兑现|击穿|查到|看见/u.test(combined), '事件兑现');
    case 'relationship_change':
      return result(/关系后果|关系收束/u.test(body) || (/(?:哥哥|母亲|唐禾|家人|员工)/u.test(body) && /信任|控制|牺牲|拒绝|决裂|裂痕|逼|交换|知情|沉默|甩锅|心寒|保护/u.test(body)), '关系后果/人物碰撞');
    case 'cost_escalation':
    case 'immediate_cost':
      return result(/选择代价|现实后果|责任分配|失去|停用|取消|缩水|辞去|决裂|承担|追究|退款|问询|责任|风险|损失|工资压力/u.test(body), '代价/后果');
    case 'core_payoff':
      return result(/高潮|公开纠错|核心.*兑现|核心不是/u.test(`${structure}；${mainEvent}`) && /公开|提交|撤回|召回|认错/u.test(eventText), '高潮结构+决定性事件');
    case 'decisive_action':
      return result(/提交|公开|投票|召回|撤回|拒绝|暂停|启动|认错/u.test(`${choice}；${eventText}`), '角色选择+子事件');
    case 'consequences':
      return result(/责任分配|召回|停产|退款|停职|缩水|辞去/u.test(body), '责任/后果');
    case 'relationship_closure':
      return result(/关系收束|保持裂痕|决裂|不.*和解/u.test(body), '关系收束');
    case 'theme_callback':
      return result(/结尾回扣|意义落点|主题/u.test(body), '结尾回扣');
    default:
      return { matched: false, source: '' };
  }
}

function result(matched, source) {
  return { matched: Boolean(matched), source: matched ? source : '' };
}

function hasLiveSceneCollision(body, events) {
  return /当面|反问|质问|逼|要求|拒绝|围住|递来|加入谈话|亲自来到|断播|争执|交换/u.test(`${String(body || '')}\n${events.join('\n')}`);
}

function outlinePreamble(value) {
  const source = String(value || '');
  const firstSection = source.search(/^#{1,6}\s*第\s*0*\d+\s*节[^\n]*$/mu);
  return firstSection >= 0 ? source.slice(0, firstSection) : source;
}

function analyzeHookAndPressureChain(sections, preservedSections) {
  const findings = [];
  const advisories = [];
  const ordered = sections.slice().sort((a, b) => a.number - b.number);
  const seenHooks = new Map();
  const seenPayoffs = new Map();
  for (const section of ordered) {
    const protectedCurrent = preservedSections.has(section.number);
    const hook = labeledValue(section.body, ['节尾钩子', '结尾回扣', '代价收束']);
    const payoff = labeledValue(section.body, ['本节兑现', '信息兑现', '反转兑现', '局势变化']);
    const pressure = labeledValue(section.body, ['压力变化', '局势起伏', '情绪起伏']);
    const hookKey = normalizeStorySignal(hook);
    const payoffKey = normalizeStorySignal(payoff);
    if (hookKey && seenHooks.has(hookKey)) {
      addChainFinding({ findings, protectedCurrent, finding: { code: 'section_hook_repeated', section: section.number, previous_section: seenHooks.get(hookKey), message: '后续小节重复使用同一个节尾钩子，剧情没有形成新的未决问题。' } });
    } else if (hookKey) seenHooks.set(hookKey, section.number);
    if (payoffKey && seenPayoffs.has(payoffKey)) {
      addChainFinding({ findings, protectedCurrent, finding: { code: 'section_payoff_repeated', section: section.number, previous_section: seenPayoffs.get(payoffKey), message: '多个小节重复兑现同一件事，剧情起伏停滞。' } });
    } else if (payoffKey) seenPayoffs.set(payoffKey, section.number);

    if (pressure && !pressureActuallyChanges(pressure)) {
      addChainFinding({ findings, protectedCurrent, finding: { code: 'section_pressure_change_unclear', section: section.number, message: '压力字段只描述当前状态，没有说明压力如何升高、反转或释放，无法形成可感知的剧情起伏。' } });
    }

    if (section.number <= 1) continue;
    const previous = ordered.find((item) => item.number === section.number - 1);
    if (!previous) continue;
    const previousHook = labeledValue(previous.body, ['节尾钩子', '结尾回扣', '代价收束']);
    const handoff = labeledValue(section.body, ['承接上节', '上节承接']);
    if (previousHook && handoff && storySignalOverlap(previousHook, handoff) < 0.2) {
      addChainFinding({ findings, protectedCurrent, finding: {
        code: 'section_hook_handoff_disconnected',
        section: section.number,
        previous_section: previous.number,
        previous_hook_anchor: hookAnchorId(previous.number),
        incoming_hook_anchor: hookAnchorId(previous.number),
        message: `第 ${section.number} 节没有实际承接第 ${previous.number} 节留下的钩子；不得另起一条无关调查线。`,
      } });
    }
  }
  return { findings, advisories };
}

function addChainFinding({ findings, protectedCurrent, finding }) {
  findings.push({ ...finding, protected_user_confirmed: protectedCurrent });
}

function pressureActuallyChanges(value) {
  return /升|加剧|收紧|逼近|转为|转向|转入|反转|翻转|爆发|释放|缓和|降低|落地|收束|失控|公开|从.+到/u.test(String(value || ''));
}

function hookAnchorId(sectionNumber) {
  return `H${String(Number(sectionNumber || 0)).padStart(3, '0')}`;
}

function sectionRole(sectionNumber, plannedSections) {
  if (sectionNumber === 1) return 'opening';
  if (plannedSections > 2 && sectionNumber === plannedSections - 1) return 'climax';
  if (plannedSections > 1 && sectionNumber === plannedSections) return 'ending';
  return 'middle';
}

function numberedEvents(body) {
  const lines = String(body || '').split(/\r?\n/u);
  const start = lines.findIndex((line) => /^\s*[-*]\s*子事件\s*[：:]?\s*$/u.test(line));
  const events = [];
  if (start >= 0) {
    for (let index = start + 1; index < lines.length; index += 1) {
      if (/^\s*[-*]\s*[^\s].*[：:]/u.test(lines[index])) break;
      const match = lines[index].match(/^\s*\d+[.、)]\s*(\S.*)$/u);
      if (match) events.push(match[1].trim());
    }
  }
  if (events.length >= 2) return events;

  const inline = labeledValue(body, ['因果链', '因果事件', '场景事件', '子事件']);
  if (!inline) return events;
  const chained = inline
    .split(/\s*(?:→|->|=>|⇒|；|;)\s*/u)
    .map((item) => item.trim())
    .filter(Boolean);
  return chained.length >= 2 ? chained : events;
}

function longestEvidenceOnlyRun(events) {
  const evidencePattern = /资料|文件|记录|档案|表格|邮件|编号|批号|附件|回执|清单|页面|系统|投料单|凭证/u;
  let longest = 0;
  let current = 0;
  for (const event of events) {
    if (evidencePattern.test(String(event || ''))) {
      current += 1;
      longest = Math.max(longest, current);
    } else {
      current = 0;
    }
  }
  return longest;
}

function labeledValue(body, labels) {
  for (const label of labels) {
    const escaped = label.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
    const match = String(body || '').match(new RegExp(`^\\s*[-*]\\s*${escaped}\\s*[：:]\\s*(.+?)\\s*$`, 'mu'));
    if (match) return match[1].trim();
  }
  return '';
}

function normalizeStorySignal(value) {
  return String(value || '').replace(/[\s，。；：、“”‘’《》【】（）()\-—_]/gu, '');
}

function storySignalOverlap(left, right) {
  const a = normalizeStorySignal(left);
  const b = normalizeStorySignal(right);
  if (!a || !b) return 0;
  if (a.includes(b) || b.includes(a)) return 1;
  const aPairs = ngrams(a, 2);
  const bPairs = ngrams(b, 2);
  const overlap = [...aPairs].filter((item) => bPairs.has(item)).length;
  return overlap / Math.max(1, Math.min(aPairs.size, bPairs.size));
}

function ngrams(text, size) {
  const output = new Set();
  for (let index = 0; index <= text.length - size; index += 1) output.add(text.slice(index, index + size));
  return output;
}

module.exports = {
  analyzeShortOutlineNarrativeQuality,
  checkShortPlanContract,
  inferPlannedSections,
  outlineSections,
  sectionRole,
  hookAnchorId,
};
