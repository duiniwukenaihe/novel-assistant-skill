#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const {
  LIFECYCLE_NODES,
  normalizeLifecycleState,
  deriveMaturity,
} = require('./lib/longform-lifecycle');

const USAGE = 'Usage: node scripts/longform-lifecycle-status.js --project-root <book-dir> [--json]';

const INDEX_PATHS = [
  '追踪/workflow/longform-lifecycle.json',
  '追踪/longform-lifecycle.json',
  '.longform-lifecycle.json',
];

const REVIEW_ACCEPTANCE_PATHS = [
  '追踪/workflow/longform-review-acceptances.json',
  '追踪/longform-review-acceptances.json',
];

const ASSET_PATHS = {
  positioning: ['创作定位.md', '定位.md', '大纲/创作定位.md', '大纲/定位.md'],
  story_bible: ['创作圣经.md', '设定.md', '设定/创作圣经.md'],
  master_outline: ['大纲/总纲.md', '总纲.md'],
  volume_outline: ['大纲/卷纲.md', '大纲/第1卷/卷纲.md'],
  stage_detail_outline: ['大纲/细纲.md', '大纲/第1卷/细纲.md', '大纲/第1卷/阶段细纲.md'],
  chapter_brief: ['大纲/第1卷/Brief.md', '大纲/第1卷/章节 Brief.md'],
  prose: ['正文.md', '正文'],
};

const ACTIONS = {
  positioning: ['define_positioning', '明确作品定位'],
  story_bible: ['build_story_bible', '补全故事核心与创作圣经'],
  master_outline: ['develop_master_outline', '完善总纲'],
  master_outline_review: ['review_master_outline', '审阅并确认总纲'],
  volume_outline: ['develop_volume_outline', '完善卷纲'],
  volume_outline_review: ['review_volume_outline', '审阅并确认卷纲'],
  stage_detail_outline: ['develop_stage_detail_outline', '完善阶段细纲'],
  detail_outline_review: ['review_detail_outline', '审阅并确认阶段细纲'],
  chapter_brief: ['create_chapter_brief', '生成当前章节 Brief'],
  brief_review: ['review_chapter_brief', '审阅并确认当前章节 Brief'],
  prose: ['start_prose', '开始正文生产'],
  prose_acceptance: ['review_prose', '验收当前正文'],
  chapter_commit: ['commit_chapter_facts', '提交章节事实与记忆'],
  milestone_review: ['review_milestone', '进行阶段复盘'],
  volume_acceptance: ['accept_volume', '完成卷级验收与跨卷交接'],
  book_acceptance: ['accept_book', '完成全书验收'],
};

const REVIEW_FOR_ASSET = {
  master_outline: 'master_outline_review',
  volume_outline: 'volume_outline_review',
  stage_detail_outline: 'detail_outline_review',
  chapter_brief: 'brief_review',
};

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(1);
}

function parseArgs(argv) {
  const args = { projectRoot: '', json: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else fail(`Unknown argument: ${arg}`);
  }
  if (!args.projectRoot) fail('missing --project-root');
  return args;
}

function readJson(file) {
  try {
    return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
  } catch {
    return null;
  }
}

function firstExistingJson(root, candidates) {
  for (const relativePath of candidates) {
    const file = path.join(root, relativePath);
    const value = readJson(file);
    if (value) return { file, relativePath, value };
  }
  return { file: '', relativePath: '', value: null };
}

