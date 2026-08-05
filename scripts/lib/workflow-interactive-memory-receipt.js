'use strict';

const { validateMemoryReadReceipt } = require('./memory-query-contract');
const { StoryMemoryRepository } = require('./story-memory-repository');

function validateInteractiveMemoryReceipt(projectRoot, task, result) {
  if (String((result || {}).step_status || '') !== 'completed') return null;
  const execution = task && task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : {};
  if (String((result || {}).host_execution_mode || execution.host_execution_mode || '') === 'managed_runner') return null;
  if (Number(execution.memory_contract_version || 0) < 2) return null;

  const policy = execution.memory_contract && typeof execution.memory_contract === 'object'
    ? execution.memory_contract
    : {};
  const memoryContext = execution.memory_context && typeof execution.memory_context === 'object'
    ? execution.memory_context
    : {};
  const contract = memoryContext.memory_contract && typeof memoryContext.memory_contract === 'object'
    ? memoryContext.memory_contract
    : null;
  const expected = memoryContext.memory_read_receipt && typeof memoryContext.memory_read_receipt === 'object'
    ? memoryContext.memory_read_receipt
    : null;
  const receiptRequired = policy.receipt_required === true
    || Boolean(contract && contract.read_receipt_required !== false);
  if (!receiptRequired) return null;
  if (!contract || !expected || String(memoryContext.status || '') !== 'assembled') {
    return blocked('blocked_interactive_memory_context_missing', '交互阶段缺少启动时绑定的记忆合同，不能接受该阶段结果。');
  }

  const receipt = result.memory_read_receipt;
  const validation = validateMemoryReadReceipt(contract, receipt);
  const staleFields = Array.isArray(validation.stale_fields) ? validation.stale_fields.slice() : [];
  if (validation.status === 'current' && expected.source_digests && typeof expected.source_digests === 'object') {
    const echoed = receipt && receipt.source_digests && typeof receipt.source_digests === 'object'
      ? receipt.source_digests
      : {};
    for (const key of Object.keys(expected.source_digests)) {
      if (String(echoed[key] || '') !== String(expected.source_digests[key] || '')) staleFields.push(`source_digests.${key}`);
    }
  }
  if (validation.status !== 'current' || staleFields.length > 0) {
    return blocked(
      'blocked_interactive_memory_receipt_invalid',
      '阶段结果没有完整回显本次交互运行实际读取的记忆合同，不能证明使用了当前作品记忆。',
      { memory_status: validation.status, stale_fields: unique(staleFields) },
    );
  }

  let currentDigests = {};
  try { currentDigests = new StoryMemoryRepository(projectRoot).sourceRevisions(); } catch (_) { currentDigests = {}; }
  const expectedDigests = expected.source_digests && typeof expected.source_digests === 'object'
    ? expected.source_digests
    : {};
  const staleSources = unique([...Object.keys(expectedDigests), ...Object.keys(currentDigests)])
    .filter((key) => String(expectedDigests[key] || '') !== String(currentDigests[key] || ''));
  if (staleSources.length > 0) {
    return blocked(
      'blocked_interactive_memory_context_stale',
      '阶段执行期间作品记忆已经变化，必须重建最小上下文后复核当前阶段。',
      { stale_sources: staleSources },
    );
  }
  return null;
}

function blocked(status, message, details = {}) {
  return {
    schemaVersion: '1.0.0',
    status,
    message,
    findings: [{ field: 'memory_read_receipt', message, ...details }],
  };
}

function unique(values) {
  return [...new Set((Array.isArray(values) ? values : []).map(String).filter(Boolean))];
}

module.exports = { validateInteractiveMemoryReceipt };
