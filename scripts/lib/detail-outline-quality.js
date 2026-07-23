'use strict';

const crypto = require('crypto');

const BASELINE_DIMENSIONS = [
  'B1_causality_action',
  'B2_visible_evidence',
  'B3_continuity_progression',
  'B4_chapter_value_change',
];

const CONDITIONAL_DIMENSIONS = {
  '读者代入': 'C1_reader_immersion',
  '代入': 'C1_reader_immersion',
  '标志场景': 'C2_signature_scene',
  '信息负载': 'C3_information_load',
  '能力切换': 'C4_ability_transition',
  '悬念推进': 'C5_suspense_progression',
  '人物线': 'C6_character_thread',
  '爽点兑现': 'C7_payoff_debt',
};

const CONDITIONAL_DIMENSION_ORDER = [
  'C1_reader_immersion',
  'C2_signature_scene',
  'C3_information_load',
  'C4_ability_transition',
  'C5_suspense_progression',
  'C6_character_thread',
  'C7_payoff_debt',
];

const QUALITY_DIMENSIONS = new Set([
  ...BASELINE_DIMENSIONS,
  ...CONDITIONAL_DIMENSION_ORDER,
]);
const SEMANTIC_SEVERITIES = new Set(['blocking', 'advisory']);

const ABILITY_TRANSITION_CHAIN = [
  { key: 'before', labels: ['触发前状态'] },
  { key: 'trigger', labels: ['触发条件'] },
  { key: 'process', labels: ['过程限制'] },
  { key: 'result', labels: ['结果'] },
  { key: 'cost', labels: ['代价/新限制', '代价', '新限制'] },
];

const ACTION_CONSEQUENCE_CONNECTORS = /因此|于是|导致|迫使|为了|结果|却|但|从而/;
const ABSTRACT_SUMMARY_TERMS = /完成|解决|推进|发生变化/g;
const CONCRETE_ACTION_TERMS = /拿到|获得|保存|截屏|截图|投屏|录音|签字|签下|拒绝|要求|威胁|逼迫|试图|拔线|打开|关上|进入|离开|发现|揭晓|暴露|调查|举起|砸碎|抢走|按下|拔出|拨打|接听|翻开|烧毁|撕开|锁上|解锁|递出|发出|删除|决定|掌握|手机|屏幕|记录|证据|信件|门锁|合同|罚单|账号|文件/;
const CONCRETE_DEMONSTRATION_TERMS = /拿到|获得|保存|截屏|截图|投屏|录音|签字|签下|拒绝|要求|拔线|打开|关上|进入|离开|举起|砸碎|抢走|按下|拔出|拨打|接听|翻开|烧毁|撕开|锁上|解锁|递出|发出|删除|演示|展示|操作|验证|试用/;
const STATE_CHANGE_TERMS = /从.{0,20}(?:转为|变成|变为)|转为|变得|不再|第一次|终于|掌握|失去|获得|拿到|揭晓|发现|决定|改变|升级|下降|上升|建立|暴露|开始追查|进入下一步/;

function sha256Text(text) {
  return crypto.createHash('sha256').update(String(text || ''), 'utf8').digest('hex');
}

function parseDetailOutline(text) {
  const source = String(text || '');
  return {
    source,
    coreEvent: field(source, ['核心事件']),
    targetEmotion: field(source, ['目标情绪']),
    openingHook: field(source, ['开篇钩子']),
    payoff: field(source, ['爽点', '本章兑现']),
    beats: numberedItems(section(source, ['情节安排', '情节点', '节拍'])),
    activationTags: csv(field(source, ['激活标签', '质量触发'])),
    activationReason: field(source, ['激活原因']),
    visibleEvidence: field(source, ['可见证据', '场景证据']),
    previousLink: field(source, ['前置承接', '承接上章']),
    chapterChange: field(source, ['本章变化', '价值变化']),
    futureDebt: field(source, ['后续债务', '后续钩子']),
    chapterPosition: field(source, ['章节位置', '章节阶段', '章位']),
    narrativeContractManaged: hasHeading(source, ['剧情单元合同', '读者体验合同']),
    plotUnitId: field(source, ['剧情单元ID', '剧情单元 Id', '剧情单元 id', '单元ID']),
    beatPosition: field(source, ['单元位置', '单元内位置', 'Beat Position']),
    readerQuestion: field(source, ['本章读者问题', '读者问题']),
    plannedPayoff: field(source, ['本章可见回报', '可见回报', '计划回报']),
    keyTurn: field(source, ['关键转折']),
    netChange: field(source, ['本章净变化', '净变化']),
    inheritedHookResponsibility: field(source, ['继承钩子责任', '钩子责任']),
    terminalReserveAction: field(source, ['终局储备动作', '终局底牌动作']),
  };
}

