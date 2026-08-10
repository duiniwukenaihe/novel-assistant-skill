'use strict';

const LONG_CONTEXT_STAGES = new Set([
  'chapter_brief', 'brief_review', 'prose', 'prose_acceptance', 'chapter_commit',
  'detail_outline_review', 'stage_detail_outline',
]);

function requiresStageContext(workflowType, stageId) {
  return String(workflowType || '') === 'long_write'
    && LONG_CONTEXT_STAGES.has(String(stageId || ''));
}

function resolveStageContext({ projectRoot = '', task = {}, execution = {}, builders = [] } = {}) {
  const stageId = String((execution || {}).stage_id || (task || {}).current_stage || '');
  const input = { projectRoot, task, stage: stageId };
  try {
    for (const buildPacket of (Array.isArray(builders) ? builders : [])) {
      if (typeof buildPacket !== 'function') continue;
      const packet = buildPacket(input);
      if (packet && packet.status === 'assembled' && packet.packet_md) return packet;
      if (packet && packet.blocking === true) return packet;
    }
    return null;
  } catch (error) {
    if (!requiresStageContext((task || {}).workflow_type, stageId)) return null;
    return {
      status: 'blocked_stage_context_build_failed',
      blocking: true,
      reason: String((error && error.message) || error || 'stage context build failed'),
      stage_id: stageId,
    };
  }
}

module.exports = {
  LONG_CONTEXT_STAGES,
  requiresStageContext,
  resolveStageContext,
};
