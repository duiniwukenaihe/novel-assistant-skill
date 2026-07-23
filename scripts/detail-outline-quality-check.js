#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { evaluateDetailOutline, mergeSemanticReview, normalizeChapterPosition } = require('./lib/detail-outline-quality');

const PROTOCOL_VERSION = '2.0.0';
const USAGE = 'Usage: node scripts/detail-outline-quality-check.js --project-root <book-dir> --outline <relative-path> [--workflow-id <id>] [--stage-id detail_outline_review] [--chapter-position <position>] [--semantic-review <workflow-relative-path>] [--write-result <relative-path> --reuse-result] --json';

let args = errorArgs(process.argv.slice(2));
try {
  args = parseArgs(process.argv.slice(2));
  if (args.helpRequested) {
    process.stdout.write(`${JSON.stringify(helpEnvelope(args), null, 2)}\n`);
    process.exit(0);
  }
  const root = realRoot(args.projectRoot);
  const outlineFile = containedPath(root, args.outline, true, 'outline');
  const text = fs.readFileSync(outlineFile, 'utf8');
  const relativeOutline = path.relative(root, outlineFile).split(path.sep).join('/');
  let quality = evaluateDetailOutline({
    text,
    workflowId: args.workflowId,
    stageId: args.stageId,
    outlinePath: relativeOutline,
    chapterPosition: args.chapterPosition,
    workflowMetadata: args.workflowMetadata,
  });
  if (args.semanticReview) {
    const semanticFile = workflowSemanticReviewPath(root, args.semanticReview, args.workflowId);
    quality = mergeSemanticReview(quality, readSemanticReview(semanticFile));
  } else if (accepted(quality.status)) {
    quality = awaitingSemanticReview(quality);
  }
  let packet = buildEnvelope(relativeOutline, quality, args);
  let reused = false;
  if (args.writeResult) {
    const resultFile = workflowResultPath(root, args.writeResult, args.workflowId);
    const resultPath = path.relative(root, resultFile).split(path.sep).join('/');
    if (fs.existsSync(resultFile)) {
      const existing = readResultPacket(resultFile);
      validateExistingOutline(existing, relativeOutline);
      if (args.reuseResult && validateReusableResult(existing, args, quality, relativeOutline)) {
        packet = reusedPacket(existing);
        reused = true;
      }
    }
    if (!reused) packet.result_packet_path = resultPath;
    atomicWritePacket(resultFile, packet);
  }
  process.stdout.write(`${JSON.stringify(packet, null, 2)}\n`);
  process.exit(accepted(packet.outputs.detail_outline_quality.status) ? 0 : 2);
} catch (error) {
  process.stdout.write(`${JSON.stringify(blockedErrorEnvelope(args, error), null, 2)}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const out = { projectRoot: '', outline: '', workflowId: '', stageId: 'detail_outline_review', chapterPosition: '', semanticReview: '', writeResult: '', reuseResult: false, json: false, helpRequested: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '';
    else if (arg === '--outline') out.outline = argv[++index] || '';
    else if (arg === '--workflow-id') out.workflowId = argv[++index] || '';
    else if (arg === '--stage-id') out.stageId = argv[++index] || 'detail_outline_review';
    else if (arg === '--chapter-position') out.chapterPosition = argv[++index] || '';
    else if (arg === '--semantic-review') out.semanticReview = argv[++index] || '';
    else if (arg === '--write-result') out.writeResult = argv[++index] || '';
    else if (arg === '--reuse-result') out.reuseResult = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') {
      out.helpRequested = true;
    } else {
      throw protocolError('unknown_argument', `unknown argument: ${arg}`);
    }
  }
  if (out.helpRequested) return out;
  if (!out.projectRoot || !out.outline) throw protocolError('missing_required_args', 'missing --project-root or --outline');
  if (path.isAbsolute(out.outline)) throw protocolError('outline_path_invalid', 'outline must be a relative path');
  if (out.semanticReview && path.isAbsolute(out.semanticReview)) throw protocolError('semantic_review_path_invalid', 'semantic-review must be a relative path');
  if (out.writeResult && path.isAbsolute(out.writeResult)) throw protocolError('result_packet_path_invalid', 'write-result must be a relative path');
  if (out.reuseResult && !out.writeResult) throw protocolError('reuse_requires_result', '--reuse-result requires --write-result');
  if (out.writeResult && !out.workflowId) throw protocolError('workflow_id_missing', 'workflow_id missing while --write-result is present');
  if (out.semanticReview && !out.workflowId) throw protocolError('workflow_id_missing', 'workflow_id missing while --semantic-review is present');
  return out;
}

function errorArgs(argv) {
  const out = { projectRoot: '', outline: '', workflowId: '', stageId: 'detail_outline_review', chapterPosition: '', semanticReview: '', writeResult: '', reuseResult: false, json: false, helpRequested: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '';
    else if (arg === '--outline') out.outline = argv[++index] || '';
    else if (arg === '--workflow-id') out.workflowId = argv[++index] || '';
    else if (arg === '--stage-id') out.stageId = argv[++index] || 'detail_outline_review';
    else if (arg === '--chapter-position') out.chapterPosition = argv[++index] || '';
    else if (arg === '--semantic-review') out.semanticReview = argv[++index] || '';
    else if (arg === '--write-result') out.writeResult = argv[++index] || '';
    else if (arg === '--reuse-result') out.reuseResult = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') out.helpRequested = true;
  }
  return out;
}

function realRoot(projectRoot) {
  try {
    return fs.realpathSync(path.resolve(projectRoot));
  } catch (_) {
    throw protocolError('project_root_missing', 'project root does not exist');
  }
}

function containedPath(root, relativePath, mustExist, label) {
  if (!relativePath || path.isAbsolute(relativePath)) throw protocolError(`${label.replace(/[^a-z]/g, '_')}_path_invalid`, `${label} must be a relative path`);
  const candidate = path.resolve(root, relativePath);
  if (!isInside(root, candidate)) throw protocolError(`${label.replace(/[^a-z]/g, '_')}_path_escape`, `${label} escapes project root`);
  const probe = existingAncestor(candidate);
  const realProbe = fs.realpathSync(probe);
  if (!isInside(root, realProbe)) throw protocolError(`${label.replace(/[^a-z]/g, '_')}_path_symlink`, `${label} escapes project root through a symlink`);
  if (mustExist) {
    let realCandidate;
    try {
      realCandidate = fs.realpathSync(candidate);
    } catch (_) {
      throw protocolError(`${label.replace(/[^a-z]/g, '_')}_missing`, `${label} does not exist`);
    }
    if (!isInside(root, realCandidate)) throw protocolError(`${label.replace(/[^a-z]/g, '_')}_path_symlink`, `${label} escapes project root through a symlink`);
    if (!fs.statSync(realCandidate).isFile()) throw protocolError(`${label.replace(/[^a-z]/g, '_')}_not_file`, `${label} is not a file`);
    return realCandidate;
  }
  if (fs.existsSync(candidate)) {
    const realCandidate = fs.realpathSync(candidate);
    if (!isInside(root, realCandidate)) throw protocolError(`${label.replace(/[^a-z]/g, '_')}_path_symlink`, `${label} escapes project root through a symlink`);
  }
  return candidate;
}

function existingAncestor(candidate) {
  let probe = candidate;
  while (!fs.existsSync(probe)) {
    const parent = path.dirname(probe);
    if (parent === probe) throw new Error('unable to resolve path');
    probe = parent;
  }
  return probe;
}

function isInside(root, target) {
  return target === root || target.startsWith(`${root}${path.sep}`);
}

function workflowResultPath(root, relativePath, workflowId) {
  if (!workflowId || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(workflowId)) {
    throw protocolError('workflow_id_invalid', 'workflow_id must be a safe result-packet directory name');
  }
  const resultFile = containedPath(root, relativePath, false, 'write-result');
  const resultDir = path.join(root, '追踪', 'workflow', 'tasks', workflowId, 'result-packets');
  if (!isInside(resultDir, resultFile) || resultFile === resultDir) {
    throw protocolError('result_packet_scope', 'write-result must be inside the workflow result-packets directory');
  }
  fs.mkdirSync(path.dirname(resultFile), { recursive: true });
  const realDirectory = fs.realpathSync(path.dirname(resultFile));
  if (realDirectory !== path.dirname(resultFile)) {
    throw protocolError('result_packet_symlink', 'write-result escapes workflow result-packets directory through a symlink');
  }
  if (fs.existsSync(resultFile) && fs.lstatSync(resultFile).isSymbolicLink()) {
    throw protocolError('result_packet_symlink', 'write-result must not be a symbolic link');
  }
  return resultFile;
}

function workflowSemanticReviewPath(root, relativePath, workflowId) {
  if (!workflowId || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(workflowId)) {
    throw protocolError('workflow_id_invalid', 'workflow_id must be a safe task directory name');
  }
  const semanticFile = containedPath(root, relativePath, true, 'semantic-review');
  const workDir = path.join(root, '追踪', 'workflow', 'tasks', workflowId, 'work');
  if (!isInside(workDir, semanticFile) || semanticFile === workDir) {
    throw protocolError('semantic_review_scope', 'semantic-review must be inside the owning workflow work directory');
  }
  return semanticFile;
}

function readSemanticReview(file) {
  try {
    const review = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!review || typeof review !== 'object' || Array.isArray(review)) throw new Error('not an object');
    return review;
  } catch (_) {
    throw protocolError('semantic_review_invalid', 'semantic-review is not valid JSON object');
  }
}

function readResultPacket(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    throw protocolError('existing_result_packet_invalid', 'existing result packet is not valid JSON');
  }
}

function validateExistingOutline(packet, outlinePath) {
  const quality = packet && packet.outputs && packet.outputs.detail_outline_quality;
  if (!quality || quality.outline_path !== outlinePath) {
    throw protocolError('reuse_outline_path_mismatch', 'existing result outline_path mismatch');
  }
}

function validateReusableResult(packet, args, quality, outlinePath) {
  const existingQuality = packet.outputs.detail_outline_quality;
  if (packet.workflow_id !== args.workflowId || existingQuality.workflow_id !== args.workflowId) {
    throw protocolError('reuse_workflow_id_mismatch', 'existing result workflow_id mismatch');
  }
  if (packet.stage_id !== args.stageId || existingQuality.stage_id !== args.stageId) {
    throw protocolError('reuse_stage_id_mismatch', 'existing result stage_id mismatch');
  }
  if (existingQuality.outline_path !== outlinePath) throw protocolError('reuse_outline_path_mismatch', 'existing result outline_path mismatch');
  if (existingQuality.outline_sha256 !== quality.outline_sha256) {
    throw protocolError('reuse_outline_sha256_mismatch', 'existing result outline_sha256 mismatch');
  }
  if (existingQuality.chapter_position !== quality.chapter_position) {
    throw protocolError('reuse_chapter_position_mismatch', 'existing result chapter_position mismatch');
  }
  return accepted(existingQuality.status)
    && packet.review_decision === 'accepted'
    && accepted(quality.status)
    && sameSemanticReview(existingQuality, quality);
}

function reusedPacket(packet) {
  const reused = JSON.parse(JSON.stringify(packet));
  reused.outputs.detail_outline_quality.execution = {
    ...(reused.outputs.detail_outline_quality.execution || {}),
    mode: 'reused',
    reused_result: true,
  };
  return reused;
}

function sameSemanticReview(left, right) {
  const leftReview = (((left || {}).execution || {}).semantic_review || {});
  const rightReview = (((right || {}).execution || {}).semantic_review || {});
  return leftReview.status === 'accepted'
    && rightReview.status === 'accepted'
    && leftReview.reviewer === rightReview.reviewer
    && leftReview.findings_sha256 === rightReview.findings_sha256
    && leftReview.finding_count === rightReview.finding_count;
}

function awaitingSemanticReview(quality) {
  return {
    ...quality,
    status: 'awaiting_semantic_review',
    execution: {
      ...((quality.execution && typeof quality.execution === 'object') ? quality.execution : {}),
      semantic_reviewer: '',
      semantic_review: {
        status: 'required',
        reviewer: '',
        findings_sha256: '',
        finding_count: 0,
      },
    },
  };
}

function atomicWritePacket(file, packet) {
  const directory = path.dirname(file);
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(packet, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
    fs.renameSync(temporary, file);
  } finally {
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
  }
}

function buildEnvelope(relativeOutline, quality, args) {
  const blocked = !accepted(quality.status);
  return {
    schemaVersion: '2.0.0',
    protocolVersion: PROTOCOL_VERSION,
    result_contract_version: 2,
    workflow_id: args.workflowId,
    workflow_type: 'long_write',
    stage_id: args.stageId,
    step_id: args.stageId,
    owner_module: 'story-review',
    lifecycle_node: args.stageId,
    asset_target: { kind: 'story_stage', id: 'current-story-stage' },
    review_requirement: { required: true, failure_return: 'stage_detail_outline' },
    step_status: blocked ? 'blocked' : 'completed',
    outputs: { detail_outline_quality: quality },
    changed_files: [],
    evidence: [{ type: 'detail_outline', path: relativeOutline, outline_sha256: quality.outline_sha256 }],
    verification_result: blocked ? 'blocked' : 'pass',
    blocking_reason: blocked ? quality.status : '',
    next_recommendation: blocked ? '修订细纲后重新检查。' : '可进入后续细纲投影或审阅阶段。',
    handoff_summary: blocked ? '细纲质量门未通过。' : '细纲质量门已完成。',
    memory_updates: [],
    asset_revision: { status: 'verified', asset_id: relativeOutline },
    review_decision: blocked ? 'revise' : 'accepted',
    downstream_effects: [],
    lifecycle_transition_request: { action: blocked ? 'pause' : 'advance', target: args.stageId },
    result_write_set: [],
    checkpoint_state: { stage_id: args.stageId, outline_path: relativeOutline },
    output_health_result: 'pass',
    resume_hint: blocked ? '修订细纲后重新运行质量检查。' : '从细纲投影阶段继续。',
    heartbeat_update: {},
    budget_usage: {},
  };
}

function blockedErrorEnvelope(errorArgs, error) {
  const code = error && error.code ? error.code : 'detail_outline_quality_validation_error';
  const outlinePath = String(errorArgs.outline || '');
  const chapterPosition = normalizeChapterPosition(errorArgs.chapterPosition);
  const quality = {
    status: 'revise',
    outline_path: outlinePath,
    outline_sha256: '',
    chapter_position: chapterPosition,
    activated_dimensions: [],
    activation_tags: [],
    baseline_dimensions: [],
    findings: [{ dimension: 'protocol_validation', code, severity: 'blocking', field: 'cli', message: error.message }],
    contract_projection: [],
    memory_projection: [],
    execution: { mode: 'fresh', reused_result: false },
    workflow_id: String(errorArgs.workflowId || ''),
    stage_id: String(errorArgs.stageId || 'detail_outline_review'),
  };
  return {
    schemaVersion: '2.0.0',
    protocolVersion: PROTOCOL_VERSION,
    result_contract_version: 2,
    workflow_id: quality.workflow_id,
    workflow_type: 'long_write',
    stage_id: quality.stage_id,
    step_id: quality.stage_id,
    owner_module: 'story-review',
    lifecycle_node: quality.stage_id,
    asset_target: { kind: 'story_stage', id: 'current-story-stage' },
    review_requirement: { required: true, failure_return: 'stage_detail_outline' },
    step_status: 'blocked',
    outputs: { detail_outline_quality: quality },
    changed_files: [],
    evidence: [],
    verification_result: 'blocked',
    blocking_reason: code,
    next_recommendation: '修复命令或结果包约束后重新检查。',
    handoff_summary: '细纲质量检查命令校验失败。',
    memory_updates: [],
    asset_revision: { status: 'unverified', asset_id: outlinePath },
    review_decision: 'revise',
    downstream_effects: [],
    lifecycle_transition_request: { action: 'pause', target: quality.stage_id },
    result_write_set: [],
    checkpoint_state: { stage_id: quality.stage_id, outline_path: outlinePath },
    output_health_result: 'blocked',
    resume_hint: '修复命令或结果包约束后重新运行质量检查。',
    heartbeat_update: {},
    budget_usage: {},
  };
}

function helpEnvelope(helpArgs) {
  const quality = {
    status: 'pass_with_advisory',
    outline_path: '',
    outline_sha256: '',
    chapter_position: '',
    activated_dimensions: [],
    activation_tags: [],
    baseline_dimensions: [],
    findings: [{ dimension: 'protocol_help', code: 'help_requested', severity: 'advisory', field: 'cli', message: USAGE }],
    contract_projection: [],
    memory_projection: [],
    execution: { mode: 'fresh', reused_result: false },
    workflow_id: String(helpArgs.workflowId || ''),
    stage_id: String(helpArgs.stageId || 'detail_outline_review'),
  };
  return buildEnvelope('', quality, helpArgs);
}

function protocolError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function accepted(status) {
  return status === 'pass' || status === 'pass_with_advisory';
}
