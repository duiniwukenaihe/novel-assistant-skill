#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MODULE="$REPO/scripts/lib/workflow-host-adapters.js"
    TMP_DIR="$(mktemp -d)"
    mkdir -p "$TMP_DIR/书籍 项目"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "host adapters build shell-free Claude Code invocation" {
    node - "$MODULE" "$TMP_DIR/书籍 项目" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const invocation = adapters.buildAdapterInvocation('claude-code', {
  projectRoot: root,
  prompt: '执行阶段，不要重复正文。',
  runId: 'run-001',
  runnerPacket: '追踪/workflow/run.json',
  expectedResultPacket: '追踪/workflow/result.json',
  executableOverrides: { 'claude-code': '/opt/bin/claude' },
  maxBudgetUsd: 1.5,
});
if (invocation.command !== '/opt/bin/claude') throw new Error(invocation.command);
if (invocation.shell !== false) throw new Error('shell must be false');
if (invocation.cwd !== root) throw new Error(invocation.cwd);
if (!invocation.args.includes('--output-format') || !invocation.args.includes('stream-json')) throw new Error(invocation.args.join(' '));
if (!invocation.args.includes('--permission-mode') || !invocation.args.includes('acceptEdits')) throw new Error(invocation.args.join(' '));
if (!invocation.args.includes('--max-budget-usd') || !invocation.args.includes('1.5')) throw new Error(invocation.args.join(' '));
if (invocation.env.NOVEL_ASSISTANT_RUN_ID !== 'run-001') throw new Error('missing run id');
NODE
}

@test "host adapters preserve an explicit skill command in the relay prompt" {
    node - "$MODULE" "$TMP_DIR/书籍 项目" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const invocation = adapters.buildAdapterInvocation('claude-code', {
  projectRoot: root,
  prompt: '执行阶段。',
  skillCommand: '/novel-assistant',
  executableOverrides: { 'claude-code': '/opt/bin/claude' },
});
if (!invocation.args.some((arg) => String(arg).startsWith('/novel-assistant\nRead and follow'))) throw new Error(invocation.args.join(' '));
NODE
}

@test "host adapters build Codex invocation without dangerous approval bypass" {
    node - "$MODULE" "$TMP_DIR/书籍 项目" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const invocation = adapters.buildAdapterInvocation('codex', {
  projectRoot: root,
  prompt: '执行阶段。',
  executableOverrides: { codex: '/opt/bin/codex' },
});
if (invocation.command !== '/opt/bin/codex') throw new Error(invocation.command);
if (invocation.shell !== false) throw new Error('shell must be false');
if (invocation.args[0] !== 'exec') throw new Error(invocation.args.join(' '));
if (!invocation.args.includes('--json') || !invocation.args.includes('workspace-write')) throw new Error(invocation.args.join(' '));
if (invocation.args.some((arg) => /dangerously-bypass/.test(arg))) throw new Error('dangerous bypass present');
NODE
}

@test "host adapters allow an explicitly isolated Codex evaluation to enable network" {
    node - "$MODULE" "$TMP_DIR/书籍 项目" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const invocation = adapters.buildAdapterInvocation('codex', {
  projectRoot: root,
  prompt: '执行隔离验收。',
  sandbox: 'danger-full-access',
  executableOverrides: { codex: '/opt/bin/codex' },
});
const index = invocation.args.indexOf('--sandbox');
if (index < 0 || invocation.args[index + 1] !== 'danger-full-access') throw new Error(invocation.args.join(' '));
if (invocation.args.some((arg) => /dangerously-bypass/.test(arg))) throw new Error('dangerous bypass present');
NODE
}

@test "host adapters can isolate Codex evaluation from user MCP configuration" {
    node - "$MODULE" "$TMP_DIR/书籍 项目" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const invocation = adapters.buildAdapterInvocation('codex', {
  projectRoot: root,
  prompt: '执行隔离验收。',
  ignoreUserConfig: true,
  executableOverrides: { codex: '/opt/bin/codex' },
});
if (!invocation.args.includes('--ignore-user-config')) throw new Error(invocation.args.join(' '));
NODE
}

