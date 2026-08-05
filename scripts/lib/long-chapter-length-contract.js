'use strict';

const crypto = require('crypto');

function parseLongChapterLengthContract(source) {
  const text = String(source || '');
  const range = text.match(/(?:合法区间|字数区间|篇幅区间)\s*[:：]?\s*([0-9]+)\s*(?:-|~|—|–|至|到)\s*([0-9]+)/u);
  const targetMatch = text.match(/(?:字数目标|目标字数|篇幅目标)\s*[:：]?\s*([0-9]+)/u);
  const target = targetMatch ? Number(targetMatch[1]) : 0;
  if (range) {
    const min = Number(range[1]);
    const max = Number(range[2]);
    if (min > 0 && max >= min) return { status: 'parsed', target, min, max, source: 'explicit_range' };
  }
  if (target > 0) {
    return {
      status: 'parsed',
      target,
      min: Math.ceil(target * 0.9),
      max: Math.floor(target * 1.2),
      source: 'target_tolerance',
    };
  }
  return { status: 'missing', target: 0, min: 0, max: 0, source: '' };
}

function countCjkCharacters(source) {
  return (String(source || '').match(/[\u3400-\u9fff]/gu) || []).length;
}

function evaluateLongChapterLength(contractSource, proseSource) {
  const contract = parseLongChapterLengthContract(contractSource);
  const cjkChars = countCjkCharacters(proseSource);
  if (contract.status !== 'parsed') {
    return {
      ...contract,
      status: 'blocking',
      reason_code: 'length_contract_missing',
      cjk_chars: cjkChars,
      message: '章节 Brief 缺少可执行的目标字数或合法区间，不能验收正文。',
    };
  }
  const inRange = cjkChars >= contract.min && cjkChars <= contract.max;
  return {
    ...contract,
    status: inRange ? 'pass' : 'blocking',
    reason_code: inRange ? '' : cjkChars < contract.min ? 'chapter_underlength' : 'chapter_overlength',
    cjk_chars: cjkChars,
    message: inRange
      ? `正文 ${cjkChars} 个中文字符，位于合法区间 ${contract.min}—${contract.max}。`
      : `正文 ${cjkChars} 个中文字符，不在合法区间 ${contract.min}—${contract.max}；请只回炉当前章正文。`,
  };
}

function chapterProseDigest(source) {
  return `sha256:${crypto.createHash('sha256').update(String(source || ''), 'utf8').digest('hex')}`;
}

function buildLongChapterAcceptanceBinding(contractSource, proseSource, candidatePath) {
  const length = evaluateLongChapterLength(contractSource, proseSource);
  if (length.status !== 'pass') {
    return {
      status: 'blocking',
      reason_code: length.reason_code,
      candidate_path: String(candidatePath || ''),
      candidate_sha256: chapterProseDigest(proseSource),
      length_contract: length,
    };
  }
  return {
    schema_version: 'long_chapter_acceptance_binding_v1',
    status: 'bound',
    candidate_path: String(candidatePath || ''),
    candidate_sha256: chapterProseDigest(proseSource),
    length_contract: length,
  };
}

function validateLongChapterAcceptanceBinding(binding, contractSource, proseSource, candidatePath) {
  const current = buildLongChapterAcceptanceBinding(contractSource, proseSource, candidatePath);
  if (!binding || String(binding.schema_version || '') !== 'long_chapter_acceptance_binding_v1') {
    return { ...current, status: 'stale', reason_code: 'acceptance_binding_missing' };
  }
  if (String(binding.candidate_path || '') !== String(candidatePath || '')) {
    return { ...current, status: 'stale', reason_code: 'candidate_path_mismatch' };
  }
  if (String(binding.candidate_sha256 || '') !== current.candidate_sha256) {
    return { ...current, status: 'stale', reason_code: 'candidate_digest_mismatch' };
  }
  if (current.status !== 'bound') return current;
  return { ...current, status: 'current', reason_code: '' };
}

function isLengthEvidence(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const descriptor = ['check', 'kind', 'item', 'code', 'metric', 'rule']
    .map((key) => String(value[key] || ''))
    .join(' ');
  return /(?:word[_ -]?count|body[_ -]?length|chapter[_ -]?length|machine_gate_word_count|(?:^|\s)length(?:$|\s)|字数|字符数|汉字数)/iu.test(descriptor);
}

function stripModelLengthEvidence(value) {
  if (Array.isArray(value)) {
    return value
      .filter((item) => !isLengthEvidence(item))
      .map(stripModelLengthEvidence);
  }
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).map(([key, nested]) => [key, stripModelLengthEvidence(nested)]));
}

function normalizeLengthClaimText(value, length) {
  const source = String(value || '');
  if (!/(?:字数|字符|汉字)/u.test(source)) return source;
  return source
    .replace(/(?:约\s*)?[0-9]+\s*(?:个)?(?:中文字符|汉字|字符|字)/gu, `${length.cjk_chars} 个中文字符`)
    .replace(/(?:合法区间|细纲约束|篇幅区间|字数区间)?\s*[0-9]+\s*(?:-|~|—|–|至|到)\s*[0-9]+\s*(?:区间)?/gu, `合法区间 ${length.min}—${length.max}`);
}

function normalizeLongChapterLengthEvidence(packet, binding) {
  const length = binding && binding.length_contract;
  if (!packet || typeof packet !== 'object' || !length || length.status !== 'pass') return packet;
  const remaining = stripModelLengthEvidence(Array.isArray(packet.evidence) ? packet.evidence : []);
  packet.evidence = [{
    check: 'chapter_length',
    source: 'deterministic_binding',
    result: 'pass',
    metric: 'cjk_chars',
    actual_cjk_chars: Number(length.cjk_chars || 0),
    target: Number(length.target || 0),
    allowed_min: Number(length.min || 0),
    allowed_max: Number(length.max || 0),
    note: String(length.message || ''),
  }, ...remaining];
  for (const field of ['handoff_summary', 'summary', 'blocking_reason', 'next_recommendation']) {
    if (typeof packet[field] === 'string') packet[field] = normalizeLengthClaimText(packet[field], length);
  }
  return packet;
}

module.exports = {
  buildLongChapterAcceptanceBinding,
  chapterProseDigest,
  countCjkCharacters,
  evaluateLongChapterLength,
  normalizeLongChapterLengthEvidence,
  parseLongChapterLengthContract,
  validateLongChapterAcceptanceBinding,
};
