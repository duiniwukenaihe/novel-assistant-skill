#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MODULE="$REPO/scripts/lib/workflow-execution-boundary.js"
}

@test "managed runner capabilities require a runner-owned child handle" {
    node - "$MODULE" <<'NODE'
const boundary = require(process.argv[2]);
const withChild = boundary.capabilitiesFor('managed_runner', { runnerOwnedChild: true, usageSource: 'host' });
if (!withChild.stream_abort || !withChild.process_liveness || !withChild.exact_usage || !withChild.checkpoint || !withChild.result_packet) {
  throw new Error(JSON.stringify(withChild));
}
const withoutChild = boundary.capabilitiesFor('managed_runner', { runnerOwnedChild: false, usageSource: 'host' });
if (withoutChild.stream_abort || withoutChild.process_liveness) throw new Error(JSON.stringify(withoutChild));
if (!withoutChild.checkpoint || !withoutChild.result_packet) throw new Error(JSON.stringify(withoutChild));
NODE
}

@test "cooperative interactive mode never claims stream abort process liveness or exact usage" {
    node - "$MODULE" <<'NODE'
const boundary = require(process.argv[2]);
const caps = boundary.capabilitiesFor('cooperative_interactive', { runnerOwnedChild: true, usageSource: 'host' });
if (caps.stream_abort || caps.process_liveness || caps.exact_usage) throw new Error(JSON.stringify(caps));
if (!caps.checkpoint || !caps.result_packet) throw new Error(JSON.stringify(caps));
if (boundary.visibleModeLabel('cooperative_interactive') !== '协作模式') throw new Error('bad cooperative label');
if (boundary.visibleModeLabel('managed_runner') !== '托管运行') throw new Error('bad managed label');
NODE
}

@test "cost source labels never promote estimates to host measured usage" {
    node - "$MODULE" <<'NODE'
const boundary = require(process.argv[2]);
if (boundary.visibleCostSource('host') !== '宿主实测') throw new Error('host label');
if (boundary.visibleCostSource('provider') !== '宿主实测') throw new Error('provider label');
if (boundary.visibleCostSource('estimated') !== '代理估算') throw new Error('estimated label');
if (boundary.visibleCostSource('unavailable') !== '不可用') throw new Error('unavailable label');
const event = boundary.normalizeExecutionBoundary({ host_execution_mode: 'cooperative_interactive', token_source: 'estimated' });
if (event.visible_execution_mode !== '协作模式' || event.visible_cost_source !== '代理估算') throw new Error(JSON.stringify(event));
NODE
}
