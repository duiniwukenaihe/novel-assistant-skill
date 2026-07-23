#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { commitAcceptedSection } = require('./lib/short-section-commit-store');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || !String(execution.stage_attempt_id || '')) {
    return finish({
      status: 'short_artifact_migration_stage_not_ready',
      instruction: '先从任务收件箱恢复当前短篇任务，让状态机启动当前阶段；再执行迁移。不会要求重写正文。',
    }, 0, args.json);
  }

  const stateFile = path.join(root, '追踪/private-short-extension/project-state.json');
  const state = readJson(stateFile) || {};
  const accepted = Array.isArray(state.accepted_sections) ? state.accepted_sections.slice().sort((a, b) => Number(a.section_index) - Number(b.section_index)) : [];
  const legacy = accepted.filter((item) => !isCurrentArtifact(item));
  if (!legacy.length) return finish({ status: 'short_artifacts_current', migrated_sections: [] }, 0, args.json);
  const userConfirmedSections = new Set(args.userConfirmedSections);

  const recovered = [];
  const missing = [];
  const revalidationRequired = [];
  for (const item of legacy) {
    const sectionIndex = Number(item.section_index || 0);
    const sourceRel = String(item.canonical_path || '');
    const sourceFile = safeProjectFile(root, sourceRel);
    const sourceText = sourceFile && fs.existsSync(sourceFile) ? readText(sourceFile) : '';
    const sectionText = sourceRel === '正文.md' ? extractSection(sourceText, sectionIndex) : sourceText;
    if (!sectionText.trim()) {
      missing.push({ section_index: sectionIndex, source_path: sourceRel });
      continue;
    }
    const anchorRel = String(item.anchor_path || `追踪/private-short-extension/section-${String(sectionIndex).padStart(3, '0')}-anchor.json`);
    const anchor = readJson(safeProjectFile(root, anchorRel)) || {};
    const userConfirmed = userConfirmedSections.has(sectionIndex);
    const qualityResult = normalizeLegacyQuality(anchor.quality_result, userConfirmed);
    if (!qualityResult) {
      revalidationRequired.push({ section_index: sectionIndex, source_path: sourceRel, anchor_path: anchorRel, reason: 'current_quality_evidence_missing' });
      continue;
    }
    recovered.push({ item, sectionIndex, sourceRel, sectionText, anchorRel, anchor, qualityResult, userConfirmed });
  }
  if (missing.length) {
    return finish({
      status: 'short_artifact_migration_blocked_missing_source',
      missing_sections: missing,
      instruction: '至少一个旧小节缺少可恢复正文或旧版验收证据；先确认候选稿，不得用模型补写或伪造通过记录。',
    }, 0, args.json);
  }
  if (revalidationRequired.length && (!args.confirm || recovered.length === 0)) {
    return finish({
      status: 'short_artifact_migration_revalidation_required',
      workflow_id: workflowId,
      sections: revalidationRequired,
      message: '旧版「通过」不等于当前大纲合同与故事质量证据。',
      next_candidates: [
        { number: 1, label: '按当前规则重新验收这些小节（推荐）' },
        { number: 2, label: '先查看旧稿与当前大纲差异' },
        { number: 3, label: '对已人工认可的小节显式确认保留' },
        { number: 4, label: '暂停并保留断点' },
      ],
      user_confirmation_example: `--user-confirmed-sections ${revalidationRequired.map((item) => item.section_index).join(',')}`,
      confirm_preserved_sections: recovered.length
        ? `node scripts/short-section-artifact-migrate.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(workflowId)} --user-confirmed-sections ${recovered.map((item) => item.sectionIndex).join(',')} --confirm --json`
        : '',
    }, 0, args.json);
  }
  if (!args.confirm) {
    return finish({
      status: 'short_artifact_migration_confirmation_required',
      workflow_id: workflowId,
      legacy_sections: recovered.map((item) => ({ section_index: item.sectionIndex, source_path: item.sourceRel })),
      risk: '只新增 正文/第NNN节.md 并更新采用锚点和项目元数据；不改原候选稿或累计正文。',
      next_candidates: [
        { number: 1, label: '迁移旧小节事实源（推荐）' },
        { number: 2, label: '查看迁移清单' },
        { number: 3, label: '保留旧结构并暂停' },
        { number: 4, label: '输入其他要求' },
      ],
      confirm_command: `node scripts/short-section-artifact-migrate.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(workflowId)} --user-confirmed-sections ${[...userConfirmedSections].sort((a, b) => a - b).join(',')} --confirm --json`,
    }, 0, args.json);
  }

  const migrated = [];
  const revalidationSet = new Set(revalidationRequired.map((item) => item.section_index));
  const nextAccepted = accepted.filter((item) => !revalidationSet.has(Number(item.section_index || 0)));
  for (const entry of revalidationRequired) {
    const anchorFile = safeProjectFile(root, entry.anchor_path);
    const anchor = readJson(anchorFile) || {};
    if (anchorFile) {
      atomicWriteJson(anchorFile, {
        ...anchor,
        status: 'needs_revalidation',
        migration_compatibility: {
          ...(anchor.migration_compatibility && typeof anchor.migration_compatibility === 'object' ? anchor.migration_compatibility : {}),
          status: 'legacy_quality_revalidation_required',
          source_kind: 'legacy',
          user_confirmed: false,
          missing_v2_fields_marked: true,
        },
        revalidation_required_at: new Date().toISOString(),
      });
    }
  }
  for (const entry of recovered) {
    let committed;
    try {
      committed = commitAcceptedSection(root, {
        task,
        sectionIndex: entry.sectionIndex,
        title: String(entry.item.title || entry.anchor.section_title || ''),
        text: entry.sectionText,
        projectTitle: String(state.working_title || state.project_title || state.title || ''),
        metadata: {
          section_summary: entry.anchor.section_summary || '',
          revealed_information: entry.anchor.revealed_information || [],
          character_state: entry.anchor.character_state || {},
          open_hook: entry.anchor.open_hook || '',
          style_anchor: entry.anchor.style_anchor || [],
          next_section_handoff: entry.anchor.next_section_handoff || {},
        },
      });
    } catch (error) {
      return finish({
        status: String((error || {}).status || 'short_artifact_migration_commit_blocked'),
        migrated_sections: migrated,
        blocked_section: entry.sectionIndex,
        detail: String((error || {}).message || error || ''),
        instruction: '已完成的小节迁移保持有效；修复当前阻塞后重跑，提交过程会幂等复用。',
      }, 0, args.json);
    }
    const anchor = {
      ...entry.anchor,
      schema_version: entry.anchor.schema_version || '1.0.0',
      workflow_id: workflowId,
      section_index: entry.sectionIndex,
      section_title: String(entry.item.title || entry.anchor.section_title || `第${entry.sectionIndex}节`),
      status: 'accepted',
      quality_result: entry.qualityResult,
      canonical_path: committed.canonical_path,
      canonical_sha256: committed.canonical_sha256,
      section_commit_id: committed.commit_id,
      migrated_from: entry.sourceRel,
      migration_compatibility: {
        status: 'protected_user_confirmed_revalidation_pending',
        source_kind: 'user_confirmed',
        user_confirmed: true,
        user_confirmed_at: new Date().toISOString(),
        preserved_machine_gate_as_history: true,
        preserved_story_value_gate_as_history: true,
        missing_v2_fields_marked: true,
      },
      migrated_at: new Date().toISOString(),
    };
    atomicWriteJson(safeProjectFile(root, entry.anchorRel), anchor);
    const index = nextAccepted.findIndex((item) => Number(item.section_index) === entry.sectionIndex);
    const acceptedRecord = {
      ...entry.item,
      canonical_path: committed.canonical_path,
      anchor_path: entry.anchorRel,
      sha256: committed.canonical_sha256,
      section_commit_id: committed.commit_id,
      source_kind: 'user_confirmed',
      user_confirmed: true,
      user_confirmed_at: new Date().toISOString(),
      quality_status: 'protected_revalidation_pending',
    };
    if (index >= 0) nextAccepted[index] = acceptedRecord;
    else nextAccepted.push(acceptedRecord);
    migrated.push({ section_index: entry.sectionIndex, canonical_path: committed.canonical_path, section_commit_id: committed.commit_id });
  }
  atomicWriteJson(stateFile, {
    ...state,
    accepted_sections: nextAccepted.sort((a, b) => Number(a.section_index || 0) - Number(b.section_index || 0)),
    current_section_index: revalidationRequired.length
      ? Math.min(...revalidationRequired.map((item) => item.section_index))
      : state.current_section_index,
    remaining_sections: revalidationRequired.length
      ? [...new Set([...(Array.isArray(state.remaining_sections) ? state.remaining_sections : []), ...revalidationRequired.map((item) => item.section_index)])].sort((a, b) => Number(a) - Number(b))
      : state.remaining_sections,
    canonical_assets: [...new Set([...(Array.isArray(state.canonical_assets) ? state.canonical_assets : []), ...migrated.map((item) => item.canonical_path)])],
    migration: {
      ...(state.migration && typeof state.migration === 'object' ? state.migration : {}),
      short_section_artifacts: {
        status: revalidationRequired.length ? 'partial_revalidation_required' : 'completed',
        workflow_id: workflowId,
        migrated_sections: migrated.map((item) => item.section_index),
        revalidation_sections: revalidationRequired.map((item) => item.section_index),
        completed_at: new Date().toISOString(),
      },
    },
    updated_at: new Date().toISOString(),
  });
  return finish({
    status: revalidationRequired.length ? 'short_artifacts_migrated_with_revalidation' : 'short_artifacts_migrated',
    workflow_id: workflowId,
    migrated_sections: migrated,
    revalidation_sections: revalidationRequired.map((item) => item.section_index),
    next_action: revalidationRequired.length ? '从第一个待复验小节恢复，按当前大纲合同重新验收。' : '重新运行当前阶段的 execution_command。',
  }, 0, args.json);
}

