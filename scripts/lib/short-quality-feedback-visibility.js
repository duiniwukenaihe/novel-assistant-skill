'use strict';

const QUALITY_LABELS = Object.freeze({
  causal_progression: '因果推进',
  protagonist_agency: '主角行动',
  emotional_tension: '情绪张力',
  reader_pull: '继续阅读动力',
  professional_reader_milestone: '读者体验',
});

function qualityFindingLabel(finding = {}) {
  const code = String(finding.code || '');
  return String(finding.label || QUALITY_LABELS[code] || (code.startsWith('outline_') ? '大纲兑现' : '质量判断'));
}

function qualityFindingMessage(finding = {}) {
  const code = String(finding.code || 'quality_revision');
  const message = String(finding.message || '').trim();
  return !message || message === `${code} 需要修订` ? '当前内容尚未完成这一项。' : message;
}

function renderQualityFindings(findings = []) {
  return (Array.isArray(findings) ? findings : []).map(finding =>
    `${qualityFindingLabel(finding)}：${qualityFindingMessage(finding)}`
  ).join('；');
}

function normalizeLegacyQualityFeedbackText(value) {
  const text = String(value || '').trim();
  if (!/(?:causal_progression|protagonist_agency|emotional_tension|reader_pull|outline_[A-Z0-9]+|professional_reader_milestone)/u.test(text)) return text;
  const lines = text.split(/\r?\n/u).map(line => line.trim()).filter(Boolean);
  const detail = lines.find(line => /^(?:未通过项|需要处理)：/u.test(line)) || '';
  const codes = [...detail.matchAll(/(?:^|[：；])((?:causal_progression|protagonist_agency|emotional_tension|reader_pull|outline_[A-Z0-9]+|professional_reader_milestone))(?=：|；|$)/gu)]
    .map(match => match[1]);
  const labels = [...new Set(codes.map(code => qualityFindingLabel({ code })))];
  const summary = lines.filter(line => !/^(?:未通过项|需要处理)：/u.test(line));
  if (labels.length) summary.push(`需要处理：${labels.join('、')}。具体修改以上述质量结论为准。`);
  return summary.join('\n');
}

module.exports = {
  normalizeLegacyQualityFeedbackText,
  qualityFindingLabel,
  qualityFindingMessage,
  renderQualityFindings,
};
