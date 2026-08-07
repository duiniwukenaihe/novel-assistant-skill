#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { acceptTransaction, inspectChapter, prepareTransaction } = require('./lib/chapter-commit-store');
const { countCjkCharacters, validateLongChapterAcceptanceBinding } = require('./lib/long-chapter-length-contract');
const { assertTargetsEqual, validateLongChapterTargetV2 } = require('./lib/long-chapter-target');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { atomicWriteJson, atomicWriteText } = require('./lib/workflow-state-store');
const { invokeApplyResult, invokeResolveAction } = require('./lib/workflow-state-machine-invoke');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return help();
  const root = path.resolve(args.projectRoot || process.cwd());
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return finish(authority, 2, args.json);
  const task = authority.task;
  const preflight = validateTask(root, task);
  if (preflight.status !== 'ready') return finish(preflight, 2, args.json);
  if (!args.apply) {
    return finish({
      status: 'long_chapter_commit_ready', workflow_id: task.workflow_id,
      chapter_target: preflight.target, candidate_sha256: preflight.candidateSha,
      canonical_recovery_required: preflight.recoveryRequired,
      instruction: '使用 --apply 执行确定性章节事务提交。', host_started: false,
    }, 0, args.json);
  }
  try {
    const recovery = recoverRejectedDirectWrite(root, preflight);
    const committed = matchingAcceptedCommit(root, task, preflight) || createAcceptedCommit(root, task, preflight);
    const result = buildResultPacket(root, task, preflight, committed, recovery);
    atomicWriteJson(safeFile(root, task.stage_execution.expected_result_packet), result);
    const applied = applyResult(root, task, task.stage_execution.expected_result_packet);
    if (!applied.applied) {
      return finish({
        status: 'apply_blocked', workflow_id: task.workflow_id, accepted_commit_id: committed.commit_id,
        result_packet: task.stage_execution.expected_result_packet, recovery,
        workflow_result: applied.result, host_started: false,
      }, applied.exitCode || 2, args.json);
    }
    return finish({
      status: 'applied', workflow_id: task.workflow_id, accepted_commit_id: committed.commit_id,
      result_packet: task.stage_execution.expected_result_packet,
      canonical_path: preflight.target.draft_path, candidate_path: preflight.target.candidate_draft_path,
      candidate_sha256: preflight.candidateSha, recovery,
      next_stage: String(applied.result.current_stage || ((applied.result.task || {}).current_stage) || ''),
      host_started: false,
    }, 0, args.json);
  } catch (error) {
    return finish({
      status: String(error.status || error.code || 'blocked_long_chapter_commit'),
      workflow_id: String(task.workflow_id || ''), detail: String(error.message || error), host_started: false,
    }, 2, args.json);
  }
}