function activateDimensions(parsed, chapterPosition) {
  const explicit = new Set((parsed.activationTags || [])
    .map(tag => CONDITIONAL_DIMENSIONS[tag])
    .filter(Boolean));
  if (explicit.size) return CONDITIONAL_DIMENSION_ORDER.filter(dimension => explicit.has(dimension));

  const position = normalizeChapterPosition(chapterPosition || parsed.chapterPosition);
  const inferred = new Set();
  if (/(opening|climax|volume[-_ ]?end|开篇|开局|首章|高潮|卷末|卷终)/.test(position)) {
    inferred.add('C2_signature_scene');
  }
  if (/(transition|end|过渡|结尾|章末|收尾)/.test(position)) {
    inferred.add('C5_suspense_progression');
  }
  return CONDITIONAL_DIMENSION_ORDER.filter(dimension => inferred.has(dimension));
}

function normalizeChapterPosition(value) {
  const position = String(value || '').trim().toLowerCase();
  if (!position) return '';
  if (/^(opening|开篇|开局|首章)$/.test(position)) return 'opening';
  if (/^(climax|高潮)$/.test(position)) return 'climax';
  if (/^(volume[-_ ]?end|卷末|卷终)$/.test(position)) return 'volume-end';
  if (/^(transition|过渡)$/.test(position)) return 'transition';
  if (/^(end|结尾|章末|收尾)$/.test(position)) return 'end';
  return position;
}

function evaluateDetailOutline(input) {
  const options = typeof input === 'string' ? { text: input } : (input || {});
  const parsed = parseDetailOutline(options.text);
  const missing = ['coreEvent', 'targetEmotion'].filter(key => !parsed[key]);
  if (parsed.beats.length < 2) missing.push('beats');
  const base = resultBase(options, parsed);

  if (missing.length) {
    return finalize(
      base,
      'outline_underfilled',
      missing.map(key => finding('blocking', 'outline_underfilled', key, `缺少细纲字段：${key}`)),
      false,
    );
  }

  const findings = [
    checkCausality(parsed),
    checkVisibleEvidence(parsed),
    checkContinuity(parsed, options),
    checkChapterChange(parsed),
    ...checkNarrativeContract(base.narrative_contract),
    ...checkConditionalDimensions(parsed, base.activated_dimensions),
  ].flat().filter(Boolean);
  const hasBlocking = findings.some(item => item.severity === 'blocking');
  const status = hasBlocking ? 'revise' : findings.length ? 'pass_with_advisory' : 'pass';
  return finalize(base, status, findings);
}

function mergeSemanticReview(baseResult, semanticReview) {
  const base = baseResult && typeof baseResult === 'object' && !Array.isArray(baseResult) ? baseResult : {};
  const semantic = semanticReview && typeof semanticReview === 'object' && !Array.isArray(semanticReview) ? semanticReview : {};
  const samePath = Boolean(base.outline_path)
    && String(semantic.outline_path || '') === String(base.outline_path);
  const sameHash = /^[0-9a-f]{64}$/.test(String(base.outline_sha256 || ''))
    && String(semantic.outline_sha256 || '') === String(base.outline_sha256);
  if (!samePath || !sameHash) {
    throw qualityError('semantic_review_identity_mismatch', 'semantic review outline_path and outline_sha256 must match the deterministic result');
  }
  if (!Array.isArray(semantic.findings)) {
    throw qualityError('semantic_review_findings_invalid', 'semantic review findings must be an array');
  }
  const reviewer = String(semantic.reviewer || '').trim();
  if (!reviewer) {
    throw qualityError('semantic_review_reviewer_missing', 'semantic review reviewer is required');
  }
  const activatedDimensions = new Set(Array.isArray(base.activated_dimensions) ? base.activated_dimensions : []);

  let ignoredInactiveFindings = 0;
  const semanticFindings = semantic.findings.map((item) => {
    const candidate = item && typeof item === 'object' && !Array.isArray(item) ? item : {};
    const dimension = String(candidate.dimension || '');
    const severity = String(candidate.severity || '');
    if (!QUALITY_DIMENSIONS.has(dimension)) {
      throw qualityError('semantic_review_dimension_invalid', `unsupported semantic review dimension: ${dimension}`);
    }
    if (!SEMANTIC_SEVERITIES.has(severity)) {
      throw qualityError('semantic_review_severity_invalid', `unsupported semantic review severity: ${severity}`);
    }
    if (/^C[1-7]_/.test(dimension) && !activatedDimensions.has(dimension)) {
      ignoredInactiveFindings += 1;
      return null;
    }
    return { ...candidate, dimension, severity };
  }).filter(Boolean);
  const findings = [
    ...(Array.isArray(base.findings) ? base.findings : []),
    ...semanticFindings,
  ];
  const status = findings.some(item => item && item.severity === 'blocking')
    ? 'revise'
    : findings.length > 0 ? 'pass_with_advisory' : 'pass';

  return {
    ...base,
    status,
    findings,
    execution: {
      ...((base.execution && typeof base.execution === 'object') ? base.execution : {}),
      semantic_reviewer: reviewer,
      semantic_review: {
        status: 'accepted',
        reviewer,
        findings: semanticFindings,
        findings_sha256: sha256Text(JSON.stringify(semanticFindings)),
        finding_count: semanticFindings.length,
        ignored_inactive_findings: ignoredInactiveFindings,
      },
    },
  };
}