@test "host adapters use Node for a ZCode javascript entry point" {
    node - "$MODULE" "$TMP_DIR/书籍 项目" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const invocation = adapters.buildAdapterInvocation('zcode', {
  projectRoot: root,
  prompt: '执行阶段。',
  executableOverrides: { zcode: '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs' },
});
if (invocation.command !== process.execPath) throw new Error(invocation.command);
if (invocation.args[0] !== '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs') throw new Error(invocation.args.join(' '));
if (!invocation.args.includes('--mode') || !invocation.args.includes('edit')) throw new Error(invocation.args.join(' '));
if (invocation.args.includes('yolo')) throw new Error('yolo must not be default');
NODE
}

@test "host adapters allow an explicit ZCode isolated evaluation mode" {
    node - "$MODULE" "$TMP_DIR/书籍 项目" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const invocation = adapters.buildAdapterInvocation('zcode', {
  projectRoot: root,
  prompt: '执行隔离验收。',
  permissionMode: 'yolo',
  executableOverrides: { zcode: '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs' },
});
if (!invocation.args.includes('--mode') || !invocation.args.includes('yolo')) throw new Error(invocation.args.join(' '));
NODE
}

@test "auto adapter reports capabilities but never silently chooses a paid host" {
    node - "$MODULE" "$TMP_DIR" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
const detected = adapters.detectAdapters({
  executableOverrides: {
    'claude-code': '/bin/sh',
    codex: '/bin/sh',
    zcode: '/missing/zcode',
  },
});
if (detected.selected !== '') throw new Error('auto detection selected a host');
if (!detected.adapters['claude-code'].available) throw new Error('claude should be available');
if (detected.adapters.zcode.available) throw new Error('zcode should be unavailable');
let failed = false;
try {
  adapters.buildAdapterInvocation('auto', { projectRoot: root, prompt: 'x' });
} catch (error) {
  failed = /explicit adapter/.test(error.message);
}
if (!failed) throw new Error('auto invocation must fail closed');
NODE
}

@test "fake adapter requires an explicit fixture executable" {
    node - "$MODULE" "$TMP_DIR" <<'NODE'
const adapters = require(process.argv[2]);
const root = process.argv[3];
let failed = false;
try {
  adapters.buildAdapterInvocation('fake', { projectRoot: root, prompt: 'x' });
} catch (error) {
  failed = /fakeExecutable/.test(error.message);
}
if (!failed) throw new Error('fake adapter should require fixture');
NODE
}

@test "behavior evaluation host aliases resolve to explicit adapters" {
    node - "$MODULE" <<'NODE'
const adapters = require(process.argv[2]);
if (adapters.resolveEvaluationAdapter('claude') !== 'claude-code') throw new Error('claude alias missing');
if (adapters.resolveEvaluationAdapter('codex') !== 'codex') throw new Error('codex alias missing');
if (adapters.resolveEvaluationAdapter('zcode') !== 'zcode') throw new Error('zcode alias missing');
let failed = false;
try {
  adapters.resolveEvaluationAdapter('auto');
} catch (error) {
  failed = /unsupported evaluation host/.test(error.message);
}
if (!failed) throw new Error('unknown evaluation host must fail closed');
NODE
}

