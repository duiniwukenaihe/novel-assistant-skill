#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MODULE="$REPO/scripts/lib/workflow-stream-health.js"
}

@test "stream health monitor keeps normal incremental output healthy" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ idleTimeoutMs: 1000 });
monitor.ingest('stdout', '正在读取第 1-20 章索引。\n', 100);
monitor.ingest('stdout', '已完成人物状态核对，发现两个待复核点。\n', 200);
const snapshot = monitor.snapshot(300);
if (snapshot.status !== 'healthy') throw new Error(JSON.stringify(snapshot));
if (monitor.shouldAbort(300)) throw new Error('normal output should continue');
NODE
}

@test "stream health monitor aborts a Chinese phrase loop before output grows" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ maxRepeatedTerm: 8 });
monitor.ingest('stdout', '修真修真修真修真修真修真修真修真修真', 100);
const snapshot = monitor.snapshot(110);
if (!monitor.shouldAbort(110)) throw new Error(JSON.stringify(snapshot));
if (snapshot.stop_reason !== 'model_degradation_repeated_term') throw new Error(JSON.stringify(snapshot));
NODE
}

@test "stream health monitor aborts repeated lines across chunks" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ maxRepeatedLine: 3 });
for (let i = 0; i < 4; i += 1) monitor.ingest('stdout', '继续读取当前章节并整理证据。\n', 100 + i);
const snapshot = monitor.snapshot(200);
if (snapshot.stop_reason !== 'model_degradation_repeated_line') throw new Error(JSON.stringify(snapshot));
NODE
}

@test "stream health monitor aborts repeated tool parameter failures" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ maxToolFailure: 2 });
monitor.ingest('stderr', 'Invalid tool parameters\n', 100);
monitor.ingest('stderr', 'Invalid tool parameters\n', 101);
monitor.ingest('stderr', 'Invalid tool parameters\n', 102);
const snapshot = monitor.snapshot(200);
if (snapshot.stop_reason !== 'tool_failure_loop') throw new Error(JSON.stringify(snapshot));
NODE
}

@test "stream health monitor aborts provider retry loops" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ maxProviderFailure: 2 });
monitor.ingest('stderr', 'API Error: output new_sensitive (1027) · Retrying attempt 1/10\n', 100);
monitor.ingest('stderr', 'API Error: output new_sensitive (1027) · Retrying attempt 2/10\n', 101);
monitor.ingest('stderr', 'API Error: output new_sensitive (1027) · Retrying attempt 3/10\n', 102);
const snapshot = monitor.snapshot(200);
if (snapshot.stop_reason !== 'provider_failure_loop') throw new Error(JSON.stringify(snapshot));
NODE
}

@test "stream health monitor aborts Codex reconnect timeout loops" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ maxProviderFailure: 1 });
monitor.ingest('stdout', 'Reconnecting... 2/5 (request timed out)\n', 100);
monitor.ingest('stdout', 'Reconnecting... 3/5 (request timed out)\n', 101);
const snapshot = monitor.snapshot(200);
if (snapshot.stop_reason !== 'provider_failure_loop') throw new Error(JSON.stringify(snapshot));
NODE
}

@test "stream health monitor classifies a host budget cap as a recoverable budget stop" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor();
monitor.start(0);
monitor.ingest('stdout', '{"type":"result","subtype":"error_max_budget_usd"}', 10);
if (!monitor.shouldAbort(10)) throw new Error('budget cap must stop the run');
if (monitor.snapshot(10).stop_reason !== 'budget_exhausted') throw new Error(JSON.stringify(monitor.snapshot(10)));
NODE
}

@test "stream health monitor reports idle timeout only after output has started" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ idleTimeoutMs: 500 });
if (monitor.shouldAbort(10000)) throw new Error('not-started stream must not time out');
monitor.ingest('stdout', '开始执行。\n', 100);
if (monitor.shouldAbort(599)) throw new Error('too early');
if (!monitor.shouldAbort(601)) throw new Error('idle stream should stop');
if (monitor.snapshot(601).stop_reason !== 'idle_timeout') throw new Error(JSON.stringify(monitor.snapshot(601)));
NODE
}

@test "stream health monitor can start an idle clock before the first output" {
    node - "$MODULE" <<'NODE'
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor({ idleTimeoutMs: 100 });
monitor.start(1000);
if (monitor.shouldAbort(1099)) throw new Error('too early');
if (!monitor.shouldAbort(1101)) throw new Error('silent started stream should stop');
if (monitor.snapshot(1101).stop_reason !== 'idle_timeout') throw new Error(JSON.stringify(monitor.snapshot(1101)));
NODE
}