function qualityError(code, message) {
  const error = new Error(`${code}: ${message}`);
  error.code = code;
  return error;
}

function resultBase(input, parsed) {
  const narrativeContract = buildNarrativeContract(parsed);
  return {
    outline_sha256: sha256Text(parsed.source),
    outline_path: String(input.outlinePath || input.outline_path || ''),
    chapter_position: normalizeChapterPosition(input.chapterPosition || input.chapter_position || parsed.chapterPosition),
    activated_dimensions: activateDimensions(parsed, input.chapterPosition || input.chapter_position),
    activation_tags: parsed.activationTags.slice(),
    baseline_dimensions: BASELINE_DIMENSIONS.slice(),
    findings: [],
    contract_projection: narrativeContract.status === 'complete'
      ? narrativeContractProjection(narrativeContract)
      : [],
    memory_projection: [],
    execution: { mode: 'fresh', reused_result: false },
    parsed_outline: parsed,
    narrative_contract: narrativeContract,
    workflow_id: String(input.workflowId || input.workflow_id || ''),
    stage_id: String(input.stageId || input.stage_id || ''),
  };
}

function buildNarrativeContract(parsed) {
  if (!parsed.narrativeContractManaged) {
    return {
      version: 'longform_narrative_contract_v1',
      status: 'legacy_compatible',
      managed: false,
      plot_unit: { id: '', beat_position: '' },
      reader_experience: {},
      terminal_reserve: { action: '' },
      missing_fields: [],
    };
  }
  const values = {
    plotUnitId: parsed.plotUnitId,
    beatPosition: parsed.beatPosition,
    readerQuestion: parsed.readerQuestion,
    plannedPayoff: parsed.plannedPayoff,
    keyTurn: parsed.keyTurn,
    netChange: parsed.netChange,
    inheritedHookResponsibility: parsed.inheritedHookResponsibility,
    terminalReserveAction: parsed.terminalReserveAction,
  };
  const missingFields = Object.entries(values).filter(([, value]) => !String(value || '').trim()).map(([key]) => key);
  return {
    version: 'longform_narrative_contract_v1',
    status: missingFields.length ? 'incomplete' : 'complete',
    managed: true,
    plot_unit: {
      id: String(parsed.plotUnitId || '').trim(),
      beat_position: String(parsed.beatPosition || '').trim(),
    },
    reader_experience: {
      reader_question: String(parsed.readerQuestion || '').trim(),
      planned_payoff: String(parsed.plannedPayoff || '').trim(),
      key_turn: String(parsed.keyTurn || '').trim(),
      net_change: String(parsed.netChange || '').trim(),
      inherited_hook_responsibility: String(parsed.inheritedHookResponsibility || '').trim(),
    },
    terminal_reserve: { action: String(parsed.terminalReserveAction || '').trim() },
    missing_fields: missingFields,
  };
}