function validateTask(root, task) {
  if (String(task.workflow_type || '') !== 'long_write') return block('blocked_wrong_workflow', '当前任务不是长篇写作任务。');
  if (String(task.current_stage || '') !== 'chapter_commit') return block('stage_action_not_applicable', `当前阶段不是 chapter_commit：${task.current_stage || 'unknown'}`);
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'chapter_commit') {
    return block('blocked_stage_execution_required', '章节事务提交需要 running chapter_commit stage_execution。');
  }
  const target = execution.chapter_target;
  const validation = validateLongChapterTargetV2(target, { projectRoot: root, workflowId: String(task.workflow_id || '') });
  if (!validation.ok) return block('blocked_chapter_target_frozen_missing', `冻结章节目标不完整：${validation.missing_fields.join(', ')}`);
  const activeValidation = validateLongChapterTargetV2(task.active_chapter_target, { projectRoot: root, workflowId: String(task.workflow_id || '') });
  const equality = activeValidation.ok ? assertTargetsEqual(task.active_chapter_target, target) : { ok: false };
  if (!activeValidation.ok || !equality.ok) return block('blocked_chapter_target_echo_mismatch', '冻结章节目标与 durable active_chapter_target 不一致。');
  if (JSON.stringify((execution.write_set || []).map(normalizeRel)) !== JSON.stringify([normalizeRel(target.draft_path)])) {
    return block('blocked_long_chapter_write_set_mismatch', 'chapter_commit 只能写冻结目标的正式正文。');
  }
  const candidateFile = safeRegularFile(root, target.candidate_draft_path);
  const contractFile = safeRegularFile(root, target.contract_path);
  if (!candidateFile || !contractFile) return block('blocked_long_chapter_candidate_missing', '章节候选稿或章节 Brief 不存在。');
  const candidate = fs.readFileSync(candidateFile, 'utf8');
  const contract = fs.readFileSync(contractFile, 'utf8');
  const prosePacket = acceptedPacket(root, task, 'prose');
  const acceptancePacket = acceptedPacket(root, task, 'prose_acceptance', true);
  const proseBinding = validateLongChapterAcceptanceBinding((prosePacket || {}).chapter_prose_candidate, contract, candidate, target.candidate_draft_path);
  const acceptanceBinding = validateLongChapterAcceptanceBinding((acceptancePacket || {}).chapter_prose_acceptance, contract, candidate, target.candidate_draft_path);
  if (proseBinding.status !== 'current' || acceptanceBinding.status !== 'current') {
    return block('blocked_long_chapter_acceptance_binding_stale', '正文生产或正文验收回执未绑定当前候选稿；必须先重新验收。', { prose_binding: proseBinding, acceptance_binding: acceptanceBinding });
  }
  const candidateSha = hashFile(candidateFile);
  const canonicalFile = safeFile(root, target.draft_path);
  const inspected = inspectChapter(root, target.volume, target.volume_chapter_no);
  const latest = inspected.latest_commit || null;
  const latestArtifact = latest && Array.isArray(latest.artifacts)
    ? latest.artifacts.find((item) => normalizeRel((item || {}).target) === normalizeRel(target.draft_path)) : null;
  const canonicalSha = fs.existsSync(canonicalFile) && fs.statSync(canonicalFile).isFile() ? hashFile(canonicalFile) : '';
  const latestSha = String((latestArtifact || {}).after_hash || '').toLowerCase();
  const recoveryRequired = Boolean(canonicalSha && latestSha && canonicalSha !== latestSha);
  if (recoveryRequired && canonicalSha !== candidateSha) {
    return block('blocked_long_chapter_canonical_drift', '正式正文已偏离最近合法提交，且内容不等于当前候选稿；禁止自动覆盖。', { canonical_sha256: canonicalSha, candidate_sha256: candidateSha, latest_accepted_sha256: latestSha });
  }
  return { status: 'ready', target, candidate, candidateSha, canonicalFile, canonicalSha, latest, latestSha, recoveryRequired, acceptancePacket };
}

function recoverRejectedDirectWrite(root, preflight) {
  if (!preflight.recoveryRequired) return { status: 'not_required' };
  const latest = preflight.latest;
  const transactionFile = safeRegularFile(root, `追踪/story-system/transactions/${String(latest.transaction_id || '')}/transaction.json`);
  const transaction = transactionFile ? readJson(transactionFile) : null;
  const artifact = transaction && Array.isArray(transaction.artifacts)
    ? transaction.artifacts.find((item) => normalizeRel((item || {}).target) === normalizeRel(preflight.target.draft_path)) : null;
  const stagedFile = artifact ? safeRegularFile(root, artifact.staged) : '';
  if (!transaction || String(transaction.status || '') !== 'accepted' || !stagedFile || hashFile(stagedFile) !== preflight.latestSha) {
    throw failure('blocked_long_chapter_canonical_recovery_missing', '无法从最近合法章节事务恢复被拒绝写入前的正式稿。');
  }
  atomicWriteText(preflight.canonicalFile, fs.readFileSync(stagedFile, 'utf8'));
  if (hashFile(preflight.canonicalFile) !== preflight.latestSha) throw failure('blocked_long_chapter_canonical_recovery_failed', '正式稿恢复后的哈希与最近合法提交不一致。');
  return { status: 'restored_latest_accepted', commit_id: String(latest.commit_id || ''), canonical_sha256: preflight.latestSha };
}

function matchingAcceptedCommit(root, task, preflight) {
  const commit = inspectChapter(root, preflight.target.volume, preflight.target.volume_chapter_no).latest_commit;
  if (!commit || String(commit.workflow_id || '') !== String(task.workflow_id || '')) return null;
  if (String(((commit.provenance || {}).stage_attempt_id) || '') !== String(task.stage_execution.stage_attempt_id || '')) return null;
  const artifact = (commit.artifacts || []).find((item) => normalizeRel((item || {}).target) === normalizeRel(preflight.target.draft_path));
  if (!artifact || String(artifact.after_hash || '').toLowerCase() !== preflight.candidateSha) return null;
  return acceptTransaction(root, String(commit.transaction_id || ''));
}