function isCurrentArtifact(item) {
  const sectionIndex = Number((item || {}).section_index || 0);
  return String((item || {}).canonical_path || '') === `正文/第${String(sectionIndex).padStart(3, '0')}节.md`
    && Boolean(String((item || {}).section_commit_id || ''));
}

function extractSection(text, sectionIndex) {
  const lines = String(text || '').split(/\r?\n/);
  const headings = [];
  for (let index = 0; index < lines.length; index += 1) if (/^#{1,6}\s+/u.test(lines[index].trim())) headings.push(index);
  if (!headings.length) return String(text || '');
  const offset = sectionIndex - 1;
  if (offset < 0 || offset >= headings.length) return '';
  return lines.slice(headings[offset], headings[offset + 1] === undefined ? lines.length : headings[offset + 1]).join('\n');
}

function normalizeLegacyQuality(value, userConfirmed = false) {
  if (!userConfirmed) return null;
  const quality = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  if (String(quality.machine_gate || '') !== 'pass'
    || String(quality.story_value_gate || quality.quality_gate || '') !== 'pass') return null;
  return {
    ...quality,
    story_value_gate: String(quality.story_value_gate || quality.quality_gate || 'pass'),
    repetition_gate: String(quality.repetition_gate || 'legacy_migration_accepted'),
    length_policy: quality.length_policy && typeof quality.length_policy === 'object'
      ? quality.length_policy
      : {
        blocking: false,
        verdict: 'legacy_migration_accepted',
        note: '旧版采用记录没有独立篇幅门；迁移时保留旧版机器门与故事质量门证据，不重新生成正文。',
      },
  };
}

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', userConfirmedSections: [], confirm: false, json: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++index] || '';
    else if (arg === '--user-confirmed-sections') args.userConfirmedSections = String(argv[++index] || '').split(',').map((item) => Number(item.trim())).filter((item) => Number.isInteger(item) && item > 0);
    else if (arg === '--confirm') args.confirm = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else usage(`unknown argument: ${arg}`);
  }
  return args;
}

function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file === root || file.startsWith(`${root}${path.sep}`) ? file : ''; }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : `${value.status}\n`}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-section-artifact-migrate.js --project-root <book> --workflow-id <id> [--user-confirmed-sections 1,2] [--confirm] [--json]\n`); process.exit(2); }
function printHelp() { process.stdout.write('Usage: node short-section-artifact-migrate.js --project-root <book> --workflow-id <id> [--user-confirmed-sections 1,2] [--confirm] [--json]\n'); return 0; }

process.exitCode = main();
