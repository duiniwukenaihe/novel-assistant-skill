'use strict';

const {
  checkLongCharacterContract,
  projectLongCharacterMemory,
} = require('./long-character-contract');

const LONG_CHARACTER_STAGES = new Set([
  'long_startup:character_design',
  'long_write:story_bible',
]);

function validateWorkflowCharacterContract(projectRoot, task, result) {
  if (!requiresLongCharacterContract(task, result)) return null;
  const analysis = checkLongCharacterContract(projectRoot, {
    files: declaredCharacterFiles(result),
  });
  if (analysis.status === 'pass') return { status: 'pass', analysis };
  return {
    status: 'blocked_character_contract_revision_required',
    findings: analysis.findings,
    advisories: analysis.advisories,
    source_files: analysis.source_files,
    instruction: '先补齐人物发动机、主要压力角色、关系债与跨阶段成长里程碑；保留已完成的世界观和剧情设定，不得直接进入总纲或正文。',
  };
}

function projectWorkflowCharacterContract(projectRoot, task, result) {
  if (!requiresLongCharacterContract(task, result)) return { status: 'not_applicable' };
  return projectLongCharacterMemory(projectRoot, {
    workflowId: String((task || {}).workflow_id || ''),
    files: declaredCharacterFiles(result),
  });
}

function requiresLongCharacterContract(task, result) {
  if (String((result || {}).step_status || '') !== 'completed') return false;
  const key = `${String((task || {}).workflow_type || '')}:${String((task || {}).current_stage || '')}`;
  return LONG_CHARACTER_STAGES.has(key);
}

function declaredCharacterFiles(result) {
  return [...new Set([
    ...(Array.isArray((result || {}).changed_files) ? result.changed_files : []),
    ...(Array.isArray((result || {}).outputs) ? result.outputs : []),
    ...(Array.isArray((result || {}).result_write_set) ? result.result_write_set : []),
  ].map(item => String(item || '')).filter(Boolean))];
}

module.exports = {
  declaredCharacterFiles,
  projectWorkflowCharacterContract,
  requiresLongCharacterContract,
  validateWorkflowCharacterContract,
};