function rel(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function hasCandidateAsset(root, id) {
  const candidates = ASSET_PATHS[id] || [];
  for (const relativePath of candidates) {
    if (fs.existsSync(path.join(root, relativePath))) return relativePath;
  }
  if (id === 'volume_outline' || id === 'stage_detail_outline' || id === 'chapter_brief') {
    const outlineRoot = path.join(root, '大纲');
    try {
      for (const entry of fs.readdirSync(outlineRoot, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const name = entry.name;
        const files = fs.readdirSync(path.join(outlineRoot, name));
        if (id === 'volume_outline' && files.some(file => /卷纲/.test(file))) return `大纲/${name}`;
        if (id === 'stage_detail_outline' && files.some(file => /细纲/.test(file))) return `大纲/${name}`;
        if (id === 'chapter_brief' && files.some(file => /brief/i.test(file))) return `大纲/${name}`;
      }
    } catch {
      return '';
    }
  }
  return '';
}

function acceptedReviewIds(value) {
  const accepted = new Set();
  const add = (item) => {
    if (typeof item === 'string') accepted.add(item);
    if (item && typeof item === 'object') {
      const id = item.asset_id || item.assetId || item.lifecycle_id || item.lifecycleId || item.id;
      const status = String(item.status || item.decision || '').toLowerCase();
      if (id && (!status || ['accepted', 'approved', 'pass', 'completed'].includes(status))) accepted.add(String(id));
    }
  };
  if (!value || typeof value !== 'object') return accepted;
  for (const key of ['accepted', 'accepted_reviews', 'reviews', 'records']) {
    if (Array.isArray(value[key])) value[key].forEach(add);
  }
  return accepted;
}

function indexState(value) {
  if (!value || typeof value !== 'object') return {};
  return value.assets || value.longform_lifecycle || value.lifecycle || value;
}

function discoverLifecycleAssets(projectRoot) {
  const root = path.resolve(projectRoot);
  const index = firstExistingJson(root, INDEX_PATHS);
  const acceptance = firstExistingJson(root, REVIEW_ACCEPTANCE_PATHS);
  const state = normalizeLifecycleState(indexState(index.value));
  const acceptedReviews = acceptedReviewIds(acceptance.value);
  const assets = LIFECYCLE_NODES.map((node) => {
    const detectedPath = hasCandidateAsset(root, node.id);
    let status = state[node.id];
    if (acceptedReviews.has(node.id)) status = 'accepted';
    else if (detectedPath && status === 'missing') status = 'needs_review';
    return {
      id: node.id,
      label: node.label,
      status,
      source_path: detectedPath,
    };
  });
  return {
    assets,
    lifecycle_index_path: index.relativePath,
    review_acceptance_path: acceptance.relativePath,
  };
}

function nextActionAsset(assets) {
  const byId = new Map(assets.map(asset => [asset.id, asset]));
  const repair = LIFECYCLE_NODES.find(node => ['invalidated', 'needs_recheck'].includes(byId.get(node.id).status));
  if (repair) return repair.id;
  const pendingEvidence = LIFECYCLE_NODES.find(node => byId.get(node.id).status === 'needs_review');
  if (pendingEvidence) {
    const reviewId = REVIEW_FOR_ASSET[pendingEvidence.id];
    return byId.has(reviewId) ? reviewId : pendingEvidence.id;
  }
  return LIFECYCLE_NODES.find(node => byId.get(node.id).status !== 'accepted')?.id || '';
}

function blockingGaps(assets, targetId) {
  if (Object.values(REVIEW_FOR_ASSET).includes(targetId)) return [];
  const targetOrder = LIFECYCLE_NODES.find(node => node.id === targetId)?.order ?? -1;
  return assets
    .filter(asset => LIFECYCLE_NODES.find(node => node.id === asset.id).order < targetOrder && asset.status !== 'accepted')
    .map(asset => asset.id);
}

function buildLifecycleStatus(projectRoot) {
  const root = path.resolve(projectRoot);
  const discovered = discoverLifecycleAssets(root);
  const state = Object.fromEntries(discovered.assets.map(asset => [asset.id, asset.status]));
  const targetId = nextActionAsset(discovered.assets);
  const action = targetId ? ACTIONS[targetId] : null;
  const gaps = targetId ? blockingGaps(discovered.assets, targetId) : [];
  return {
    status: action ? (gaps.length ? 'blocked' : 'action_required') : 'complete',
    maturity: deriveMaturity(state),
    assets: discovered.assets,
    recommended_actions: action ? [{
      action_id: action[0],
      target_asset: targetId,
      label: action[1],
      blocking_gaps: gaps,
    }] : [],
    blocking_gaps: gaps,
    lifecycle_index_path: discovered.lifecycle_index_path,
    review_acceptance_path: discovered.review_acceptance_path,
    project_root: root,
    readPolicy: 'metadata_only',
  };
}

function print(result, json) {
  if (json) console.log(JSON.stringify(result, null, 2));
  else if (result.recommended_actions.length) console.log(result.recommended_actions[0].label);
  else console.log('长篇生命周期：已完成。');
}

function main() {
  const args = parseArgs(process.argv);
  print(buildLifecycleStatus(args.projectRoot), args.json);
}

if (require.main === module) main();

module.exports = { buildLifecycleStatus, discoverLifecycleAssets };
