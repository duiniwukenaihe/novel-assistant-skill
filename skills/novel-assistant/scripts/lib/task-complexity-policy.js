'use strict';

const DETERMINISTIC_STAGES = new Set([
  'project_type_lock',
  'section_machine_gate',
  'source_inventory',
  'schema_validation',
  'update_check',
]);

const SINGLE_WRITER_STAGE_PATTERN = /(?:draft|prose|brief|repair|apply_patch|accept_anchor|assembly|outline|setting|positioning)/u;

function classifyTaskComplexity(input = {}) {
  const workflowType = String(input.workflowType || input.workflow_type || 'workflow');
  const stageId = String(input.stageId || input.stage_id || '');
  const inputFiles = positiveInteger(input.inputFiles ?? input.input_files, 1);
  const inputChars = positiveNumber(input.inputChars ?? input.input_chars, 0);
  const unitCount = positiveInteger(input.unitCount ?? input.unit_count, 1);
  const riskLevel = String(input.riskLevel || input.risk_level || 'low').toLowerCase();
  const independentDomains = uniqueStrings(input.independentDomains || input.independent_domains);
  const maxParallelAgents = positiveInteger(input.maxParallelAgents ?? input.max_parallel_agents, 4);
  const structuralChange = Boolean(input.structuralChange ?? input.structural_change);
  const crossVolume = Boolean(input.crossVolume ?? input.cross_volume);
  const failureCount = nonNegativeInteger(input.failureCount ?? input.failure_count, 0);
  const deterministic = DETERMINISTIC_STAGES.has(stageId) || Boolean(input.deterministic);
  const canonicalSingleWriter = SINGLE_WRITER_STAGE_PATTERN.test(stageId) || Boolean(input.canonicalWrite);
  const reasonCodes = [];

  if (deterministic) reasonCodes.push('deterministic_stage');
  if (canonicalSingleWriter) reasonCodes.push('canonical_single_writer');
  if (inputChars > 240000 || inputFiles > 80 || unitCount > 40) reasonCodes.push('large_input_scope');
  if (inputChars > 60000 || inputFiles > 20 || unitCount > 8) reasonCodes.push('medium_input_scope');
  if (independentDomains.length > 1) reasonCodes.push('independent_evidence_domains');
  if (riskLevel === 'high' || riskLevel === 'destructive') reasonCodes.push('high_risk');
  if (structuralChange) reasonCodes.push('structural_change');
  if (crossVolume) reasonCodes.push('cross_volume');
  if (failureCount > 1) reasonCodes.push('repeated_failure');

  let sizeClass = 'small';
  if (inputChars > 240000 || inputFiles > 80 || unitCount > 40 || crossVolume || failureCount > 2) {
    sizeClass = 'large';
  } else if (inputChars > 60000 || inputFiles > 20 || unitCount > 8 || independentDomains.length > 1 || structuralChange || ['high', 'destructive'].includes(riskLevel)) {
    sizeClass = 'medium';
  }

  let recommendedAgentCount = 1;
  let executionTopology = 'single_agent';
  if (deterministic) {
    recommendedAgentCount = 0;
    executionTopology = 'deterministic_script';
  } else if (!canonicalSingleWriter && independentDomains.length > 1) {
    const classLimit = sizeClass === 'large' ? 4 : 2;
    recommendedAgentCount = Math.max(1, Math.min(maxParallelAgents, classLimit, independentDomains.length));
    executionTopology = sizeClass === 'large' ? 'batch_then_parallel_read' : 'parallel_read';
  }

  const modelClass = deterministic
    ? 'cheap_extract'
    : sizeClass === 'large' && (crossVolume || structuralChange || ['high', 'destructive'].includes(riskLevel))
      ? 'deep_reasoning'
      : 'standard_reasoning';

  return {
    schemaVersion: '1.0.0',
    workflow_type: workflowType,
    stage_id: stageId,
    size_class: sizeClass,
    reason_codes: reasonCodes.length ? reasonCodes : ['current_unit_scope'],
    recommended_agent_count: recommendedAgentCount,
    parallel_domains: recommendedAgentCount > 1 ? independentDomains.slice(0, recommendedAgentCount) : [],
    model_class: modelClass,
    context_strategy: sizeClass === 'large' ? 'batch_summaries' : sizeClass === 'medium' ? 'scoped_artifacts' : 'current_unit_only',
    execution_topology: executionTopology,
    single_writer_required: canonicalSingleWriter,
  };
}

function uniqueStrings(values) {
  return Array.from(new Set((Array.isArray(values) ? values : []).map((value) => String(value || '').trim()).filter(Boolean)));
}

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

function nonNegativeInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : fallback;
}

function positiveNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

module.exports = { classifyTaskComplexity };
