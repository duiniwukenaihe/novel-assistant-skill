'use strict';

const EXCEPTION_ROLES = new Set(['opening', 'transition', 'climax', 'reversal', 'finale']);

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
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
  const samples = acceptedSamples(input.projectState)
    .filter((section) => !sectionIndex || section.section_index < sectionIndex);
  if (!samples.length) {
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
  const baseline = median(stablePool.map((section) => section.length_chars));
  const tolerance = Math.min(400, Math.max(200, Math.round(baseline * 0.12)));
  const lower = Math.max(1, baseline - tolerance);
  const upper = baseline + tolerance;
  const actual = positiveInteger(input.actual);
  const plannedTarget = positiveInteger(input.plannedTarget || input.planned_target);
  const observed = actual || plannedTarget;
  const role = String(input.sectionRole || input.section_role || 'normal').toLowerCase();
  const exceptionReason = String(input.exceptionReason || input.exception_reason || '').trim();
  const base = {
    schemaVersion: '1.0.0',
    section_index: sectionIndex,
    section_role: role,
    observed_kind: actual ? 'actual' : 'planned_target',
    observed_chars: observed,
    baseline_status: comparable.length >= 3 ? 'stabilized' : 'provisional',
    baseline_chars: baseline,
    sample_size: stablePool.length,
    tolerance_chars: tolerance,
    lower_bound: lower,
    upper_bound: upper,
  };

  if (!observed) {
    return { ...base, status: 'blocked', blocking: true, verdict: 'length_value_missing', note: '缺少当前小节实际字数或 Brief 目标字数。' };
  }
  if (observed >= lower && observed <= upper) {
    return { ...base, status: 'pass', blocking: false, verdict: 'within_story_band', note: '篇幅处于当前作品的稳定区间。' };
  }
  if (EXCEPTION_ROLES.has(role) && exceptionReason) {
    return {
      ...base,
      status: 'warning',
      blocking: false,
      verdict: 'explicit_story_exception',
      exception_reason: exceptionReason,
      note: '篇幅偏离基准，但当前 Brief 已记录明确的结构功能理由；仍需通过机器门和故事价值门。',
    };
  }
  return {
    ...base,
    status: 'advisory',
    blocking: false,
    verdict: 'outside_story_band_deferred',
    exception_reason_required: EXCEPTION_ROLES.has(role),
    note: actual
      ? '当前小节偏离作品内篇幅基准；已记录为篇幅提醒，不阻断当前节，整篇收束时统一决定补写、压缩或保留。'
      : '下一节 Brief 的目标篇幅偏离作品基准；仅记录提醒，不因字数单独阻断写作。',
  };
}

function shouldAskSingleSectionLengthChoice(task, lengthPolicy) {
  if (String((lengthPolicy || {}).verdict || '') !== 'outside_story_band_deferred') return false;
  const originalScope = String((((task || {}).lifecycle || {}).scope) || '').trim();
  if (!/^第\s*0*\d+\s*节$/u.test(originalScope)) return false;
  const queue = (task || {}).feedback_revision_queue;
  const queueSections = Array.isArray((queue || {}).affected_sections)
    ? queue.affected_sections
    : Array.isArray((queue || {}).items) ? queue.items.map((item) => item.section_index) : [];
  return new Set(queueSections.map(Number).filter(Number.isInteger)).size <= 1;
}

module.exports = { EXCEPTION_ROLES, acceptedSamples, deriveSectionLengthPolicy, median, shouldAskSingleSectionLengthChoice };
