'use strict';

const { checkBriefFreshness } = require('./short-brief-freshness');
const { checkShortPlanContract } = require('./short-plan-contract');

function checkShortProseEntry({ projectRoot, briefPath, sectionIndex, acceptedAnchorPath = '' }) {
  const plan = checkShortPlanContract(projectRoot);
  if (plan.status !== 'current') {
    return {
      status: 'blocked_short_plan_incomplete',
      plan,
      brief: null,
      resume_stage: 'section_outline',
      message: '短篇全篇规划尚未形成可执行契约，请先补齐设定和小节大纲。',
    };
  }
  const brief = checkBriefFreshness({ projectRoot, briefPath, sectionIndex, acceptedAnchorPath });
  if (brief.status !== 'current') {
    return {
      status: 'blocked_short_brief_stale',
      plan,
      brief,
      resume_stage: sectionIndex > 1 ? 'next_section_brief' : 'first_section_brief',
      message: '当前 Brief 缺失或已因上游规划变化而失效，必须重建后再写正文。',
    };
  }
  return {
    status: 'pass',
    plan,
    brief,
    section_index: Number(sectionIndex),
    progress: {
      planned: plan.planned_sections,
      accepted: plan.accepted_sections,
      current: plan.current_section_index,
      remaining: plan.remaining_sections,
    },
  };
}

module.exports = { checkShortProseEntry };
