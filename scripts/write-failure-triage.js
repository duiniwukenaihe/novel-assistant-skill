#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const USAGE = `Usage: node write-failure-triage.js --target path [--log-file path] [--project-root dir] [--write] [--json]

Classifies Write/Edit/MultiEdit failures without retrying the same fragile tool call.`;

function parseArgs(argv) {
  const args = { target: '', logFile: '', projectRoot: '', write: false, json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--target') args.target = argv[++i] || '';
    else if (arg === '--log-file') args.logFile = argv[++i] || '';
    else if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--write') args.write = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }
  if (!args.target) fail('missing --target');
  return args;
}

function readLog(args) {
  if (args.logFile) return fs.readFileSync(args.logFile, 'utf8');
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function triage({ target, logText }) {
  const absTarget = path.resolve(target);
  const parent = path.dirname(absTarget);
  const parentInfo = inspectPath(parent);
  const targetInfo = inspectPath(absTarget);
  const writable = testWritable(parent, parentInfo.type);
  const log = String(logText || '');
  const findings = detectLogFindings(log);

  let status = 'blocked_write_missing_output';
  let category = 'write_failure_unclassified';

  if (parentInfo.type !== 'directory' || !writable.ok || hasFinding(findings, 'permission_denied')) {
    status = 'blocked_write_permission';
    category = 'filesystem_preflight';
  } else if (hasFinding(findings, 'tool_schema')) {
    status = 'blocked_write_tool_call_invalid';
    category = 'tool_call_schema_check';
  } else if (hasFinding(findings, 'hook_block')) {
    status = 'blocked_write_hook';
    category = 'hook_block';
  } else if (hasFinding(findings, 'old_string_not_found') || hasFinding(findings, 'missing_output')) {
    status = 'blocked_write_missing_output';
    category = 'missing_output_or_edit_conflict';
  }

  const result = {
    status,
    category,
    target: absTarget,
    parent,
    targetExists: targetInfo.exists,
    targetType: targetInfo.type,
    parentExists: parentInfo.exists,
    parentType: parentInfo.type,
    permissionWritable: Boolean(writable.ok),
    writableCheck: writable,
    currentUser: os.userInfo().username,
    cwd: process.cwd(),
    findings,
    hookNames: extractHookNames(log),
    recovery: buildRecovery(status, category, absTarget, parent),
  };

  return result;
}

function inspectPath(absPath) {
  try {
    const stat = fs.lstatSync(absPath);
    return {
      exists: true,
      type: stat.isDirectory() ? 'directory' : stat.isFile() ? 'file' : stat.isSymbolicLink() ? 'symlink' : 'other',
      mode: `0${(stat.mode & 0o777).toString(8)}`,
      uid: stat.uid,
      gid: stat.gid,
      size: stat.size,
    };
  } catch (error) {
    return { exists: false, type: 'missing', error: error.code || error.message };
  }
}

function testWritable(parent, parentType) {
  if (parentType !== 'directory') {
    return { ok: false, reason: `parent is ${parentType}` };
  }
  const testFile = path.join(parent, `.write-test-${process.pid}-${Date.now()}.tmp`);
  try {
    fs.writeFileSync(testFile, 'ok\n', 'utf8');
    const text = fs.readFileSync(testFile, 'utf8');
    fs.unlinkSync(testFile);
    return { ok: text === 'ok\n', method: 'write-read-unlink' };
  } catch (error) {
    try {
      if (fs.existsSync(testFile)) fs.unlinkSync(testFile);
    } catch {
      // best-effort cleanup
    }
    return { ok: false, reason: error.code || error.message };
  }
}

function detectLogFindings(logText) {
  const rules = [
    {
      type: 'tool_schema',
      pattern: /(Invalid tool parameters|missing required parameter|参数不完整|file_path|content)/i,
      message: '工具调用参数不完整或 schema 错误，不是文件系统权限问题。',
    },
    {
      type: 'hook_block',
      pattern: /(PostToolUse|hook returned blocking error|\.claude\/hooks|usage:.*\.sh|ai-trace-detector\.sh|prose-quality-gate\.sh)/i,
      message: 'PostToolUse hook 或 hook usage 阻断了写入链路。',
    },
    {
      type: 'permission_denied',
      pattern: /(Permission denied|EACCES|EPERM|operation not permitted)/i,
      message: '权限或 ownership 导致写入失败。',
    },
    {
      type: 'old_string_not_found',
      pattern: /(old_string not found|Error editing file)/i,
      message: 'Edit/Update 目标锚点不匹配，应重新读取文件并改用恢复报告或最小补丁。',
    },
    {
      type: 'missing_output',
      pattern: /(FileNotFoundError|No such file or directory|写后读不到|目标文件不存在)/i,
      message: '目标文件缺失或写后无法确认存在。',
    },
    {
      type: 'write_error',
      pattern: /(Error writing file|Error editing file|Write\(|Update\(|Edit\()/i,
      message: '工具返回写入/编辑失败。',
    },
  ];

  const findings = [];
  for (const rule of rules) {
    const match = String(logText || '').match(rule.pattern);
    if (match) {
      findings.push({
        type: rule.type,
        phrase: match[0],
        message: rule.message,
      });
    }
  }
  return findings;
}

function hasFinding(findings, type) {
  return findings.some(finding => finding.type === type);
}

function extractHookNames(logText) {
  const hooks = new Set();
  const pattern = /(?:^|[\/\s"'])((?:ai-trace-detector|prose-quality-gate|[A-Za-z0-9_-]+)\.sh)(?=$|[\s"':<>\]])/gm;
  let match;
  while ((match = pattern.exec(String(logText || ''))) !== null) {
    hooks.add(match[1]);
  }
  return Array.from(hooks);
}

function buildRecovery(status, category, target, parent) {
  if (status === 'blocked_write_tool_call_invalid') {
    return {
      next: 'rebuild_write_tool_call',
      required: ['tool=Write/Edit', 'file_path must be non-empty', 'content or old_string/new_string must be non-empty'],
      retryLimit: 1,
    };
  }
  if (status === 'blocked_write_hook') {
    return {
      next: 'inspect_hook_stderr_and_fix_hook_or_payload',
      required: ['record hook name', 'do not reuse blocked draft as valid output', 'rerun gate after fix'],
      retryLimit: 1,
    };
  }
  if (status === 'blocked_write_permission') {
    return {
      next: 'fix_filesystem_before_writing',
      required: [`mkdir -p ${shellQuote(parent)}`, `sudo chown -R $(whoami):$(id -gn) ${shellQuote(findProjectRoot(target))}`],
      retryLimit: 0,
    };
  }
  return {
    next: 'write_timestamped_recovery_report',
    suggestedPath: path.join(parent, `恢复_${stamp()}.md`),
    retryLimit: 1,
  };
}

function writeRecord(projectRoot, result) {
  const root = projectRoot ? path.resolve(projectRoot) : process.cwd();
  const dir = path.join(root, '追踪', '写入失败分诊');
  fs.mkdirSync(dir, { recursive: true });
  const base = `${stamp()}_${result.status}`;
  const jsonPath = path.join(dir, `${base}.json`);
  const mdPath = path.join(dir, `${base}.md`);
  fs.writeFileSync(jsonPath, `${JSON.stringify(result, null, 2)}\n`, 'utf8');
  fs.writeFileSync(mdPath, renderMarkdown(result), 'utf8');
  return { jsonPath, mdPath };
}

function renderMarkdown(result) {
  return [
    '# 写入失败分诊',
    '',
    `- status: ${result.status}`,
    `- category: ${result.category}`,
    `- target: ${result.target}`,
    `- parentType: ${result.parentType}`,
    `- permissionWritable: ${result.permissionWritable}`,
    `- currentUser: ${result.currentUser}`,
    '',
    '## Findings',
    ...result.findings.map(finding => `- ${finding.type}: ${finding.phrase}`),
    '',
    '## Recovery',
    `- next: ${result.recovery.next}`,
    `- retryLimit: ${result.recovery.retryLimit}`,
  ].join('\n') + '\n';
}

function stamp() {
  return new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '_');
}

function findProjectRoot(target) {
  const parts = path.resolve(target).split(path.sep).filter(Boolean);
  const index = parts.findIndex(part => part === '追踪' || part === '正文' || part === '大纲');
  if (index > 0) return `${path.sep}${parts.slice(0, index).join(path.sep)}`;
  return path.dirname(path.resolve(target));
}

function shellQuote(value) {
  return `'${String(value || '').replace(/'/g, `'\\''`)}'`;
}

function fail(message) {
  console.error(message);
  console.error(USAGE);
  process.exit(2);
}

function main() {
  const args = parseArgs(process.argv);
  const logText = readLog(args);
  const result = triage({ target: args.target, logText });
  if (args.write) result.written = writeRecord(args.projectRoot, result);
  process.stdout.write(args.json ? `${JSON.stringify(result, null, 2)}\n` : renderMarkdown(result));
  process.exit(result.status === 'blocked_write_permission' ? 1 : 0);
}

if (require.main === module) main();

module.exports = { triage };