@test "host adapters keep detailed prompts out of argv and inherit only allowlisted environment" {
    node - "$MODULE" "$TMP_DIR" <<'NODE'
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const adapters = require(process.argv[2]);
const root = process.argv[3];
process.env.EVAL_SECRET_SHOULD_NOT_LEAK = 'sk-test-abcdefghijklmnopqrstuv';
const invocation = adapters.buildAdapterInvocation('claude-code', {
  projectRoot: root,
  prompt: 'Bearer top-secret-token EVAL_SECRET_SHOULD_NOT_LEAK',
  runId: 'paid-run-001',
  runnerPacket: '.behavior-eval/scenario.json',
  expectedResultPacket: '.behavior-eval/result.json',
  executableOverrides: { 'claude-code': '/bin/sh' },
});
assert.equal(invocation.args.some((arg) => arg.includes('top-secret-token')), false);
assert.equal(invocation.env.EVAL_SECRET_SHOULD_NOT_LEAK, undefined);
assert.ok(invocation.env.NOVEL_ASSISTANT_PROMPT_FILE);
assert.equal(invocation.args.some((arg) => arg.includes(invocation.env.NOVEL_ASSISTANT_PROMPT_FILE)), true);
assert.equal(fs.readFileSync(invocation.env.NOVEL_ASSISTANT_PROMPT_FILE, 'utf8').includes('top-secret-token'), true);
assert.equal(fs.statSync(invocation.env.NOVEL_ASSISTANT_PROMPT_FILE).mode & 0o777, 0o600);
assert.equal(path.dirname(invocation.env.NOVEL_ASSISTANT_PROMPT_FILE).startsWith(root), true);
NODE
}

@test "host usage selects terminal cumulative snapshots and reports invalid optional metrics" {
    node - "$MODULE" <<'NODE'
const assert = require('assert/strict');
const adapters = require(process.argv[2]);
const cumulative = adapters.normalizeHostUsage('fake', [
  { usage: { input_tokens: 10, output_tokens: 5, cache_read_tokens: 1 } },
  { usage: { input_tokens: 30, output_tokens: 9, cache_read_tokens: 3 } },
], 20, { outputChars: 100 });
assert.equal(cumulative.token_source, 'host');
assert.equal(cumulative.input_tokens, 30);
assert.equal(cumulative.output_tokens, 9);
assert.equal(cumulative.snapshot_strategy, 'terminal_cumulative');
const invalid = adapters.normalizeHostUsage('fake', [
  { usage: { input_tokens: 10, output_tokens: 5, cache_read_tokens: -2, duration_ms: 'NaN' } },
], 20, { outputChars: 100 });
assert.equal(invalid.token_source, 'estimated');
assert.ok(invalid.findings.some((item) => item.code === 'invalid_host_usage_metric'));
NODE
}

