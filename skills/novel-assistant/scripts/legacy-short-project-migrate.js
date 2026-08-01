#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { writeFocusPointer } = require('./lib/workflow-task-authority');
const {
  ensureShortProjectState,
  advanceShortPlanRevision,
  outlineSectionCount,
  readShortProjectState,
} = require('./lib/short-project-state');

function parseArgs(argv) {
  const args = { projectRoot: '', write: false, confirm: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--write') args.write = true;
    else if (arg === '--confirm') args.confirm = true;
    else if (arg === '--json') args.json = true;
    else fail(`Unknown argument: ${arg}`);
  }
  if (!args.projectRoot) fail('Missing --project-root');
  return args;
}

function firstFile(root, candidates) {
  return candidates.find((relative) => {
    const file = path.join(root, relative);
    return fs.existsSync(file) && fs.statSync(file).isFile();
  }) || '';
}

function inspectLegacyShort(root) {
  const mapping = {
    material_card: mapAsset(root, ['素材卡.md'], '素材卡.md'),
    setting: mapAsset(root, ['设定.md'], '设定.md'),
    outline: mapAsset(root, ['大纲/小节大纲.md', '小节大纲.md'], '小节大纲.md'),
    prose: mapAsset(root, ['正文/正文.md', '正文.md'], '正文.md'),
  };
  const briefsDir = path.join(root, '追踪', 'private-short-extension', 'briefs');
  const sectionDir = path.join(root, '正文');
  const briefCount = countMatchingFiles(briefsDir, /(?:写作Brief_)?第\d+节\.md$/u);
  const sectionCount = countMatchingFiles(sectionDir, /^第\d+节\.md$/u);
  const required = ['setting', 'outline', 'prose'];
  const missing = required.filter((key) => !mapping[key].source);
  const legacyTask = inspectLegacyTaskState(root);
  const inspection = {
    asset_status: missing.length ? 'legacy_short_assets_incomplete' : 'legacy_short_assets_detected',
    asset_mapping: mapping,
    section_file_count: sectionCount,
    brief_file_count: briefCount,
    missing_required_assets: missing,
    legacy_task_summary: legacyTask ? summarizeLegacyTask(legacyTask) : null,
  };
  Object.defineProperty(inspection, '__legacy_task', { value: legacyTask, enumerable: false });
  return inspection;
}

function inspectLegacyTaskState(root) {
  const file = path.join(root, '追踪', 'workflow', 'current-task.json');
  if (!fs.existsSync(file)) return null;
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  const pointerOnly = value && value.workflow_id && value.task_dir && !value.workflow_type && !value.work_title;
  if (pointerOnly || !value || (!value.workflow_type && !value.current_stage && !value.user_feedback)) return null;
  return value;
}

function summarizeLegacyTask(task) {
  return {
    workflow_type: String(task.workflow_type || ''),
    work_title: String(task.work_title || task.title || ''),
    current_stage: String(task.current_stage || ''),
    status: String(task.status || ''),
    updated_at: String(task.updated_at || ''),
    completed_count: Array.isArray(task.completed) ? task.completed.length : 0,
    has_user_feedback: Boolean(task.user_feedback && typeof task.user_feedback === 'object'),
    has_quality_gate: Boolean(task.quality_gate && typeof task.quality_gate === 'object'),
    next_candidate_count: Array.isArray(task.next_candidates) ? task.next_candidates.length : 0,
  };
}

function mapAsset(root, candidates, target) {
  const source = firstFile(root, candidates);
  return {
    source,
    target,
    requires_copy: Boolean(source && source !== target),
    source_digest: source ? digestFile(path.join(root, source)) : '',
  };
}