function checkNarrativeContract(contract) {
  if (!contract || contract.status === 'legacy_compatible') return [];
  const findings = (contract.missing_fields || []).map(fieldName => finding(
    'blocking',
    'B5_narrative_contract',
    fieldName,
    `剧情单元合同缺少字段：${fieldName}`,
  ));
  if (contract.plot_unit.id && !/^PU-[A-Za-z0-9_\-一-鿿]+$/.test(contract.plot_unit.id)) {
    findings.push(finding('blocking', 'B5_narrative_contract', 'plotUnitId', '剧情单元ID必须使用 PU- 开头的稳定标识。'));
  }
  if (contract.plot_unit.beat_position && !/^(?:\d+\s*\/\s*\d+|opening|middle|climax|ending|开端|发展|高潮|收束)$/i.test(contract.plot_unit.beat_position)) {
    findings.push(finding('blocking', 'B5_narrative_contract', 'beatPosition', '单元位置应使用 1/4 这类顺序，或开端/发展/高潮/收束。'));
  }
  return findings;
}

function narrativeContractProjection(contract) {
  const reader = contract.reader_experience;
  return [
    `剧情单元ID：${contract.plot_unit.id}`,
    `单元位置：${contract.plot_unit.beat_position}`,
    `本章读者问题：${reader.reader_question}`,
    `本章可见回报：${reader.planned_payoff}`,
    `关键转折：${reader.key_turn}`,
    `本章净变化：${reader.net_change}`,
    `继承钩子责任：${reader.inherited_hook_responsibility}`,
    `终局储备动作：${contract.terminal_reserve.action}`,
  ];
}

function checkConditionalDimensions(parsed, dimensions) {
  return dimensions.map(dimension => {
    if (dimension === 'C1_reader_immersion') return checkReaderImmersion(parsed);
    if (dimension === 'C2_signature_scene') return checkSignatureScene(parsed);
    if (dimension === 'C3_information_load') return checkInformationLoad(parsed);
    if (dimension === 'C4_ability_transition') return checkAbilityTransition(parsed);
    if (dimension === 'C5_suspense_progression') return checkSuspenseProgression(parsed);
    if (dimension === 'C6_character_thread') return checkCharacterThread(parsed);
    if (dimension === 'C7_payoff_debt') return checkPayoffDebt(parsed);
    return null;
  }).filter(Boolean);
}

function checkReaderImmersion(parsed) {
  const text = parsed.source;
  const anchor = /视角|视点|主角|主人公|第一人称|\b我\b/.test(text);
  const consequence = /看到|看见|听到|闻到|感到|意识到|心跳|皱眉|后退|颤抖|反应|感受/.test(text);
  return anchor && consequence ? null : finding('blocking', 'C1_reader_immersion', 'reader_immersion', '读者代入需要视角锚点及至少一个感知或反应后果。');
}

function checkSignatureScene(parsed) {
  const text = parsed.source;
  const namedLocation = /(?:地点|场景|位置|在)[：:\s]*[^\n]{1,24}(?:楼|室|厅|站|街|桥|巷|台|门|仓|馆|园|房|店)|(?:钟楼|天台|车站|医院|办公室|大厅)/.test(text);
  const namedObject = /(?:物件|对象|道具)[：:\s]*\S+|手机|记录|信件|钥匙|合同|账号|屏幕|证据/.test(text);
  const action = countConcreteActionTerms(text) > 0;
  return namedLocation && namedObject && action ? null : finding('blocking', 'C2_signature_scene', 'signature_scene', '标志场景需要可复认的命名地点、对象和行动组合。');
}

function checkInformationLoad(parsed) {
  const knownConcepts = new Set();
  const overloaded = parsed.beats.some(beat => {
    const introduced = namedConcepts(beat).filter(concept => !knownConcepts.has(concept));
    namedConcepts(beat).forEach(concept => knownConcepts.add(concept));
    return introduced.length > 3 && !hasConcreteDemonstration(beat);
  });
  return overloaded ? finding('blocking', 'C3_information_load', 'beats', '单个情节点引入超过三个新命名概念时，需要给出具体演示。') : null;
}

function checkAbilityTransition(parsed) {
  const segments = abilityTransitionSegments(parsed.source);
  const complete = ABILITY_TRANSITION_CHAIN.every((definition, index) => {
    const segment = segments.find(item => item.key === definition.key);
    const previous = index > 0 ? segments.find(item => item.key === ABILITY_TRANSITION_CHAIN[index - 1].key) : null;
    return segment && meaningfulChainValue(segment.value) && (!previous || previous.order < segment.order);
  });
  return complete ? null : finding('blocking', 'C4_ability_transition', 'ability_transition', '能力切换需要触发前状态、触发条件、过程限制、结果及代价或新限制的完整链条。');
}

