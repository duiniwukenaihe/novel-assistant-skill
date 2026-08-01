'use strict';

const QUALITY_CHECKS = Object.freeze([
  'causal_progression',
  'protagonist_agency',
  'emotional_tension',
  'reader_pull',
]);

const LEGACY_CHECK_GROUPS = Object.freeze({
  causal_progression: ['causal_chain', 'section_function_completion'],
  protagonist_agency: ['role_lock', 'protagonist_agency'],
  emotional_tension: ['human_emotion'],
  reader_pull: ['title_promise', 'hook_payoff', 'story_attraction'],
});

function buildShortQualityEvidenceSchema({ workflowId, sectionIndex, draftDigest, outlineContract, readerMilestone }) {
  const schema = {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    section_index: sectionIndex,
    draft_digest: draftDigest,
    outline_contract_digest: String(outlineContract.contract_digest || ''),
    checks: QUALITY_CHECKS.map((id) => ({
      id,
      status: 'pass|revise',
      evidence: '至少四个字的判断理由',
      evidence_quote: '正文中可核验的原句',
    })),
    outline_coverage: (outlineContract.obligations || [])
      .filter((item) => item.required_in_draft)
      .map((item) => ({
        id: item.id,
        status: 'pass|revise',
        evidence_quote: '正文中兑现该大纲义务的原句',
      })),
    summary: '不少于十二个字的本节质量结论',
    acceptance_metadata: {
      revealed_information: ['本节新增且已确认的信息'],
      character_state: { 角色名: '本节结束时的人物状态' },
      open_hook: outlineContract.section_role === 'ending' ? '' : '带入下一节的未闭合问题',
    },
  };
  if (readerMilestone && readerMilestone.required) {
    schema.reader_milestone = {
      reviewer: 'professional-reader',
      kind: readerMilestone.kind,
      status: 'pass|revise',
      would_continue: 'yes|maybe|no',
      strongest_pull: '读者最想继续追看的具体原因',
      biggest_resistance: '最可能掉线的具体阻力',
      evidence_quote: '正文中的可核验原句',
      repair_direction: 'status=revise 时填写最小修复方向',
    };
  }
  return schema;
}

module.exports = {
  LEGACY_CHECK_GROUPS,
  QUALITY_CHECKS,
  buildShortQualityEvidenceSchema,
};