function migrate(root, inspection) {
  if (inspection.missing_required_assets.length) {
    return result('blocked_legacy_short_assets_incomplete', { ...inspection, creative_assets_modified: false }, 2);
  }
  const preflight = preflightMigration(root, inspection);
  if (preflight.status !== 'ok') {
    return result(preflight.status, { ...inspection, ...preflight, creative_assets_modified: false }, 2);
  }
  const created = [];
  const migrationId = `legacy-short-${new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 14)}-${crypto.randomBytes(3).toString('hex')}`;
  const migrationRel = `追踪/workflow/migrations/${migrationId}.json`;
  const legacySnapshotRel = inspection.__legacy_task
    ? `追踪/workflow/migrations/${migrationId}.legacy-current-task.json`
    : '';
  let legacyTaskMoved = false;
  try {
    for (const asset of Object.values(inspection.asset_mapping)) {
      if (!asset.source || asset.source === asset.target) continue;
      const source = path.join(root, asset.source);
      const target = path.join(root, asset.target);
      if (fs.existsSync(target)) {
        if (digestFile(target) !== asset.source_digest) {
          return result('blocked_legacy_short_canonical_conflict', {
            source: asset.source,
            target: asset.target,
            creative_assets_modified: false,
          }, 2);
        }
        continue;
      }
      atomicCopy(source, target);
      created.push(asset.target);
    }

    if (legacySnapshotRel) {
      const currentTaskFile = path.join(root, '追踪', 'workflow', 'current-task.json');
      const snapshotFile = path.join(root, legacySnapshotRel);
      fs.mkdirSync(path.dirname(snapshotFile), { recursive: true });
      fs.renameSync(currentTaskFile, snapshotFile);
      legacyTaskMoved = true;
    }

    const legacyTitle = String(((inspection.__legacy_task || {}).work_title) || '').trim();
    const createdTask = createShortWorkflow(root, legacyTitle);
    const task = createdTask.task;
    const projectTitle = inferLegacyProjectTitle(root, inspection) || path.basename(root);
    const projectState = ensureShortProjectState(root, {
      workflowId: task.workflow_id,
      title: projectTitle,
      status: 'migration_pending_revalidation',
    });
    const plannedState = advanceShortPlanRevision(root, {
      workflowId: task.workflow_id,
      title: projectState.project_title,
      outlinePath: '小节大纲.md',
    });
    const record = {
      schemaVersion: '1.0.0',
      migration_id: migrationId,
      source_kind: 'legacy_short_project',
      workflow_id: task.workflow_id,
      created_at: new Date().toISOString(),
      asset_mapping: inspection.asset_mapping,
      created_canonical_assets: created,
      preserved_legacy_assets: Object.values(inspection.asset_mapping).map((item) => item.source).filter(Boolean),
      section_file_count: inspection.section_file_count,
      brief_file_count: inspection.brief_file_count,
      legacy_task_snapshot: legacySnapshotRel,
      legacy_task_summary: inspection.legacy_task_summary,
      next_stage: task.current_stage,
      revalidation_required: true,
    };
    atomicWriteJson(path.join(root, migrationRel), record);

    const taskFile = path.join(root, task.task_dir, 'task.json');
    const durableTask = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
    durableTask.migration = {
      source_kind: 'legacy_short_project',
      migration_id: migrationId,
      migration_record: migrationRel,
      legacy_task_snapshot: legacySnapshotRel,
      revalidation_required: true,
      creative_assets_modified: created.length > 0,
    };
    if (inspection.__legacy_task) {
      durableTask.legacy_resume = buildLegacyResume(inspection.__legacy_task, legacySnapshotRel);
      durableTask.user_goal = `恢复旧短篇任务：${legacyTitle || projectState.project_title}`;
      durableTask.lifecycle = {
        ...(durableTask.lifecycle || {}),
        user_goal: durableTask.user_goal,
        migration_source_stage: durableTask.legacy_resume.source_stage,
        migration_source_status: durableTask.legacy_resume.source_status,
      };
      durableTask.state_version = Number(durableTask.state_version || 0) + 1;
    }
    durableTask.project_identity = {
      project_id: plannedState.project_id,
      working_title: plannedState.project_title,
      status: plannedState.status,
    };
    atomicWriteJson(taskFile, durableTask);
    writeFocusPointer(root, durableTask);
    return result('legacy_short_migration_applied', {
      workflow_id: task.workflow_id,
      workflow_type: 'short_write',
      current_stage: task.current_stage,
      migration_record: migrationRel,
      created_canonical_assets: created,
      preserved_legacy_assets: record.preserved_legacy_assets,
      legacy_task_state_preserved: Boolean(legacySnapshotRel),
      legacy_task_snapshot: legacySnapshotRel,
      revalidation_required: true,
      creative_assets_modified: created.length > 0,
    }, 0);
  } catch (error) {
    for (const relative of created.reverse()) {
      try { fs.unlinkSync(path.join(root, relative)); } catch (_) { /* best effort rollback */ }
    }
    if (legacyTaskMoved) {
      const currentTaskFile = path.join(root, '追踪', 'workflow', 'current-task.json');
      const snapshotFile = path.join(root, legacySnapshotRel);
      if (!fs.existsSync(currentTaskFile) && fs.existsSync(snapshotFile)) {
        try { fs.renameSync(snapshotFile, currentTaskFile); } catch (_) { /* best effort rollback */ }
      }
    }
    return result('legacy_short_migration_failed', { message: error.message, rolled_back_canonical_assets: created }, 2);
  }
}

function buildLegacyResume(task, snapshotPath) {
  const candidates = Array.isArray(task.next_candidates) ? task.next_candidates : [];
  const recommended = candidates.find(item => Number((item || {}).number) === 1) || candidates[0] || null;
  return {
    schemaVersion: '1.0.0',
    source_kind: 'legacy_short_task_state',
    source_snapshot: snapshotPath,
    source_workflow_type: String(task.workflow_type || ''),
    source_stage: String(task.current_stage || ''),
    source_status: String(task.status || ''),
    source_updated_at: String(task.updated_at || ''),
    completed: Array.isArray(task.completed) ? JSON.parse(JSON.stringify(task.completed)) : [],
    artifacts: task.artifacts && typeof task.artifacts === 'object' ? JSON.parse(JSON.stringify(task.artifacts)) : {},
    user_feedback: task.user_feedback && typeof task.user_feedback === 'object' ? JSON.parse(JSON.stringify(task.user_feedback)) : null,
    quality_gate: task.quality_gate && typeof task.quality_gate === 'object' ? JSON.parse(JSON.stringify(task.quality_gate)) : null,
    next_candidates: JSON.parse(JSON.stringify(candidates)),
    recommended_action: recommended ? JSON.parse(JSON.stringify(recommended)) : null,
    recovery_policy: '先执行当前协议只读扫描；旧完成项仅作证据，不自动视为新质量门通过。',
  };
}

