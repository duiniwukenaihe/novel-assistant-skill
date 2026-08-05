'use strict';

const crypto = require('crypto');
const { validateStageResult } = require('./contracts');

// SHA-256 over the four-field binding the renderer/consumer must honor.
// `state_version` here is the TARGET COMMITTED version, not the prepared
// task's current version, so the bound promise can be checked after commit.
function digestBinding(pending) {
  const binding = {
    workflow_id: pending.workflow_id,
    state_version: pending.state_version,
    question: pending.question,
    options: pending.options.map((option) => ({
      action_id: option.action_id,
      label: option.label,
      number: option.number,
    })),
  };
  return crypto.createHash('sha256').update(JSON.stringify(binding)).digest('hex');
}

// Persistence-before-render: produces ONLY a pending action (no visible text).
// Stable option numbers are assigned here, never accepted from the stage result.
function prepareInteraction(task, result) {
  const checked = validateStageResult(result);
  if (checked.kind !== 'needs_author_choice') return { pending_action: null };

  const targetVersion = Number(task.state_version) + 1;
  const options = checked.options.map((option, index) => Object.freeze({ ...option, number: index + 1 }));

  const pending = {
    id: `pa-v3-${task.workflow_id}-${targetVersion}`,
    status: 'pending',
    workflow_id: task.workflow_id,
    state_version: targetVersion,
    question: checked.question,
    options,
    created_at: new Date().toISOString(),
  };
  pending.visible_choice_hash = digestBinding(pending);

  return { pending_action: Object.freeze(pending) };
}

// Assert the committed task still honors its own binding before any render or
// consume. Status must be pending, the stored version must equal the committed
// version, and the hash must recompute exactly.
function assertCommittedBinding(task) {
  const pending = task.pending_action;
  if (!pending) throw new Error('pending_action_missing');
  if (pending.status !== 'pending') throw new Error('pending_action_not_pending');
  if (String(pending.workflow_id) !== String(task.workflow_id)) {
    throw new Error('binding_workflow_mismatch');
  }
  if (Number(pending.state_version) !== Number(task.state_version)) {
    throw new Error('binding_version_mismatch');
  }
  if (pending.visible_choice_hash !== digestBinding(pending)) {
    throw new Error('binding_hash_mismatch');
  }
}

function renderCommittedInteraction(task) {
  assertCommittedBinding(task);
  const pending = task.pending_action;
  const lines = pending.options.map((option) => `${option.number}. ${option.label}`);
  const text = `${pending.question}\n${lines.join('\n')}`;
  // Surface ONLY the Arbiter-owned binding metadata so later hosts and Engine
  // forward exactly these four fields alongside the rendered text.
  const binding = Object.freeze({
    workflow_id: pending.workflow_id,
    state_version: pending.state_version,
    pending_action_id: pending.id,
    visible_choice_hash: pending.visible_choice_hash,
  });
  return Object.freeze({ text, binding });
}

function consumeBinding(task, input) {
  assertCommittedBinding(task);
  const pending = task.pending_action;
  const number = Number(input);
  if (!Number.isInteger(number) || number < 1 || number > pending.options.length) {
    throw new Error('author_choice_number_out_of_range');
  }
  const selected = pending.options[number - 1];
  return Object.freeze({
    action_id: selected.action_id,
    label: selected.label,
    number: selected.number,
  });
}

module.exports = {
  digestBinding,
  prepareInteraction,
  renderCommittedInteraction,
  consumeBinding,
};
