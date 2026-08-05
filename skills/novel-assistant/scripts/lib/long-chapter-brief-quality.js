'use strict';

function inspectLongChapterBriefBudget(text, options = {}) {
  const source = String(text || '');
  const beatWords = [];
  const declaredTotals = [];
  for (const line of source.split(/\r?\n/)) {
    const cells = markdownTableCells(line);
    if (cells.length < 2) continue;
    const first = stripMarkdown(cells[0]);
    const lastNumber = positiveInt(stripMarkdown(cells[cells.length - 1]));
    if (/^\d+$/.test(first) && lastNumber) beatWords.push(lastNumber);
    if (/(?:合计|总计|total)/i.test(first) && lastNumber) declaredTotals.push(lastNumber);
  }
  const beatTotal = beatWords.reduce((sum, value) => sum + value, 0);
  const declaredTotal = declaredTotals[0] || 0;
  const budgetApplicable = beatWords.length >= 2 && declaredTotal > 0;
  const beatCount = beatWords.length >= 2 ? beatWords.length : countPrimarySemanticBeats(source);
  const target = resolveTargetWords(source, options, declaredTotal);
  const briefCjk = countCjk(source);
  const briefTargetRatio = target.words > 0 ? round(briefCjk / target.words, 3) : 0;
  const averageWordsPerBeat = target.words > 0 && beatCount > 0
    ? Math.floor(target.words / beatCount)
    : 0;
  const findings = [];

  if (budgetApplicable && beatTotal !== declaredTotal) {
    findings.push({
      code: 'brief_beat_total_mismatch',
      message: `逐拍字数相加为 ${beatTotal}，但 Brief 合计栏声明为 ${declaredTotal}；请先统一预算再进入正文。`,
    });
  }

  if (target.words > 0) {
    const ratio = briefCjk / target.words;
    if (ratio > 0.55) {
      findings.push({
        code: 'brief_compactness_excessive',
        message: `Brief 约为目标正文的 ${Math.round(ratio * 100)}%，超过 55% 上限；请保留唯一情节点与约束，合并重复叙述后重新审阅。`,
      });
    } else if (ratio > 0.45) {
      findings.push({
        code: 'brief_compactness_above_target',
        message: `Brief 约为目标正文的 ${Math.round(ratio * 100)}%，超过 45% 紧凑度目标；请自动压缩重复说明后重新审阅。`,
      });
    }
    if (beatCount > 0 && target.words / beatCount < 150) {
      findings.push({
        code: 'brief_beat_density_too_high',
        message: `目标正文平均每个主要情节点仅 ${averageWordsPerBeat} 字，低于 150 字；请合并情节点或拆分章节。`,
      });
    }
  } else if (briefCjk > 1800) {
    findings.push({
      code: 'brief_compactness_target_missing_excessive',
      message: `Brief 未提供可验证的目标正文字数，且已达到 ${briefCjk} 个 CJK 字符；请补齐目标或先压缩至 1800 个 CJK 字符以内。`,
    });
  }

  const compactnessApplicable = target.source === 'structured_target' || findings.length > 0;
  return {
    status: findings.length > 0 ? 'revise' : (budgetApplicable || compactnessApplicable ? 'pass' : 'not_applicable'),
    beat_total: beatTotal,
    declared_total: declaredTotal,
    beat_count: beatCount,
    target_words: target.words,
    target_source: target.source,
    brief_cjk: briefCjk,
    brief_bytes: Buffer.byteLength(source, 'utf8'),
    brief_lines: source.split(/\r?\n/).length,
    brief_target_ratio: briefTargetRatio,
    average_words_per_beat: averageWordsPerBeat,
    findings,
  };
}

function resolveTargetWords(text, options, declaredTotal) {
  const structured = positiveNumber((options || {}).targetWords != null
    ? options.targetWords
    : (options || {}).target_words);
  if (structured) return { words: structured, source: 'structured_target' };

  const source = String(text || '');
  const exact = source.match(/(?:字数目标|目标字数)\s*[:：]\s*(\d{3,6})\s*(?=[（(])/);
  if (exact) return { words: Number(exact[1]), source: 'brief_nominal_target' };
  const range = source.match(/(?:字数目标|目标字数)\s*[:：]\s*(\d{3,6})\s*[-—~至]\s*(\d{3,6})/);
  if (range) return { words: Math.round((Number(range[1]) + Number(range[2])) / 2), source: 'brief_target_range' };
  const single = source.match(/(?:字数目标|目标字数)\s*[:：]\s*(\d{3,6})/);
  if (single) return { words: Number(single[1]), source: 'brief_nominal_target' };
  if (declaredTotal > 0) return { words: declaredTotal, source: 'declared_beat_total' };
  return { words: 0, source: 'missing' };
}

function countPrimarySemanticBeats(text) {
  const lines = String(text || '').split(/\r?\n/);
  let start = -1;
  let level = 0;
  for (let index = 0; index < lines.length; index += 1) {
    const heading = lines[index].match(/^(#{2,6})\s+(.+)$/);
    if (!heading || !/(?:必须交付|must[- ]?have|beat sheet|逐拍执行)/i.test(heading[2])) continue;
    start = index + 1;
    level = heading[1].length;
    break;
  }
  if (start < 0) return 0;

  const ids = new Set();
  for (let index = start; index < lines.length; index += 1) {
    const heading = lines[index].match(/^(#{1,6})\s+/);
    if (heading && heading[1].length <= level) break;
    let match = lines[index].match(/^\s*(?:[-*+]\s+|\|\s*)(?:\*\*)?B0*(\d{1,3})\b/i);
    if (!match) match = lines[index].match(/^\s*(\d{1,3})[.、]\s+/);
    if (!match) match = lines[index].match(/^\|\s*0*(\d{1,3})\s*\|/);
    if (match) ids.add(Number(match[1]));
  }
  return ids.size;
}

function countCjk(value) {
  return (String(value || '').match(/\p{Script=Han}/gu) || []).length;
}

function positiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? Math.round(number) : 0;
}

function round(value, digits) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function markdownTableCells(line) {
  const value = String(line || '').trim();
  if (!value.startsWith('|') || !value.endsWith('|')) return [];
  return value.slice(1, -1).split('|').map((cell) => cell.trim());
}

function stripMarkdown(value) {
  return String(value || '').replace(/[*_`~]/g, '').trim();
}

function positiveInt(value) {
  const match = String(value || '').match(/^\s*(\d+)\s*$/);
  const number = match ? Number(match[1]) : 0;
  return Number.isInteger(number) && number > 0 ? number : 0;
}

module.exports = { inspectLongChapterBriefBudget };
