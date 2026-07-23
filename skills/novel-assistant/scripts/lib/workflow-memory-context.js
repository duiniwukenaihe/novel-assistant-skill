'use strict';

const path = require('path');
const { spawnSync } = require('child_process');
const { sanitizeForArtifact } = require('../behavior-eval');
const {
  createMemoryContract,
  createMemoryReadReceipt,
} = require('./memory-query-contract');
const { StoryMemoryRepository } = require('./story-memory-repository');

function prepareMemoryContext(root, task, execution, policy, contextRunId = '') {
  if (policy.mode === 'none') return memoryContextDecision(policy, 'not_applicable');
  const script = path.join(__dirname, '..', 'context-assembler.js');
  const target = String(task.scope || execution.stage_id || task.user_goal || 'current-task');
  const taskName = `${task.workflow_type}:${execution.stage_id}`;
  const result = spawnSync(process.execPath, [
    script,
    '--project-root', root,
    '--task', taskName,
    '--target', target,
    '--workflow-id', task.workflow_id,
    '--task-dir', task.task_dir,
    '--stage', execution.stage_id,
    '--run-id', contextRunId,
    '--budget', String(policy.token_budget),
    '--json',
  ], { encoding: 'utf8', shell: false, maxBuffer: 20 * 1024 * 1024 });
  let parsed = {};
  try {
    parsed = JSON.parse(result.stdout || '{}');
  } catch (error) {
    parsed = { status: 'blocked_memory_context_invalid', message: error.message };
  }
  if (parsed.status !== 'ok') {
    if (policy.mode === 'optional') {
      return {
        ...memoryContextDecision(policy, parsed.status || 'optional_context_unavailable'),
        warning: sanitizeForArtifact(String(parsed.message || parsed.status || 'memory context unavailable')).slice(0, 300),
      };
    }
    return {
      ...memoryContextDecision(policy, parsed.status || 'blocked_memory_context'),
      blocking: true,
      findings: parsed.findings || [],
      stale_entry_ids: parsed.staleEntryIds || [],
      blocked_entry_ids: parsed.blockedEntryIds || [],
    };
  }
  const identity = resolveProjectIdentity(root, task);
  const memoryRevision = normalizeDigest(parsed.packetDigest || '');
  const contract = createMemoryContract({
    query: {
      project_id: identity.project_id,
      project_instance_id: identity.project_instance_id,
      workflow_id: String(task.workflow_id || ''),
      workflow_type: String(task.workflow_type || ''),
      stage_id: String(execution.stage_id || task.current_stage || ''),
      owner_module: String(execution.owner_module || task.workflow_owner || ''),
      scope: { target },
      needs: memoryNeedsFor(task.workflow_type),
      query_text: `${taskName}\n${target}`,
    },
    provider: 'story-memory',
    memoryRevision,
    packetPath: relativeProjectPath(root, parsed.packetJson),
    packetDigest: memoryRevision,
    tokenBudget: Number(policy.token_budget || 0),
    usedTokens: Number(parsed.estimated_total_tokens || 0),
    selectedEntryIds: (parsed.selectedEntries || []).map((item) => item.id).filter(Boolean),
    omittedCount: Array.isArray(parsed.omittedEntries) ? parsed.omittedEntries.length : 0,
    acceptsMemoryUpdates: policy.accepts_memory_updates,
  });
  const receipt = {
    ...createMemoryReadReceipt(contract),
    source_digests: new StoryMemoryRepository(root).sourceRevisions(),
    generated_at: new Date().toISOString(),
  };
  return {
    ...memoryContextDecision(policy, 'assembled'),
    packet_json: relativeProjectPath(root, parsed.packetJson),
    packet_md: relativeProjectPath(root, parsed.packetMd),
    estimated_tokens: Number(parsed.estimated_total_tokens || 0),
    selected_entry_ids: (parsed.selectedEntries || []).map((item) => item.id).filter(Boolean),
    omitted_count: Array.isArray(parsed.omittedEntries) ? parsed.omittedEntries.length : 0,
    workflow_id: parsed.workflowId || task.workflow_id,
    packet_digest: parsed.packetDigest || '',
    packet_mode: parsed.packetMode || '',
    memory_contract: contract,
    memory_read_receipt: receipt,
  };
}

function memoryContextDecision(policy, status) {
  return {
    mode: policy.mode,
    status,
    context_source: policy.context_source || 'story_memory',
    token_budget: policy.token_budget,
    accepts_memory_updates: policy.accepts_memory_updates,
    packet_json: '',
    packet_md: '',
    memory_contract: null,
    memory_read_receipt: null,
    blocking: false,
  };
}

function memoryContextFromStagePacket(policy, stageContextPacket) {
  const packet = stageContextPacket && typeof stageContextPacket === 'object' ? stageContextPacket : {};
  if (packet.status !== 'assembled' || !packet.packet_md || !packet.memory_read_receipt) {
    return {
      ...memoryContextDecision(policy, 'blocked_stage_memory_context_missing'),
      blocking: policy.mode === 'required',
      findings: [{
        field: 'stage_context_packet.memory_read_receipt',
        message: '当前阶段要求使用阶段上下文中的唯一记忆合同，但阶段包或读取回执缺失。',
      }],
    };
  }
  return {
    ...memoryContextDecision(policy, 'assembled'),
    context_source: 'stage_context',
    packet_json: String(packet.packet_json || ''),
    packet_md: String(packet.packet_md || ''),
    estimated_tokens: Number(packet.estimated_tokens || 0),
    memory_contract: packet.memory_contract || null,
    memory_read_receipt: packet.memory_read_receipt,
  };
}

function resolveProjectIdentity(root, task) {
  const embedded = task.project_identity && typeof task.project_identity === 'object'
    ? task.project_identity
    : {};
  let stored = {};
  try { stored = new StoryMemoryRepository(root).projectIdentity() || {}; } catch (_) { stored = {}; }
  return {
    project_id: String(embedded.project_id || stored.project_id || task.book_id || path.basename(root) || 'current-project'),
    project_instance_id: String(embedded.project_instance_id || stored.project_instance_id || ''),
  };
}

function memoryNeedsFor(workflowType) {
  if (/(?:scan|cover|setup)/u.test(String(workflowType || ''))) return ['user_preferences'];
  if (/(?:analyze|review|deslop)/u.test(String(workflowType || ''))) {
    return ['accepted_facts', 'review_dependencies', 'confirmed_quality_rules', 'user_preferences'];
  }
  return ['accepted_facts', 'active_cast', 'active_promises', 'confirmed_style_rules', 'confirmed_quality_rules', 'continuity_obligations', 'canon_constraints', 'user_preferences'];
}

function normalizeDigest(value) {
  const text = String(value || '').trim();
  return text.startsWith('sha256:') ? text : `sha256:${text}`;
}

function relativeProjectPath(root, file) {
  if (!file) return '';
  const absolute = path.resolve(String(file));
  const relative = path.relative(root, absolute);
  return relative && !relative.startsWith('..') && !path.isAbsolute(relative) ? relative : '';
}

module.exports = { memoryContextDecision, memoryContextFromStagePacket, prepareMemoryContext };
