'use strict';

const IMPACT_LEVELS = new Set([
  'expression_only',
  'current_brief',
  'planning',
  'structure',
]);

function stringList(value) {
  return Array.isArray(value) ? value.map(String).filter(Boolean) : [];
}

function sectionList(value) {
  return Array.isArray(value)
    ? [...new Set(value.map(Number).filter((item) => Number.isInteger(item) && item > 0))].sort((a, b) => a - b)
    : [];
}

function includesPlanningAsset(changedAssets) {
  return changedAssets.some((item) => /(^|\/)(素材卡|设定|小节大纲)\.md$/.test(item));
}

function preferredBriefStage(allowed, section) {
  if (allowed.has('section_brief')) return 'section_brief';
  return section === 1 ? 'first_section_brief' : 'next_section_brief';
}

function preferredPlanningStage(changedAssets, allowed, section) {
  const changedMaterial = changedAssets.some((item) => /(^|\/)素材卡\.md$/.test(item));
  const changedSetting = changedAssets.some((item) => /(^|\/)设定\.md$/.test(item));
  const changedOutline = changedAssets.some((item) => /(^|\/)小节大纲\.md$/.test(item));
  if (changedOutline) return 'section_plan_lock';
  if (changedSetting) return 'section_outline';
  if (changedMaterial) return 'short_setting';
  return preferredBriefStage(allowed, section);
}

function blocked(message, details = {}) {
  return {
    status: 'blocked_feedback_impact_contract',
    message,
    ...details,
  };
}

function resolveShortFeedbackPatch({ result = {}, allowedNext = [], sectionIndex = 1 } = {}) {
  const impactLevel = String(result.impact_level || result.feedback_impact_level || '').trim();
  const changedAssets = stringList(result.changed_assets);
  const affectedSections = sectionList(result.affected_sections);
  const crossSectionImpact = result.cross_section_impact === true || affectedSections.length > 1;
  const allowed = new Set(stringList(allowedNext));
  const section = Number.isInteger(Number(sectionIndex)) && Number(sectionIndex) > 0 ? Number(sectionIndex) : 1;
  if (!IMPACT_LEVELS.has(impactLevel)) {
    return blocked('反馈结果缺少有效 impact_level。', { impact_level: impactLevel });
  }

  let nextStageId = '';
  let invalidatesBrief = false;
  let invalidatesDraft = false;
  let requiresStructureAudit = false;
  let downstreamRevalidation = false;
  let userTextStatus = '';

  if (String(result.source_kind || '') === 'user_manual_edit') {
    if (result.preserve_user_text !== true) {
      return blocked('人工修改必须先作为候选保留并完成语义影响检查，不能被静默覆盖。', { impact_level: impactLevel });
    }
    userTextStatus = 'candidate_preserved';
  }

  if (impactLevel === 'expression_only') {
    if (includesPlanningAsset(changedAssets)) {
      return blocked('表达层反馈不能声明设定或小节大纲变更。', { impact_level: impactLevel, changed_assets: changedAssets });
    }
    nextStageId = 'section_repair_loop';
  } else if (impactLevel === 'current_brief') {
    if (includesPlanningAsset(changedAssets)) {
      return blocked('当前 Brief 层反馈不能夹带规划资产变更。', { impact_level: impactLevel, changed_assets: changedAssets });
    }
    if (result.brief_invalidated !== true) {
      return blocked('当前节故事调整必须先使旧 Brief 失效，再进入重建。', { impact_level: impactLevel });
    }
    nextStageId = preferredBriefStage(allowed, section);
    invalidatesBrief = true;
    invalidatesDraft = true;
  } else if (impactLevel === 'planning') {
    if (!includesPlanningAsset(changedAssets)) {
      return blocked('规划层反馈必须先更新素材卡、设定或小节大纲。', { impact_level: impactLevel, changed_assets: changedAssets });
    }
    if (result.brief_invalidated !== true) {
      return blocked('规划层更新后必须使受影响 Brief 失效。', { impact_level: impactLevel, changed_assets: changedAssets });
    }
    if (crossSectionImpact && (!result.downstream_impact || typeof result.downstream_impact !== 'object')) {
      return blocked('跨节规划变更必须附带受影响小节、失效 Brief 和正文复检清单。', { impact_level: impactLevel, affected_sections: affectedSections });
    }
    nextStageId = preferredPlanningStage(changedAssets, allowed, section);
    invalidatesBrief = true;
    invalidatesDraft = true;
    requiresStructureAudit = crossSectionImpact;
    downstreamRevalidation = true;
  } else {
    if (!includesPlanningAsset(changedAssets)) {
      return blocked('结构变更必须回写设定或小节大纲。', { impact_level: impactLevel, changed_assets: changedAssets });
    }
    if (result.brief_invalidated !== true) {
      return blocked('结构变更后必须使受影响 Brief 失效。', { impact_level: impactLevel, changed_assets: changedAssets });
    }
    if (!result.downstream_impact || typeof result.downstream_impact !== 'object') {
      return blocked('结构变更必须附带下游影响清单。', { impact_level: impactLevel });
    }
    nextStageId = 'section_plan_lock';
    invalidatesBrief = true;
    invalidatesDraft = true;
    requiresStructureAudit = true;
    downstreamRevalidation = true;
  }

  const requestedNext = String(result.next_stage_id || result.next_stage || result.target_stage || '');
  if (requestedNext && requestedNext !== nextStageId) {
    return blocked('反馈结果试图绕过必需的上游回写顺序。', {
      impact_level: impactLevel,
      requested_next_stage: requestedNext,
      required_next_stage: nextStageId,
    });
  }
  if (!allowed.has(nextStageId)) {
    return blocked('工作流模板未允许反馈回到必需阶段。', {
      impact_level: impactLevel,
      required_next_stage: nextStageId,
    });
  }

  return {
    status: 'ok',
    impact_level: impactLevel,
    next_stage_id: nextStageId,
    changed_assets: changedAssets,
    invalidates_brief: invalidatesBrief,
    invalidates_draft: invalidatesDraft,
    requires_structure_audit: requiresStructureAudit,
    downstream_revalidation: downstreamRevalidation,
    requires_reacceptance: invalidatesDraft && (result.accepted_section === true || String(result.current_section_status || '') === 'accepted'),
    affected_sections: affectedSections,
    cross_section_impact: crossSectionImpact,
    user_text_status: userTextStatus,
  };
}

module.exports = {
  IMPACT_LEVELS,
  resolveShortFeedbackPatch,
};
