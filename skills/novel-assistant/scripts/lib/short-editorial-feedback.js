'use strict';

const crypto = require('crypto');
const {
  classifyEditorialImpact,
  normalizeSectionIndices,
  sectionsFromFindingScope,
  summarizeEditorialImpact,
} = require('./short-editorial-impact');

const FINDING_COPY = Object.freeze({
  EndingCost: Object.freeze({
    title: '结尾的责任与代价没有落地',
    impact: '读者能看到结论，却看不到人物为这个结论承担了什么。',
  }),
  causal_progression: Object.freeze({
    title: '关键事件之间的因果推进不够完整',
    impact: '读者能看见事件发生，却不容易相信人物为什么会走到下一步。',
  }),
  protagonist_agency: Object.freeze({
    title: '主角缺少推动局面的主动选择',
    impact: '主角更像被情节推着走，人物力量和代价都会变弱。',
  }),
  emotional_tension: Object.freeze({
    title: '冲突后的情绪张力没有继续升级',
    impact: '情绪在关键位置提前松掉，高潮的冲击力会被削弱。',
  }),
  reader_pull: Object.freeze({
    title: '这一段缺少继续读下去的明确牵引',
    impact: '读者知道发生了什么，但下一步最想追问的问题不够清楚。',
  }),
  professional_reader_milestone: Object.freeze({
    title: '目标读者期待的关键体验尚未兑现',
    impact: '故事信息已经出现，但读者期待的情绪回报或剧情回报还不充分。',
  }),
  section_responsibility_overload: Object.freeze({
    title: '当前小节同时承担的剧情任务过多',
    impact: '多个重要结果挤在一起，会让高潮、人物选择和结尾余韵互相削弱。',
  }),
});

function buildEditorialFeedbackDraft(task = {}, result = {}) {
  const findings = Array.isArray(result.findings) ? result.findings : [];
  if (!findings.length) return { status: 'not_applicable', reason: 'editorial_findings_empty' };

  const sectionIndices = normalizeSectionIndices(result.section_indices);
  const reviewHash = normalizedReviewHash(result.review_card_sha256, findings);
  const normalized = normalizeEditorialFindings(findings, sectionIndices, reviewHash);
  const affectedSections = normalizeSectionIndices(normalized.flatMap(item => item.affected_sections));
  if (!affectedSections.length) {
    return { status: 'not_applicable', reason: 'editorial_finding_scope_unresolved' };
  }

  const feedbackId = `feedback-editorial-${crypto.createHash('sha256').update(reviewHash).digest('hex').slice(0, 16)}`;
  const titles = [...new Set(normalized.map(item => item.visible_title))];
  const impactLevel = summarizeEditorialImpact(normalized);
  const needsAnalysis = impactLevel === 'needs_analysis';
  const summary = `全篇审阅发现 ${normalized.length} 项需要回炉的问题，涉及第${formatSectionList(affectedSections)}节。`;
  const question = [
    summary,
    `主要问题：${titles.slice(0, 3).join('；')}${titles.length > 3 ? `；另有 ${titles.length - 3} 项` : ''}。`,
    needsAnalysis
      ? '其中包含无法安全自动判断影响范围的问题。请先通过对话明确修改方向，再生成可确认方案。'
      : '建议先确认修改方向，再更新相关小节的规划与 Brief，逐节修改正文并重新审阅。请选择如何处理。',
  ].join('\n');
  const proposedPlan = {
    schema_version: '1.0.0',
    proposal_id: `proposal.${feedbackId}`,
    summary,
    impact_level: impactLevel,
    affected_sections: affectedSections,
    evidence: normalized.map(item => item.evidence_quote).filter(Boolean),
    proposed_changes: normalized.map(item => item.repair_direction).filter(Boolean),
    review_findings: normalized,
    source_review: {
      review_card_sha256: String(result.review_card_sha256 || ''),
      receipt_path: String(result.receipt_path || ''),
      story_sha256: String(result.story_sha256 || ''),
    },
  };

  return {
    status: 'feedback_draft_ready',
    pending_feedback: {
      id: feedbackId,
      feedback_id: feedbackId,
      status: 'awaiting_confirmation',
      workflow_id: String(task.workflow_id || ''),
      stage_id: 'editorial_review',
      scope_snapshot: '全篇',
      proposed_plan: proposedPlan,
      proposed_at: new Date().toISOString(),
    },
    interaction_result: {
      kind: 'needs_author_choice',
      code: 'confirm_editorial_revision_plan',
      stage_id: 'editorial_review',
      question,
      options: needsAnalysis
        ? [
            { action_id: 'continue_feedback_chat', label: '先讨论并明确修改方案' },
            { action_id: 'view_feedback_evidence', label: '查看正文依据' },
            { action_id: 'pause_feedback', label: '暂停并保存断点' },
          ]
        : [
            { action_id: 'accept_feedback_plan', label: '采用这份修改方案' },
            { action_id: 'continue_feedback_chat', label: '继续讨论并修改方案' },
            { action_id: 'view_feedback_evidence', label: '查看正文依据' },
            { action_id: 'pause_feedback', label: '暂停并保存断点' },
          ],
    },
  };
}

