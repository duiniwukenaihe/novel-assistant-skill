'use strict';

const RESULT_KINDS = Object.freeze([
  'completed', 'retryable_internal', 'needs_author_choice', 'blocked',
]);

function stageResult(input = {}) {
  if (!RESULT_KINDS.includes(input.kind)) throw new Error('stage_result_kind_invalid');
  if (!String(input.code || '').trim()) throw new Error('stage_result_code_required');
  if (!String(input.stage_id || '').trim()) throw new Error('stage_result_stage_required');
  if (Object.prototype.hasOwnProperty.call(input, 'visible_response')) {
    throw new Error('visible_response_forbidden');
  }
  const result = { ...input };
  if (result.kind === 'needs_author_choice') {
    const options = Array.isArray(result.options) ? result.options.map(authorChoice) : [];
    if (options.length < 2 || options.length > 4) throw new Error('author_choice_count_invalid');
    result.options = Object.freeze(options);
  }
  return Object.freeze(result);
}

function authorChoice(input = {}) {
  if (Object.prototype.hasOwnProperty.call(input, 'number')) throw new Error('author_choice_number_forbidden');
  if (!String(input.action_id || '').trim() || !String(input.label || '').trim()) {
    throw new Error('author_choice_identity_required');
  }
  return Object.freeze({ ...input });
}

function validateStageResult(result) {
  return stageResult(result);
}

module.exports = { RESULT_KINDS, stageResult, authorChoice, validateStageResult };
