'use strict';

// Public CLI commands are a compatibility contract. Keep dispatch and lock
// classification here so the state-machine facade cannot silently drift.
const PUBLIC_COMMANDS = Object.freeze([
  'templates',
  'create',
  'inspect',
  'task-overview',
  'resolve-action',
  'apply-result',
  'next-candidates',
  'switch-intent',
  'activate',
  'migrate-legacy',
  'migrate-longform-successor',
  'reset-incompatible-review-batches',
  'continue-review-with-legacy-evidence',
  'restore-incomplete-workflow',
  'reset-unmanaged-review-repair',
  'reconcile-runtime',
  'refresh-short-title-lock',
  'resume-pending-short-feedback',
  'discard-short-feedback-item',
  'reclassify-short-feedback-item',
  'migrate-short-lean-workflow',
]);

const MUTATING_COMMANDS = new Set([
  'create',
  'resolve-action',
  'apply-result',
  'switch-intent',
  'activate',
  'migrate-legacy',
  'migrate-longform-successor',
  'reset-incompatible-review-batches',
  'continue-review-with-legacy-evidence',
  'restore-incomplete-workflow',
  'reset-unmanaged-review-repair',
  'reconcile-runtime',
  'refresh-short-title-lock',
  'resume-pending-short-feedback',
  'discard-short-feedback-item',
  'reclassify-short-feedback-item',
  'migrate-short-lean-workflow',
]);

function isPublicCommand(command) {
  return PUBLIC_COMMANDS.includes(String(command || ''));
}

function isMutatingCommand(command) {
  return MUTATING_COMMANDS.has(String(command || ''));
}

function dispatchCommand(command, handlers) {
  const handler = handlers && handlers[String(command || '')];
  if (typeof handler !== 'function') throw new Error(`workflow command is not registered: ${command}`);
  return handler();
}

module.exports = {
  PUBLIC_COMMANDS,
  isPublicCommand,
  isMutatingCommand,
  dispatchCommand,
};
