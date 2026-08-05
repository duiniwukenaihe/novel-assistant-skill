'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {
  acquireNamedProjectLock,
  atomicWriteJson,
  atomicWriteText,
  createWorkflowId,
} = require('../../workflow-state-store');
const engine = require('../engine');
const {
  ensureShortProjectState,
  advanceShortPlanRevision,
  outlineSectionCount,
  readShortProjectState,
  shortStateFile,
} = require('../../short-project-state');

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
  const projectStateFile = shortStateFile(root, 'project-state.json', { forWrite: true });
  const projectStateBefore = fs.existsSync(projectStateFile) ? fs.readFileSync(projectStateFile, 'utf8') : null;
  const migrationFile = path.join(root, migrationRel);
  const workflowId = createWorkflowId('short_write');
  let legacyTaskMoved = false;
  let migrationRecordCreated = false;
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
    const projectTitle = inferLegacyProjectTitle(root, inspection) || path.basename(root);
    const projectState = ensureShortProjectState(root, {
      workflowId,
      title: projectTitle,
      status: 'migration_pending_revalidation',
    });
    const plannedState = advanceShortPlanRevision(root, {
      workflowId,
      title: projectState.project_title,
      outlinePath: '小节大纲.md',
    });
    const record = {
      schemaVersion: '1.0.0',
      migration_id: migrationId,
      source_kind: 'legacy_short_project',
      workflow_id: workflowId,
      created_at: new Date().toISOString(),
      asset_mapping: inspection.asset_mapping,
      created_canonical_assets: created,
      preserved_legacy_assets: Object.values(inspection.asset_mapping).map((item) => item.source).filter(Boolean),
      section_file_count: inspection.section_file_count,
      brief_file_count: inspection.brief_file_count,
      legacy_task_snapshot: legacySnapshotRel,
      legacy_task_summary: inspection.legacy_task_summary,
      next_stage: 'creative_entry',
      revalidation_required: true,
    };
    atomicWriteJson(migrationFile, record);
    migrationRecordCreated = true;

    const legacyResume = inspection.__legacy_task
      ? buildLegacyResume(inspection.__legacy_task, legacySnapshotRel)
      : null;
    const userGoal = inspection.__legacy_task
      ? `恢复旧短篇任务：${legacyTitle || projectState.project_title}`
      : (legacyTitle ? `恢复旧短篇任务：${legacyTitle}` : '升级旧版短篇项目并恢复');
    const authorChoice = createShortWorkflow(root, {
      workflow_id: workflowId,
      workflow_type: 'short_write',
      workflow_profile: 'private',
      production_kernel: 'short-v3',
      user_goal: userGoal,
      book_root: '.',
      migration: {
        source_kind: 'legacy_short_project',
        migration_id: migrationId,
        migration_record: migrationRel,
        legacy_task_snapshot: legacySnapshotRel,
        revalidation_required: true,
        creative_assets_modified: created.length > 0,
      },
      ...(legacyResume ? {
        legacy_resume: legacyResume,
        lifecycle: {
          user_goal: userGoal,
          migration_source_stage: legacyResume.source_stage,
          migration_source_status: legacyResume.source_status,
        },
      } : {}),
      project_identity: {
        project_id: plannedState.project_id,
        working_title: plannedState.project_title,
        status: plannedState.status,
      },
    },
      {
        kind: 'needs_author_choice',
        code: 'legacy_project_recovery_choice_required',
        stage_id: 'creative_entry',
        question: '旧短篇已经安全导入 V3。请选择恢复方式，也可以直接输入修改意见。',
        options: [
          { action_id: 'inspect_legacy_checkpoint', label: '查看旧断点、反馈与质量依据（推荐）' },
          { action_id: 'prepare_v3_recovery_plan', label: '根据旧证据生成 V3 恢复方案' },
          { action_id: 'pause_legacy_import', label: '暂停并保存导入结果' },
        ],
      },
    );
    const task = authorChoice.task;
    return result('legacy_short_migration_applied', {
      workflow_id: task.workflow_id,
      workflow_type: 'short_write',
      current_stage: authorChoice.task.current_stage,
      state_version: authorChoice.task.state_version,
      pending_action_id: String(((authorChoice.task.pending_action || {}).id) || ''),
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
    if (migrationRecordCreated && fs.existsSync(migrationFile)) {
      try { fs.unlinkSync(migrationFile); } catch (_) { /* best effort rollback */ }
    }
    try {
      if (projectStateBefore === null) {
        if (fs.existsSync(projectStateFile)) fs.unlinkSync(projectStateFile);
      } else {
        atomicWriteText(projectStateFile, projectStateBefore);
      }
    } catch (_) { /* best effort rollback */ }
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
  for (const asset of Object.values(inspection.asset_mapping)) {
    if (!asset.source || asset.source === asset.target) continue;
    const target = path.join(root, asset.target);
    if (fs.existsSync(target) && digestFile(target) !== asset.source_digest) {
      return {
        status: 'blocked_legacy_short_canonical_conflict',
        source: asset.source,
        target: asset.target,
      };
    }
  }
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

function createShortWorkflow(root, task, authorChoice) {
  return engine.createTaskWithInitialInteraction(root, task, authorChoice);
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
function runLegacyShortProjectMigration(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const args = { write: Boolean(options.write), confirm: Boolean(options.confirm) };
  let releaseMigrationLock = null;
  if (args.write && args.confirm) {
    try {
      releaseMigrationLock = acquireNamedProjectLock(root, {
        relativeDir: path.join('追踪', 'workflow'),
        lockName: '.legacy-short-migration.lock',
        owner: 'workflow-v3-legacy-short-migration',
        ttlMs: 5 * 60 * 1000,
        errorCode: 'LEGACY_SHORT_MIGRATION_LOCKED',
        errorLabel: 'legacy short migration lock',
      });
    } catch (error) {
      if (error && error.code === 'LEGACY_SHORT_MIGRATION_LOCKED') {
        return result('blocked_legacy_short_migration_locked', {
          message: '另一个旧短篇导入正在执行；本次未写入任何资产或控制状态。',
          creative_assets_modified: false,
        }, 2);
      }
      throw error;
    }
  }
  try {
    let inspection;
    try {
      inspection = inspectLegacyShort(root);
    } catch (error) {
      return result('blocked_legacy_short_asset_unreadable', {
        message: `无法读取旧短篇资产：${path.basename(String(error.path || 'unknown'))}`,
        asset_path: error.path ? path.relative(root, error.path).replace(/\\/g, '/') : '',
        error_code: String(error.code || 'READ_FAILED'),
        creative_assets_modified: false,
      }, 2);
    }
    const preflight = preflightMigration(root, inspection);
    const { status: preflightStatus, ...preflightDetails } = preflight;
    if (preflightStatus === 'blocked_legacy_short_project_owned') {
      return result('legacy_short_project_already_managed', {
        ...inspection,
        ...preflightDetails,
        requires_confirmation: false,
        creative_assets_modified: false,
      }, 0);
    }
    if (preflightStatus !== 'ok') {
      return result(preflightStatus, {
        ...inspection,
        ...preflightDetails,
        requires_confirmation: false,
        creative_assets_modified: false,
      }, 2);
    }
    if (!args.write) {
      return result('legacy_short_migration_preview', {
        ...inspection,
        ...preflightDetails,
        requires_confirmation: true,
        confirmation_command: 'node scripts/legacy-short-project-migrate.js --project-root . --write --confirm --json',
        creative_assets_modified: false,
      }, 0);
    }
    if (!args.confirm) {
      return result('blocked_legacy_short_migration_confirmation_required', { ...inspection, creative_assets_modified: false }, 2);
    }
    return migrate(root, inspection);
  } finally {
    if (releaseMigrationLock) releaseMigrationLock();
  }
}

module.exports = { inspectLegacyShort, runLegacyShortProjectMigration };