function normalizeEditorialFindings(findings = [], sectionIndices = [], reviewHash = '') {
  const available = normalizeSectionIndices(sectionIndices);
  const stableHash = normalizedReviewHash(reviewHash, findings);
  return (Array.isArray(findings) ? findings : []).map((finding, index) => {
    const source = finding && typeof finding === 'object' ? finding : {};
    const code = String(source.code || 'editorial_revision_required');
    const affectedSections = sectionsFromFindingScope(source.scope, available);
    const impact = classifyEditorialImpact(source);
    const copy = findingCopy(code, affectedSections);
    return {
      finding_id: `review.${stableHash}.${String(index + 1).padStart(3, '0')}`,
      code,
      impact_level: impact.impact_level,
      severity: String(source.severity || ''),
      scope: String(source.scope || ''),
      affected_sections: affectedSections,
      visible_title: String(source.visible_title || copy.title),
      evidence_quote: String(source.evidence_quote || '').trim(),
      reader_impact: String(source.reader_impact || copy.impact),
      repair_direction: String(source.repair_direction || '围绕正文证据补足这一项，并在修改后重新审阅。').trim(),
    };
  });
}

function findingCopy(code, affectedSections) {
  if (FINDING_COPY[code]) return FINDING_COPY[code];
  if (/^outline_/u.test(code)) {
    return {
      title: '大纲中的关键承诺没有在正文中充分兑现',
      impact: '读者能看到前期铺垫，却没有在对应位置得到完整回报。',
    };
  }
  const scope = affectedSections.length
    ? `第${formatSectionList(affectedSections)}节`
    : '当前故事';
  return {
    title: `${scope}存在需要回炉的故事问题`,
    impact: '这一问题会削弱读者对人物选择、情节推进或结局回报的理解。',
  };
}

function normalizedReviewHash(value, findings) {
  const normalized = String(value || '').replace(/^sha256:/u, '').replace(/[^A-Za-z0-9._-]+/gu, '');
  if (normalized) return normalized;
  return crypto.createHash('sha256').update(JSON.stringify(findings || [])).digest('hex');
}

function formatSectionList(values) {
  const normalized = normalizeSectionIndices(values);
  if (normalized.length === 1) return String(normalized[0]);
  const continuous = normalized.every((value, index) => index === 0 || value === normalized[index - 1] + 1);
  return continuous ? `${normalized[0]}至${normalized[normalized.length - 1]}` : normalized.join('、');
}

module.exports = {
  buildEditorialFeedbackDraft,
  normalizeEditorialFindings,
  sectionsFromFindingScope,
};