function inferLegacyProjectTitle(root, inspection) {
  const outline = inspection.asset_mapping.outline;
  if (!outline || !outline.source) return '';
  const text = fs.readFileSync(path.join(root, outline.source), 'utf8');
  const match = text.match(/^#\s*(?:小节大纲(?:\.md)?|大纲)\s*[｜|：:]\s*(.+?)\s*$/mu);
  return match ? String(match[1] || '').trim() : '';
}

function preflightMigration(root, inspection) {
  const outline = inspection.asset_mapping.outline;
  const outlineFile = path.join(root, outline.source);
  const plannedSections = outlineSectionCount(fs.readFileSync(outlineFile, 'utf8'));
  if (!plannedSections) {
    return {
      status: 'blocked_legacy_short_plan_unreadable',
      message: '旧小节大纲未识别到连续小节标题；请先补齐“第 N 节：标题”或“第 N 节｜标题”后再迁移。',
    };
  }
  const state = readShortProjectState(root);
  const owner = String((state || {}).active_write_workflow_id || '').trim();
  if (owner) {
    return {
      status: 'blocked_legacy_short_project_owned',
      message: `短篇目录已由活动写作任务 ${owner} 接管；请先在该任务中恢复或结束，再迁移旧结构。`,
      owner_workflow_id: owner,
    };
  }
  return { status: 'ok', planned_sections: plannedSections };
}

function createShortWorkflow(root, legacyTitle = '') {
  const script = path.join(__dirname, 'workflow-state-machine.js');
  const userGoal = legacyTitle ? `恢复旧短篇任务：${legacyTitle}` : '升级旧版短篇项目并恢复';
  const child = spawnSync(process.execPath, [script, 'create', '--workflow-type', 'short_write', '--project-root', root, '--scope', '全篇', '--user-goal', userGoal, '--json'], { encoding: 'utf8' });
  if (child.status !== 0) throw new Error(String(child.stdout || child.stderr || 'workflow create failed').trim());
  const parsed = JSON.parse(child.stdout);
  if (parsed.status !== 'created' || !parsed.task) throw new Error(`unexpected workflow create result: ${child.stdout}`);
  return parsed;
}

function atomicCopy(source, target) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const temporary = `${target}.migration-${process.pid}.tmp`;
  fs.copyFileSync(source, temporary, fs.constants.COPYFILE_EXCL);
  fs.renameSync(temporary, target);
}

function countMatchingFiles(dir, pattern) {
  try { return fs.readdirSync(dir).filter((name) => pattern.test(name)).length; } catch (_) { return 0; }
}

function digestFile(file) {
  fs.accessSync(file, fs.constants.R_OK);
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}
function result(status, fields, exitCode) { return { schemaVersion: '1.0.0', status, ...fields, exitCode }; }
function fail(message) { process.stderr.write(`${message}\n`); process.exit(2); }

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot);
  let inspection;
  try {
    inspection = inspectLegacyShort(root);
  } catch (error) {
    const output = result('blocked_legacy_short_asset_unreadable', {
      message: `无法读取旧短篇资产：${path.basename(String(error.path || 'unknown'))}`,
      asset_path: error.path ? path.relative(root, error.path).replace(/\\/g, '/') : '',
      error_code: String(error.code || 'READ_FAILED'),
      creative_assets_modified: false,
    }, 2);
    process.stdout.write(`${JSON.stringify(output, null, args.json ? 2 : 0)}\n`);
    process.exitCode = output.exitCode;
    return;
  }
  const preflight = preflightMigration(root, inspection);
  const { status: preflightStatus, ...preflightDetails } = preflight;
  let output;
  if (preflightStatus === 'blocked_legacy_short_project_owned') {
    output = result('legacy_short_project_already_managed', {
      ...inspection,
      ...preflightDetails,
      requires_confirmation: false,
      creative_assets_modified: false,
    }, 0);
  } else if (preflightStatus !== 'ok') {
    output = result(preflightStatus, {
      ...inspection,
      ...preflightDetails,
      requires_confirmation: false,
      creative_assets_modified: false,
    }, 2);
  } else if (!args.write) {
    output = result('legacy_short_migration_preview', {
      ...inspection,
      ...preflightDetails,
      requires_confirmation: true,
      confirmation_command: 'node scripts/legacy-short-project-migrate.js --project-root . --write --confirm --json',
      creative_assets_modified: false,
    }, 0);
  } else if (!args.confirm) {
    output = result('blocked_legacy_short_migration_confirmation_required', { ...inspection, creative_assets_modified: false }, 2);
  } else {
    output = migrate(root, inspection);
  }
  process.stdout.write(`${JSON.stringify(output, null, args.json ? 2 : 0)}\n`);
  process.exitCode = output.exitCode;
}

if (require.main === module) main();

module.exports = { inspectLegacyShort };
