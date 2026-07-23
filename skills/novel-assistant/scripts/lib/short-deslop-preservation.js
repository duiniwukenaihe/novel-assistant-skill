'use strict';

const SCHEMA_VERSION = '1.0.0';

function countCjk(value) {
  return (String(value || '').match(/[\u3400-\u9fff]/gu) || []).length;
}

function splitSections(value) {
  const source = String(value || '');
  const matches = [...source.matchAll(/^##\s+第\s*0*(\d+)\s*节(?:\s+([^\n]+))?\s*$/gmu)];
  return matches.map((match, index) => ({
    section_index: Number(match[1]),
    title: String(match[2] || '').trim(),
    body: source.slice(match.index + match[0].length, matches[index + 1] ? matches[index + 1].index : source.length).trim(),
  }));
}

function preservationCheck(sourceText, revisedText, options = {}) {
  const sourceSections = splitSections(sourceText);
  const revisedSections = splitSections(revisedText);
  const findings = [];
  const advisories = [];
  const metrics = [];
  const revisedByIndex = new Map(revisedSections.map(section => [section.section_index, section]));

  if (!sourceSections.length || sourceSections.length !== revisedSections.length) {
    findings.push({
      code: 'section_structure_changed',
      message: '去 AI 味前后的小节数量不一致。',
      before: sourceSections.map(section => section.section_index),
      after: revisedSections.map(section => section.section_index),
    });
  }

  for (const source of sourceSections) {
    const revised = revisedByIndex.get(source.section_index);
    if (!revised) continue;
    const before = countCjk(source.body);
    const after = countCjk(revised.body);
    const removed = Math.max(0, before - after);
    const retainedRatio = before ? after / before : 1;
    const advisoryAllowance = Math.max(220, Math.round(before * 0.15));
    const blockingAllowance = Math.max(350, Math.round(before * 0.22));
    const row = {
      section_index: source.section_index,
      title: source.title,
      before_cjk_chars: before,
      after_cjk_chars: after,
      removed_cjk_chars: removed,
      retained_ratio: Number(retainedRatio.toFixed(3)),
      advisory_allowance: advisoryAllowance,
      blocking_allowance: blockingAllowance,
    };
    metrics.push(row);
    if (removed > blockingAllowance) {
      findings.push({
        code: 'section_material_loss',
        section_index: source.section_index,
        message: `第${source.section_index}节删减幅度过大，可能丢失动作、反应、后果或承接。`,
        ...row,
      });
    } else if (removed > advisoryAllowance) {
      advisories.push({
        code: 'section_shrink_advisory',
        section_index: source.section_index,
        message: `第${source.section_index}节缩短较明显，最终检查需关注剧情功能是否仍完整。`,
        ...row,
      });
    }
  }

  const beforeTotal = countCjk(sourceText);
  const afterTotal = countCjk(revisedText);
  const totalRemoved = Math.max(0, beforeTotal - afterTotal);
  const totalAllowance = Math.max(600, Math.round(beforeTotal * 0.12));
  const materiallyShrunkSections = metrics.filter(row => row.removed_cjk_chars > row.advisory_allowance);
  if (totalRemoved > totalAllowance && materiallyShrunkSections.length >= 2) {
    findings.push({
      code: 'whole_story_material_loss',
      message: '全篇累计删减较大，且影响多个小节；不能把它当作普通表达清理直接提交。',
      before_cjk_chars: beforeTotal,
      after_cjk_chars: afterTotal,
      removed_cjk_chars: totalRemoved,
      affected_sections: materiallyShrunkSections.map(row => row.section_index),
      allowance: totalAllowance,
    });
  }

  const exceptionReason = String(options.exceptionReason || '').trim();
  const exceptionAccepted = findings.length > 0 && exceptionReason.length >= 8;
  return {
    schemaVersion: SCHEMA_VERSION,
    status: findings.length === 0 ? 'pass' : (exceptionAccepted ? 'explicit_exception' : 'revision_required'),
    blocking: findings.length > 0 && !exceptionAccepted,
    before_cjk_chars: beforeTotal,
    after_cjk_chars: afterTotal,
    removed_cjk_chars: totalRemoved,
    retained_ratio: beforeTotal ? Number((afterTotal / beforeTotal).toFixed(3)) : 1,
    section_metrics: metrics,
    findings,
    advisories,
    exception_reason: exceptionAccepted ? exceptionReason : '',
    repair_principle: '只补回因去 AI 味误删的剧情功能、人物反应、行动后果和跨节承接；不按差额机械补字，不恢复已确认的 AI 套话。',
  };
}

module.exports = { countCjk, preservationCheck, splitSections };