function createAcceptedCommit(root, task, preflight) {
  const attempt = String(task.stage_execution.stage_attempt_id || 'chapter-commit').replace(/[^A-Za-z0-9._-]/g, '_');
  const manifestRel = `${task.task_dir}/audit/chapter-commit-manifests/${attempt}.json`;
  atomicWriteJson(safeFile(root, manifestRel), {
    schemaVersion: '1.0.0', workflow_id: task.workflow_id,
    volume: preflight.target.volume, chapter: preflight.target.volume_chapter_no,
    provenance: {
      task_family_id: String(task.task_family_id || ''), workflow_id: String(task.workflow_id || ''),
      branch_id: String(task.branch_id || task.workflow_id || ''), stage_attempt_id: String(task.stage_execution.stage_attempt_id || ''),
      acceptance_status: 'accepted',
    },
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: [{ role: 'long_chapter_prose', required: true, staged: preflight.target.candidate_draft_path, target: preflight.target.draft_path }],
    facts: Array.isArray(preflight.acceptancePacket.facts) ? preflight.acceptancePacket.facts : [],
    promise_deltas: Array.isArray(preflight.acceptancePacket.promise_deltas) ? preflight.acceptancePacket.promise_deltas : [],
  });
  return acceptTransaction(root, prepareTransaction(root, manifestRel).transaction_id);
}

function buildResultPacket(root, task, preflight, commit, recovery) {
  const execution = task.stage_execution || {};
  const boundRunner = (((task.runtime_guard || {}).last_runner_attempt) || {});
  const runnerBound = String(boundRunner.stage_id || '') === 'chapter_commit'
    && String(boundRunner.expected_result_packet || '') === String(execution.expected_result_packet || '')
    && Boolean(String(boundRunner.runner_packet_path || ''));
  let memoryReceipt = (((execution.memory_context || {}).memory_read_receipt) || null);
  if (runnerBound) {
    const runner = readJson(safeFile(root, boundRunner.runner_packet_path)) || {};
    memoryReceipt = (((runner.memory_context || {}).memory_read_receipt) || memoryReceipt);
  }
  const currentTargetId = String(preflight.target.target_id || '');
  const consumedTargetIds = new Set((Array.isArray(task.consumed_detail_outline_targets) ? task.consumed_detail_outline_targets : [])
    .map((item) => String((item || {}).target_id || '')).filter(Boolean));
  const hasNextChapter = (Array.isArray(task.accepted_detail_outline_targets) ? task.accepted_detail_outline_targets : [])
    .some((item) => {
      const id = String((item || {}).target_id || '');
      return id && id !== currentTargetId && !consumedTargetIds.has(id);
    });
  const nextStage = hasNextChapter ? 'chapter_brief' : 'milestone_review';
  const canonicalChanged = String(preflight.canonicalSha || '') !== String(preflight.candidateSha || '');
  const canonicalChanges = canonicalChanged ? [preflight.target.draft_path] : [];
  return {
    schemaVersion: '1.0.0', workflow_id: task.workflow_id, workflow_type: 'long_write', stage_id: 'chapter_commit', step_id: 'chapter_commit',
    owner_module: String(execution.owner_module || 'story-workflow'), lifecycle_node: 'chapter_commit', asset_target: { kind: 'chapter', id: 'current-chapter' }, review_requirement: { required: false, failure_return: '' },
    chapter_target: preflight.target, step_status: 'completed',
    outputs: [{ kind: 'chapter_prose', path: preflight.target.draft_path, source_candidate_path: preflight.target.candidate_draft_path, cjk_char_count: countCjkCharacters(preflight.candidate) }],
    changed_files: canonicalChanges,
    evidence: [{ type: 'accepted_chapter_transaction', commit_id: commit.commit_id, candidate_sha256: preflight.candidateSha, canonical_recovery: recovery.status, idempotent_adoption: !canonicalChanged }],
    verification_result: 'pass', checkpoint_state: { stage_id: 'chapter_commit' }, output_health_result: 'pass',
    result_packet_path: execution.expected_result_packet,
    host_execution_mode: runnerBound ? 'managed_runner' : 'deterministic_command', runner_packet_path: runnerBound ? boundRunner.runner_packet_path : '', memory_read_receipt: memoryReceipt,
    asset_revision: { status: 'verified', asset_id: preflight.target.target_id }, review_decision: 'not_applicable', downstream_effects: [],
    lifecycle_transition_request: { action: 'advance', target: nextStage }, next_stage_id: nextStage, result_write_set: canonicalChanges,
    chapter_commit: {
      mode: 'transactional', accepted_commit_id: commit.commit_id,
      commit_file: normalizeRel(path.relative(root, String(commit.commit_file || ''))),
      projection_status: commit.projection_status, projection_debt: commit.projection_status === 'projection_failed',
      staged_artifacts: [preflight.target.candidate_draft_path],
    },
    blocking_reason: '', next_recommendation: hasNextChapter ? '进入下一章 Brief。' : '进入阶段复盘。',
    handoff_summary: '当前章已通过确定性内部事务提交。', memory_updates: [],
  };
}