function checkSuspenseProgression(parsed) {
  const oldQuestion = parsed.previousLink || /旧问题|原问题|此前疑问|承接/.test(parsed.source);
  const progression = parsed.beats.length > 0 && (countConcreteActionTerms(parsed.beats.join('\n')) > 0 || /推进|进展|揭晓|发现/.test(parsed.source));
  const newQuestion = parsed.futureDebt || /新问题|新疑问|悬念|未揭晓|未知/.test(parsed.source);
  return oldQuestion && progression && newQuestion ? null : finding('blocking', 'C5_suspense_progression', 'suspense_progression', '悬念推进需要旧问题、当前推进和新的或变化后的问题。');
}

function checkCharacterThread(parsed) {
  const prior = parsed.previousLink || /此前|之前|原本|前置/.test(parsed.source);
  const pressureOrChoice = /威胁|逼|压力|选择|决定|拒绝|要求|取舍/.test(parsed.source);
  const delta = parsed.chapterChange || /关系|状态变化|转为|变成|改变/.test(parsed.source);
  return prior && pressureOrChoice && delta ? null : finding('blocking', 'C6_character_thread', 'character_thread', '人物线需要此前状态、当前压力或选择，以及章后的关系或状态变化。');
}

function checkPayoffDebt(parsed) {
  const priorDebt = parsed.openingHook || parsed.previousLink || /压力|债务|危机|麻烦/.test(parsed.source);
  const counteraction = /反击|拒绝|揭露|公开|投屏|拿到|获得|解决/.test(parsed.source);
  const consequence = /无法|暴露|当众|结果|后果|改变|得到/.test(parsed.source);
  const remainingDebt = parsed.futureDebt || /尚未|仍未|后续债务|未揭晓/.test(parsed.source);
  return priorDebt && counteraction && consequence && remainingDebt ? null : finding('blocking', 'C7_payoff_debt', 'payoff_debt', '爽点兑现需要既有压力、赢得的反制、页面后果和剩余债务。');
}

function namedConcepts(beat) {
  const text = String(beat || '');
  const named = new Set();
  const structured = /(?:新命名概念|新概念)\s*[：:]\s*(?:[【\[]([^】\]]+)[】\]]|([^；;。！？\n]+))/g;
  for (const match of text.matchAll(structured)) {
    csv(match[1] || match[2]).forEach(item => named.add(item));
  }
  const properName = /《([^》\n]{1,32})》|[「『“"]([^」』”"\n]{1,32})[」』”"]/g;
  for (const match of text.matchAll(properName)) {
    named.add(match[1] || match[2]);
  }
  return [...named];
}

function hasConcreteDemonstration(beat) {
  return CONCRETE_DEMONSTRATION_TERMS.test(String(beat || ''));
}

function abilityTransitionSegments(source) {
  const segments = [];
  let order = 0;
  for (const line of String(source || '').split(/\r?\n/)) {
    for (let part of line.split(/(?:->|→)/)) {
      part = part.trim().replace(/^[-*+]\s*/, '').replace(/^能力切换链\s*[：:]\s*/, '');
      for (const definition of ABILITY_TRANSITION_CHAIN) {
        const labels = definition.labels.map(escapeRegExp).join('|');
        const match = part.match(new RegExp(`^(?:${labels})\\s*[：:]\\s*(.*)$`));
        if (match) segments.push({ key: definition.key, value: match[1].trim(), order: order += 1 });
      }
    }
  }
  return segments;
}

function meaningfulChainValue(value) {
  const normalized = String(value || '').replace(/[。；;，,]/g, '').trim();
  if (!normalized) return false;
  return !ABILITY_TRANSITION_CHAIN.some(definition => definition.labels.includes(normalized));
}

function finalize(base, status, findings) {
  const result = {
    ...base,
    status,
    findings,
  };
  return result;
}

function checkCausality(parsed) {
  if (parsed.beats.length < 2) {
    return finding('blocking', 'B1_causality_action', 'beats', '至少需要两个有序情节点。');
  }
  const beats = parsed.beats.join('\n');
  const hasCausalConnector = ACTION_CONSEQUENCE_CONNECTORS.test(beats);
  const hasConcreteAction = countConcreteActionTerms(beats) > 0;
  if (!hasExecutableActionChain(parsed.beats) && !(hasCausalConnector && hasConcreteAction)) {
    return finding('blocking', 'B1_causality_action', 'beats', '情节点缺少明确的行动或后果连接。');
  }
  return null;
}

function hasExecutableActionChain(beats) {
  return beats.some(beat => /[；;]/.test(beat) && countConcreteActionTerms(beat) >= 2);
}