@test "short section compact context: buildStageContextPacket only carries brief/anchor/plan/voice for the drafted section" {
    node - "$MODULE" "$TMP_DIR/book" <<'NODE'
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const adapters = require(process.argv[2]);
const root = process.argv[3];

// Project fixtures: a private short story at section 6, with prior sections accepted.
fs.mkdirSync(path.join(root, '素材'), { recursive: true });
fs.writeFileSync(path.join(root, '素材卡.md'), '# 素材\n核心素材：复仇线\n');
fs.writeFileSync(path.join(root, '设定.md'), '# 设定\n第三人称。共6节。主节奏：钩子-压力-反转。\n');
fs.writeFileSync(path.join(root, '小节大纲.md'),
  '# 小节大纲\n' +
  Array.from({ length: 6 }, (_, i) => `## 第${i + 1}节\n结构功能：起承转合\n情绪目标：紧张\n因果链：A→B\n节尾钩子：悬念${i + 1}\n`).join('\n')
);
fs.writeFileSync(path.join(root, '写作Brief_第006节.md'),
  '# 写作Brief 第006节\nPOV：第三人称\n主角能动性：反击\n节尾：兑现钩子\n');
fs.mkdirSync(path.join(root, '追踪/private-short-extension'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/private-short-extension/section-005-anchor.json'),
  JSON.stringify({ workflow_id: 'wf-short-sixth', section_index: 5, status: 'accepted', canonical_path: '正文.md', quality_result: { machine_gate: 'pass' } }, null, 2));
fs.writeFileSync(path.join(root, '正文.md'),
  Array.from({ length: 5 }, (_, i) => `第${i + 1}节正文，含承接收束。`).join('\n') + '\n');
fs.writeFileSync(path.join(root, '风格卡.md'), '# 风格卡\n冷峻、克制、短句\n');

// Disallowed noise that the packet MUST NOT include.
fs.mkdirSync(path.join(root, '追踪/workflow/tasks/wf-short-sixth'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/workflow/tasks/wf-short-sixth/journal.jsonl'),
  '{"type":"old_chat","text":"历史 debug 转录应当被排除"}\n');
fs.mkdirSync(path.join(root, '追踪/workflow/tasks/wf-short-sixth/result-packets'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/workflow/tasks/wf-short-sixth/result-packets/draft_next_section.result.json'),
  JSON.stringify({ legacy: '历史 result packet 应当排除' }));
fs.writeFileSync(path.join(root, '写作Brief_第005节.md'), '# 旧 Brief 5\n不得泄露进入第6节正文\n');

// task fixture: workflow_type short_write, runtime_guard.token_estimate.context_chars_budget drives the char budget.
const task = {
  workflow_id: 'wf-short-sixth',
  workflow_type: 'short_write',
  workflow_profile: 'private',
  workflow_owner: 'private-short-extension',
  scope: '第6节',
  current_stage: 'draft_next_section',
  task_dir: '追踪/workflow/tasks/wf-short-sixth',
  runtime_guard: { token_estimate: { context_chars_budget: 1200 } },
};
const stageContext = adapters.buildStageContextPacket({
  projectRoot: root,
  task,
  stage: 'draft_next_section',
});
assert.equal(stageContext.status, 'assembled', `status=${stageContext.status} detail=${JSON.stringify(stageContext).slice(0, 400)}`);
assert.ok(stageContext.packet_md, 'packet_md path missing');
assert.ok(stageContext.packet_json, 'packet_json path missing');
assert.ok(Array.isArray(stageContext.source_files), 'source_files missing');

const packetPath = path.join(root, stageContext.packet_md);
assert.ok(fs.existsSync(packetPath), `packet_md file missing: ${packetPath}`);
const packetText = fs.readFileSync(packetPath, 'utf8');

// Allowed assets MUST appear.
assert.match(packetText, /写作Brief_第006节\.md/, 'current Brief must be referenced or inlined');
assert.match(packetText, /section-005-anchor\.json/, 'previous accepted anchor must be referenced or inlined');
assert.match(packetText, /设定|小节大纲/, 'plan summary must be present');

// Forbidden assets MUST NOT appear as inline content.
assert.doesNotMatch(packetText, /workflow-state-machine\.js/, 'script source must not be inlined');
assert.doesNotMatch(packetText, /journal\.jsonl/, 'task journal must not be inlined');
assert.doesNotMatch(packetText, /历史 debug 转录/, 'old chat transcription must not leak');
assert.doesNotMatch(packetText, /legacy result packet/, 'legacy result packet must not leak');
assert.doesNotMatch(packetText, /写作Brief_第005节/, 'previous Brief must not leak');
assert.doesNotMatch(packetText, /旧 Brief 5/, 'previous Brief content must not leak');

// The char budget from runtime_guard.token_estimate.context_chars_budget caps inline material.
assert.ok(packetText.length <= 1200 * 4, `packet not budget-aware, length=${packetText.length}`);
assert.ok(Number(stageContext.estimated_tokens) > 0, 'estimated_tokens should be positive');

// packet metadata must explicitly enumerate allowed files only.
const metaPath = path.join(root, stageContext.packet_json);
const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
const allowedIds = meta.source_files.map((item) => String(item.id || item.path || ''));
assert.ok(allowedIds.some((id) => /写作Brief_第006节/.test(id)), `Brief not enumerated: ${JSON.stringify(allowedIds)}`);
assert.ok(allowedIds.some((id) => /section-005-anchor/.test(id)), `anchor not enumerated: ${JSON.stringify(allowedIds)}`);
assert.ok(!allowedIds.some((id) => /journal\.jsonl/.test(id)), `journal leaked into metadata: ${JSON.stringify(allowedIds)}`);
assert.ok(!allowedIds.some((id) => /result-packets/.test(id)), `result packet leaked into metadata: ${JSON.stringify(allowedIds)}`);
NODE
}

@test "short quality context keeps review evidence and drops drafting-only microbeats and plan summaries" {
    node - "$MODULE" "$TMP_DIR/book" <<'NODE'
const assert=require('assert/strict'),fs=require('fs'),path=require('path');
const adapters=require(process.argv[2]);const root=process.argv[3];
fs.mkdirSync(path.join(root,'追踪/private-short-extension'),{recursive:true});
fs.writeFileSync(path.join(root,'写作Brief_第006节.md'),`# Brief\n\n## 本节任务\n- 逼问哥哥。\n\n## 因果节拍与字数分配\n### 0-300字：不应进入质量包\n1. 微节拍一。\n\n## 上节承接锁定\n- 档案室对峙。\n\n## 视角与称谓\n- 第一人称。\n\n## 主角动作与关系变化\n- 主动出示证据。\n\n## 禁止漂移\n- 不改人物。\n\n## 节尾钩子\n- 父亲夹页。\n\n## 验收标准\n- 因果成立。\n`);
fs.writeFileSync(path.join(root,'草稿_第006节_候选.md'),'### 第六节\n\n我把合同推到哥哥面前。\n');
fs.writeFileSync(path.join(root,'设定.md'),'# 设定\n不应重复注入质量门。\n');
fs.writeFileSync(path.join(root,'小节大纲.md'),'# 大纲\n不应重复注入质量门。\n');
fs.writeFileSync(path.join(root,'素材卡.md'),'# 素材\n不应重复注入质量门。\n');
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({working_title:'测试',current_section_index:6}));
fs.writeFileSync(path.join(root,'追踪/private-short-extension/section-005-anchor.json'),JSON.stringify({workflow_id:'wf-quality',section_index:5,status:'accepted',canonical_path:'正文.md'}));
const task={workflow_id:'wf-quality',workflow_type:'short_write',scope:'第6节',current_stage:'quality_gate',task_dir:'追踪/workflow/tasks/wf-quality'};
const packet=adapters.buildStageContextPacket({projectRoot:root,task,stage:'quality_gate'});
assert.equal(packet.status,'assembled');
const text=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
assert.match(text,/我把合同推到哥哥面前/);
assert.match(text,/父亲夹页/);
assert.doesNotMatch(text,/0-300字：不应进入质量包/);
assert.doesNotMatch(text,/不应重复注入质量门/);
assert.ok(!packet.source_files.some(item=>item.kind==='plan_summary'),JSON.stringify(packet.source_files));
NODE
}

@test "short section compact context: ignores non-short and non-draft stages with status not_applicable" {
    node - "$MODULE" "$TMP_DIR/book" <<'NODE'
const assert = require('assert/strict');
const adapters = require(process.argv[2]);
const notShort = adapters.buildStageContextPacket({
  projectRoot: '/tmp',
  task: { workflow_type: 'long_write', scope: '第1卷/第003章', task_dir: 't' },
  stage: 'chapter_brief',
});
assert.equal(notShort.status, 'not_applicable');

const shortButNotDraft = adapters.buildStageContextPacket({
  projectRoot: '/tmp',
  task: { workflow_type: 'short_write', scope: '第1节', task_dir: 't' },
  stage: 'section_machine_gate',
});
assert.equal(shortButNotDraft.status, 'not_applicable');
NODE
}

@test "short section compact context: host guidance composes an advisory without claiming to break Claude thinking" {
    node - "$MODULE" <<'NODE'
const assert = require('assert/strict');
const adapters = require(process.argv[2]);
const guidance = adapters.composeStageContextGuidance({
  status: 'assembled',
  packet_md: '追踪/workflow/tasks/wf-x/context-packets/draft_next_section/a/stage-context.md',
  source_files: [
    { id: '写作Brief_第006节.md' },
    { id: '追踪/private-short-extension/section-005-anchor.json' },
  ],
});
assert.match(guidance, /stage-context\.md/);
assert.match(guidance, /写作Brief_第006节\.md/);
assert.match(guidance, /section-005-anchor\.json/);
// advisory must NOT claim to interrupt hidden thinking — that is impossible.
assert.doesNotMatch(guidance, /中断.*thinking|打断.*思考|break.*hidden thinking/i);
NODE
}