function applyResult(root, task, resultRel) {
  const run = invokeApplyResult({ projectRoot: root, workflowId: task.workflow_id, resultFile: safeFile(root, resultRel) });
  const result = parseJson(run.stdout) || { status: 'blocked_apply_result_unreadable', stdout: String(run.stdout || '').slice(-1000), stderr: String(run.stderr || '').slice(-1000) };
  return { applied: run.status === 0 && !String(result.status || '').startsWith('blocked_'), exitCode: run.status || 0, result };
}

function acceptedPacket(root, task, stageId, requirePass = false) {
  const attempt = (Array.isArray(task.stage_attempt_history) ? task.stage_attempt_history : []).slice().reverse().find((item) => String((item || {}).stage_id || '') === stageId && String((item || {}).status || '') === 'completed' && String((item || {}).accepted_result_packet || '') && (item || {}).superseded_by_chapter_prose_revalidation !== true);
  if (!attempt || String(attempt.accepted_result_packet || '') !== String(attempt.expected_result_packet || '')) return null;
  const packet = readJson(safeFile(root, attempt.accepted_result_packet));
  if (!packet || String(packet.workflow_id || '') !== String(task.workflow_id || '') || String(packet.stage_id || '') !== stageId || String(packet.step_status || '') !== 'completed') return null;
  if (requirePass && !['pass', 'accepted'].includes(String(packet.verification_result || '').toLowerCase())) return null;
  return packet;
}

function safeFile(root, rel) { const file=path.resolve(root,String(rel||'')); if(file===root||!file.startsWith(`${root}${path.sep}`)) throw failure('blocked_unsafe_path',`unsafe path: ${rel}`); return file; }
function safeRegularFile(root, rel) { let file; try{file=safeFile(root,rel);}catch(_){return '';} if(!fs.existsSync(file)||!fs.statSync(file).isFile()) return ''; const realRoot=fs.realpathSync(root),realFile=fs.realpathSync(file); return realFile.startsWith(`${realRoot}${path.sep}`)?file:''; }
function normalizeRel(value){return String(value||'').replace(/\\/g,'/').replace(/^\.\//,'');}
function hashFile(file){return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;}
function readJson(file){try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch(_){return null;}}
function parseJson(value){try{return JSON.parse(String(value||'').trim());}catch(_){return null;}}
function block(status,detail,extra={}){return {status,detail,...extra,host_started:false};}
function failure(status,message){const error=new Error(message);error.status=status;return error;}
function finish(value,code,json){process.stdout.write(`${json?JSON.stringify(value):`${value.status}\n`}\n`);return code;}
function parseArgs(argv){const out={projectRoot:'',workflowId:'',apply:false,json:false,help:false};for(let i=0;i<argv.length;i+=1){const arg=argv[i];if(arg==='--project-root')out.projectRoot=argv[++i]||'';else if(arg==='--workflow-id')out.workflowId=argv[++i]||'';else if(arg==='--apply'||arg==='--write')out.apply=true;else if(arg==='--json')out.json=true;else if(arg==='--help'||arg==='-h')out.help=true;else throw failure('blocked_invalid_argument',`unknown argument: ${arg}`);}if(!out.workflowId&&!out.help)throw failure('blocked_invalid_argument','missing --workflow-id');return out;}
function help(){process.stdout.write('Usage: node long-chapter-commit-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n');return 0;}

try { process.exitCode = main(); } catch (error) { process.stdout.write(`${JSON.stringify({status:String(error.status||'error'),detail:String(error.message||error),host_started:false})}\n`); process.exitCode=2; }