function countConcreteActionTerms(text) {
  const terms = String(text || '').match(new RegExp(CONCRETE_ACTION_TERMS.source, 'g'));
  return terms ? terms.length : 0;
}

function checkVisibleEvidence(parsed) {
  if (parsed.visibleEvidence) return null;
  const beats = parsed.beats.join('\n');
  const hasConcreteAction = CONCRETE_ACTION_TERMS.test(beats);
  if (hasConcreteAction) return null;
  const abstractCount = (beats.match(ABSTRACT_SUMMARY_TERMS) || []).length;
  if (abstractCount >= 2) {
    return finding('blocking', 'B2_visible_evidence', 'visibleEvidence', '细纲反复使用抽象概述，缺少可落地的场面行动。');
  }
  return finding('advisory', 'B2_visible_evidence', 'visibleEvidence', '尚未明确给出可见证据或具体行动/对象。');
}

function checkContinuity(parsed, input) {
  if (parsed.previousLink || parsed.futureDebt || hasAdjacentHandoff(input)) return null;
  return finding('blocking', 'B3_continuity_progression', 'continuity', '缺少前置承接、后续债务或相邻章节交接。');
}

function checkChapterChange(parsed) {
  if (parsed.chapterChange) return null;
  if (STATE_CHANGE_TERMS.test(parsed.beats.join('\n'))) return null;
  return finding('blocking', 'B4_chapter_value_change', 'chapterChange', '未说明本章变化，情节点中也未识别到状态变化。');
}

function hasAdjacentHandoff(input) {
  const candidates = [
    input.adjacentHandoff,
    input.adjacent_handoff,
    input.workflowMetadata && input.workflowMetadata.adjacentHandoff,
    input.workflowMetadata && input.workflowMetadata.adjacent_handoff,
    input.workflow_metadata && input.workflow_metadata.adjacent_handoff,
    input.metadata && input.metadata.adjacent_handoff,
  ];
  return candidates.some(value => {
    if (Array.isArray(value)) return value.length > 0;
    if (value && typeof value === 'object') return Object.keys(value).length > 0;
    return Boolean(String(value || '').trim());
  });
}

function finding(severity, dimension, fieldName, message) {
  return { dimension, severity, field: fieldName, message };
}

function field(source, labels) {
  const wanted = labels.slice().sort((a, b) => b.length - a.length);
  const pattern = new RegExp(`^\\s*(?:[-*+]\\s*)?(?:#{1,6}\\s*)?(?:${wanted.map(escapeRegExp).join('|')})\\s*(?:[:：]\\s*(.*)|$)`);
  for (const line of source.split(/\r?\n/)) {
    const match = line.match(pattern);
    if (match && match[1]) return match[1].trim();
  }
  return '';
}

function section(source, labels) {
  const wanted = labels.map(label => label.trim());
  const lines = source.split(/\r?\n/);
  let start = -1;
  let level = 0;
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(/^\s*(#{1,6})\s*(.*?)\s*$/);
    if (!match) continue;
    const title = match[2].replace(/[:：].*$/, '').trim();
    if (wanted.some(label => title === label || title.startsWith(`${label} `))) {
      start = index + 1;
      level = match[1].length;
      break;
    }
  }
  if (start < 0) return '';
  let end = lines.length;
  for (let index = start; index < lines.length; index += 1) {
    const match = lines[index].match(/^\s*(#{1,6})\s+/);
    if (match && match[1].length <= level) {
      end = index;
      break;
    }
  }
  return lines.slice(start, end).join('\n');
}

function hasHeading(source, labels) {
  const wanted = labels.map(label => String(label).trim());
  return String(source || '').split(/\r?\n/).some((line) => {
    const match = line.match(/^\s*#{1,6}\s*(.*?)\s*$/);
    if (!match) return false;
    const title = match[1].replace(/[:：].*$/, '').trim();
    return wanted.some(label => title === label || title.startsWith(`${label} `));
  });
}

function numberedItems(text) {
  return String(text || '').split(/\r?\n/)
    .map(line => line.match(/^\s*\d+[.)、]\s*(.+?)\s*$/))
    .filter(Boolean)
    .map(match => match[1]);
}

function csv(value) {
  return String(value || '').split(/[,，、;；]/).map(item => item.trim()).filter(Boolean);
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

module.exports = {
  BASELINE_DIMENSIONS,
  CONDITIONAL_DIMENSIONS,
  activateDimensions,
  evaluateDetailOutline,
  mergeSemanticReview,
  normalizeChapterPosition,
  parseDetailOutline,
  sha256Text,
};
