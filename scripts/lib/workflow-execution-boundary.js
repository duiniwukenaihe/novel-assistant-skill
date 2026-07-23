'use strict';

const MODES = new Set(['managed_runner', 'cooperative_interactive']);
const ACTUAL_SOURCES = new Set(['host', 'provider']);

function normalizeMode(value) {
  return MODES.has(String(value || '')) ? String(value) : 'cooperative_interactive';
}

function capabilitiesFor(mode, options = {}) {
  const normalized = normalizeMode(mode);
  const runnerOwnedChild = options.runnerOwnedChild === true;
  const exactUsage = ACTUAL_SOURCES.has(String(options.usageSource || options.token_source || ''));
  if (normalized === 'managed_runner') {
    return {
      host_execution_mode: normalized,
      stream_abort: runnerOwnedChild,
      process_liveness: runnerOwnedChild,
      exact_usage: runnerOwnedChild && exactUsage,
      checkpoint: true,
      result_packet: true,
    };
  }
  return {
    host_execution_mode: 'cooperative_interactive',
    stream_abort: false,
    process_liveness: false,
    exact_usage: false,
    checkpoint: true,
    result_packet: true,
  };
}

function visibleModeLabel(mode) {
  return normalizeMode(mode) === 'managed_runner' ? '托管运行' : '协作模式';
}

function visibleCostSource(source) {
  const value = String(source || '');
  if (ACTUAL_SOURCES.has(value)) return '宿主实测';
  if (value === 'estimated') return '代理估算';
  return '不可用';
}

function normalizeExecutionBoundary(value = {}) {
  const mode = normalizeMode(value.host_execution_mode || value.hostExecutionMode);
  const tokenSource = String(value.token_source || value.tokenSource || 'unavailable');
  return {
    host_execution_mode: mode,
    capabilities: capabilitiesFor(mode, {
      runnerOwnedChild: value.runnerOwnedChild === true,
      usageSource: tokenSource,
    }),
    token_source: tokenSource,
    visible_execution_mode: visibleModeLabel(mode),
    visible_cost_source: visibleCostSource(tokenSource),
  };
}

module.exports = {
  capabilitiesFor,
  normalizeExecutionBoundary,
  normalizeMode,
  visibleCostSource,
  visibleModeLabel,
};
