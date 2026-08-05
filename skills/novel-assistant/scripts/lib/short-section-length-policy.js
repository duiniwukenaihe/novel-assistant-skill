'use strict';

const EXCEPTION_ROLES = new Set(['opening', 'transition', 'climax', 'reversal', 'finale']);

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

function targetRange(value) {
  if (!value || typeof value !== 'object') return null;
  const min = positiveInteger(value.min);
  const max = positiveInteger(value.max);
  if (!min || !max) return null;
  return { min: Math.min(min, max), max: Math.max(min, max) };
}

function median(values) {
  const sorted = values.slice().sort((left, right) => left - right);
  if (!sorted.length) return 0;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

function acceptedSamples(projectState) {
  return (Array.isArray((projectState || {}).accepted_sections) ? projectState.accepted_sections : [])
    .map((section) => ({
      section_index: positiveInteger((section || {}).section_index),
      length_chars: positiveInteger((section || {}).length_chars || (section || {}).section_cjk_chars),
      section_role: String((section || {}).section_role || 'normal').toLowerCase(),
    }))
    .filter((section) => section.section_index && section.length_chars)
    .sort((left, right) => left.section_index - right.section_index);
}

function deriveSectionLengthPolicy(input = {}) {
  const sectionIndex = positiveInteger(input.sectionIndex || input.section_index);
  const actual = positiveInteger(input.actual);
  const plannedTarget = positiveInteger(input.plannedTarget || input.planned_target);
  const plannedRange = targetRange(input.plannedTargetRange || input.planned_target_range);
  const samples = acceptedSamples(input.projectState)
    .filter((section) => !sectionIndex || section.section_index < sectionIndex);
  if (!samples.length && !(actual && plannedTarget)) {
    return {
      schemaVersion: '1.0.0',
      status: 'advisory',
      blocking: false,
      verdict: 'baseline_not_established',
      baseline_status: 'unavailable',
      baseline_chars: 0,
      sample_size: 0,
      note: '首个小节尚未采用；先按小节大纲与平台目标写作，采用后建立作品内篇幅基准。',
    };
  }

  const comparable = samples.filter((section) => !EXCEPTION_ROLES.has(section.section_role));
  const stablePool = (comparable.length >= 3 ? comparable : samples).slice(-5);
  const localBaseline = median(stablePool.map((section) => section.length_chars));
  const explicitTarget = actual && plannedTarget ? plannedTarget : 0;
  const baseline = explicitTarget || localBaseline;
  const lowerTolerance = plannedRange ? Math.max(0, baseline - plannedRange.min) : Math.ceil(baseline * 0.10);
  const upperTolerance = plannedRange ? Math.max(0, plannedRange.max - baseline) : Math.ceil(baseline * 0.20);
  const lower = plannedRange ? plannedRange.min : Math.max(1, baseline - lowerTolerance);
  const upper = plannedRange ? plannedRange.max : baseline + upperTolerance;
  const hardFloor = lower;
  const hardCeiling = upper;
  const observed = actual || plannedTarget;
  const role = String(input.sectionRole || input.section_role || 'normal').toLowerCase();
  const exceptionReason = String(input.exceptionReason || input.exception_reason || '').trim();
  const targetSource = explicitTarget
    ? String(input.plannedTargetSource || input.planned_target_source || 'explicit_section_target')
    : 'accepted_section_median';
  const inferredHardTarget = ['explicit_section_target', 'outline_section_target', 'accepted_outline_section_target']
    .includes(targetSource);
  const targetEnforcement = String(input.targetEnforcement || input.target_enforcement || '')
    || (inferredHardTarget ? 'hard' : 'advisory');
  const base = {
    schemaVersion: '1.0.0',
    section_index: sectionIndex,
    section_role: role,
    observed_kind: actual ? 'actual' : 'planned_target',
    target_source: targetSource,
    target_enforcement: targetEnforcement,
    observed_chars: observed,
    target_chars: targetEnforcement === 'hard' ? baseline : 0,
    target_range: plannedRange || undefined,
    reference_chars: baseline,
    baseline_status: comparable.length >= 3 ? 'stabilized' : 'provisional',
    baseline_chars: baseline,
    sample_size: stablePool.length,
    lower_tolerance_chars: lowerTolerance,
    upper_tolerance_chars: upperTolerance,
    lower_bound: lower,
    upper_bound: upper,
    hard_floor: hardFloor,
    hard_ceiling: hardCeiling,
  };

  if (!observed) {
    return { ...base, status: 'blocked', blocking: true, verdict: 'length_value_missing', note: '缺少当前小节实际字数或 Brief 目标字数。' };
  }
  if (EXCEPTION_ROLES.has(role) && exceptionReason) {
    return {
      ...base,
      status: 'warning',
      blocking: false,
      verdict: 'explicit_story_exception',
      exception_reason: exceptionReason,
      author_decision_required: false,
      note: '篇幅偏离基准，但当前 Brief 已记录明确的结构功能理由；仍需通过机器门和故事价值门。',
    };
  }
  if (!actual && observed < hardFloor) {
    return {
      ...base,
      status: 'advisory',
      blocking: false,
      verdict: 'under_target_review_completeness',
      author_decision_required: false,
      note: '下一节目标篇幅明显低于作品基准；写作前检查是否仍能容纳计划内事件、选择和钩子。',
    };
  }
  if (targetEnforcement !== 'hard') {
    if (observed >= lower && observed <= upper) {
      return { ...base, status: 'pass', blocking: false, verdict: 'within_target_band', author_decision_required: false, note: '当前长度处于历史节奏参考区间；历史中位数不替代作者目标。' };
    }
    return {
      ...base,
      status: 'advisory',
      blocking: false,
      verdict: 'observed_length_variance_advisory',
      author_decision_required: false,
      note: '当前长度偏离历史中位数；该数据只用于节奏诊断，不能降低或代替作者、项目已确认的篇幅目标。',
    };
  }
  if (observed < hardFloor) {
    const gap = baseline - observed;
    const gapPercent = gap / baseline * 100;
    return {
      ...base,
      status: 'blocked',
      blocking: true,
      verdict: 'under_target_repair_required',
      author_decision_required: false,
      variance_chars: -gap,
      variance_percent: Number((-gapPercent).toFixed(1)),
      note: `目标${baseline}字，实际${observed}字，少${gap}字（${gapPercent.toFixed(1)}%），低于最低${hardFloor}字；自动回到本节补足真实事件、冲突、选择或钩子，不把欠写交给作者确认。`,
    };
  }
  if (observed > hardCeiling) {
    const excess = observed - baseline;
    const excessPercent = excess / baseline * 100;
    return {
      ...base,
      status: 'blocked',
      blocking: true,
      verdict: 'over_target_repair_required',
      author_decision_required: false,
      variance_chars: excess,
      variance_percent: Number(excessPercent.toFixed(1)),
      note: `目标${baseline}字，实际${observed}字，多${excess}字（${excessPercent.toFixed(1)}%），超过最高${hardCeiling}字；自动回炉删除重复和无功能段落，承担项过载时拆回规划处理。`,
    };
  }
  if (observed >= lower && observed <= hardCeiling) {
    return { ...base, status: 'pass', blocking: false, verdict: 'within_target_band', note: '篇幅处于当前目标的稳定区间。' };
  }
  return { ...base, status: 'blocked', blocking: true, verdict: 'length_policy_unreachable', author_decision_required: false };
}

function shouldAskSingleSectionLengthChoice(task, lengthPolicy) {
  return false;
}

module.exports = { EXCEPTION_ROLES, acceptedSamples, deriveSectionLengthPolicy, median, shouldAskSingleSectionLengthChoice };
