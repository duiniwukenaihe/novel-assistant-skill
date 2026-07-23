'use strict';

function parseArabicSectionIndex(value) {
  const text = String(value || '');
  const match = text.match(/第\s*0*([0-9]+)\s*节/);
  if (!match) return null;
  const parsed = Number(match[1]);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function expectedSectionIndex(task) {
  const unit = task.unit_lifecycle || {};
  return parseArabicSectionIndex(unit.current_scope)
    || parseArabicSectionIndex(task.scope)
    || parseArabicSectionIndex((task.lifecycle || {}).scope)
    || null;
}

function actualSectionIndex(result) {
  const direct = Number(result.current_section_index || result.section_index || 0);
  if (Number.isInteger(direct) && direct > 0) return direct;
  const checkpoint = result.checkpoint_state || {};
  const checkpointDirect = Number(checkpoint.current_section_index || checkpoint.section_index || 0);
  if (Number.isInteger(checkpointDirect) && checkpointDirect > 0) return checkpointDirect;
  return parseArabicSectionIndex(result.current_section_scope)
    || parseArabicSectionIndex(result.section_scope)
    || parseArabicSectionIndex(checkpoint.current_scope)
    || parseArabicSectionIndex(checkpoint.current_batch)
    || parseArabicSectionIndex(result.handoff_summary)
    || null;
}

function shouldValidateSectionUnit(task) {
  const unit = task.unit_lifecycle || {};
  const workflowType = String(task.workflow_type || '');
  const stageId = String(((task.stage_execution || {}).stage_id) || task.current_stage || '');
  const wholeStoryStages = new Set(['full_story_assembly', 'full_story_review', 'short_deslop', 'deslop', 'final_check']);
  if (wholeStoryStages.has(stageId) || unit.unit_type === 'story') return false;
  return unit.unit_type === 'section'
    || ['short_write', 'private_short_startup'].includes(workflowType);
}

function validateResultPacketUnitBinding(task, result) {
  if (!task || !result || !shouldValidateSectionUnit(task)) return null;
  const expected = expectedSectionIndex(task);
  const actual = actualSectionIndex(result);
  if (!expected || !actual || expected === actual) return null;
  return {
    status: 'blocked_result_packet_unit_mismatch',
    findings: [{
      field: 'result_packet.current_section_index',
      message: '结果包所属小节与当前 workflow 单元不一致，可能是上一小节同名 result packet 残留；不得继续推进。',
      expected_section_index: expected,
      actual_section_index: actual,
      expected_scope: String((task.unit_lifecycle || {}).current_scope || task.scope || ''),
      actual_scope: String(result.current_section_scope || result.section_scope || ''),
    }],
  };
}

module.exports = {
  actualSectionIndex,
  expectedSectionIndex,
  parseArabicSectionIndex,
  validateResultPacketUnitBinding,
};
