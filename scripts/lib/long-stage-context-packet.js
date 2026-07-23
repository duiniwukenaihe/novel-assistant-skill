'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { compactToTokens, estimateTokens } = require('./context-budget');
const { atomicWriteJson, atomicWriteText } = require('./workflow-state-store');

const LONG_STAGES = new Set(['chapter_brief', 'brief_review', 'prose', 'prose_acceptance', 'chapter_commit']);
const DEFAULT_TOKEN_BUDGET = 6000;

function buildLongStageContextPacket({ projectRoot, task, stage, options = {} } = {}) {
  const root = path.resolve(projectRoot || '');
  const stageId = String(stage || (task || {}).current_stage || '');
  if (!root || !fs.existsSync(root) || String((task || {}).workflow_type || '') !== 'long_write' || !LONG_STAGES.has(stageId)) {
    return { status: 'not_applicable', reason: 'not_long_chapter_stage' };
  }
  const chapter = inferLongChapter(root, task, stageId);
  if (!chapter) return { status: 'not_applicable', reason: 'chapter_identity_missing' };
  const volume = inferVolume(task);
  const contextPack = buildContextPack(root, chapter, volume);
  const draft = ['prose_acceptance', 'chapter_commit'].includes(stageId) ? resolveChapterDraft(root, task, chapter, volume) : '';
  const tokenBudget = positiveInt(options.tokenBudget) || DEFAULT_TOKEN_BUDGET;
  const entries = [];
  let remaining = tokenBudget;

  const contextText = JSON.stringify(compactContextPack(contextPack), null, 2);
  const compactContext = compactToTokens(contextText, Math.min(remaining, 3000));
  entries.push({ id: 'chapter_context', path: contextPack.__path || '', kind: 'chapter_context', content: compactContext, estimated_tokens: estimateTokens(compactContext) });
  remaining -= entries[0].estimated_tokens;

  if (draft) {
    const draftText = fs.readFileSync(draft, 'utf8');
    const compactDraft = compactToTokens(draftText, Math.max(500, remaining));
    entries.push({ id: 'current_chapter_draft', path: relative(root, draft), kind: 'current_draft', content: compactDraft, estimated_tokens: estimateTokens(compactDraft), truncated: compactDraft !== draftText });
  }

  const taskDir = String((task || {}).task_dir || `追踪/workflow/tasks/${(task || {}).workflow_id || 'long-write'}`);
  const base = `${taskDir}/context-packets/${stageId}/chapter-${String(chapter).padStart(3, '0')}`;
  const packetMd = `${base}/stage-context.md`;
  const packetJson = `${base}/stage-context.json`;
  const markdown = renderMarkdown({ task, stageId, chapter, volume, tokenBudget, entries });
  atomicWriteText(path.join(root, packetMd), markdown);
  atomicWriteJson(path.join(root, packetJson), {
    schemaVersion: '1.0.0', workflow_id: String((task || {}).workflow_id || ''), workflow_type: 'long_write',
    stage_id: stageId, chapter, volume, packet_md: packetMd, packet_json: packetJson, token_budget: tokenBudget,
    estimated_tokens: entries.reduce((sum, entry) => sum + entry.estimated_tokens, 0),
    source_files: entries.map(({ id, path: filePath, kind }) => ({ id, path: filePath, kind })),
    excludes: ['完整总纲/卷纲/细纲原文', '完整任务日志和历史回执', '平台脚本源码', '无关章节正文', '旧聊天转录'],
    created_at: new Date().toISOString(),
  });
  return { status: 'assembled', packet_md: packetMd, packet_json: packetJson, chapter, volume, estimated_tokens: entries.reduce((sum, entry) => sum + entry.estimated_tokens, 0), token_budget: tokenBudget, source_files: entries.map(({ id, path: filePath, kind }) => ({ id, path: filePath, kind })), draft: draft ? relative(root, draft) : '' };
}

function inferLongChapter(root, task, stageId) {
  const text = `${String((task || {}).scope || '')}\n${String((task || {}).user_goal || '')}`;
  const matches = [...text.matchAll(/第\s*0*(\d+)\s*章/g)].map((match) => Number(match[1])).filter(Number.isInteger);
  if (matches.length) return matches[matches.length - 1];
  const contract = readJson(path.join(root, '追踪/schema/current-contract.json'));
  if (positiveInt((contract || {}).chapterNo)) return positiveInt(contract.chapterNo);
  const bookState = readJson(path.join(root, '.book-state.json')) || {};
  const current = positiveInt(bookState.currentChapter);
  if (current) return ['chapter_brief', 'brief_review', 'prose'].includes(stageId) ? current + 1 : current;
  const schema = readJson(path.join(root, '追踪/schema/story-schema.json')) || readJson(path.join(root, '追踪/schema/story.json')) || {};
  const schemaCurrent = positiveInt(schema.currentChapter || ((schema.progress || {}).currentChapter));
  return schemaCurrent ? (['chapter_brief', 'brief_review', 'prose'].includes(stageId) ? schemaCurrent + 1 : schemaCurrent) : 0;
}

function inferVolume(task) {
  const match = `${String((task || {}).scope || '')} ${String((task || {}).user_goal || '')}`.match(/第\s*([0-9一二三四五六七八九十百]+)\s*卷/);
  return match ? `第${match[1]}卷` : '';
}

function buildContextPack(root, chapter, volume) {
  const args = [path.join(__dirname, '..', 'context-pack-build.js'), root, '--chapter', String(chapter), '--mode', 'writing', '--write', '--json'];
  if (volume) args.push('--volume', volume);
  const run = spawnSync(process.execPath, args, { cwd: root, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  const parsed = parseJson(run.stdout) || { gate: { status: 'fail', blockingFindings: [{ code: 'context_pack_failed', message: String(run.stderr || '').slice(0, 500) }] }, summary: {}, sourceFiles: {} };
  parsed.__path = contextPackRelative(chapter, volume);
  return parsed;
}

function compactContextPack(pack) {
  return {
    target: pack.target || {}, gate: pack.gate || {}, sourceFiles: pack.sourceFiles || {},
    mustCarryForward: ((pack.summary || {}).mustCarryForward || []).slice(0, 20),
    forbiddenChanges: ((pack.summary || {}).forbiddenChanges || []).slice(0, 15),
    openForeshadows: ((pack.summary || {}).openForeshadows || []).slice(0, 20),
    characterState: ((pack.summary || {}).characterState || []).slice(0, 20),
    recentStateDelta: ((pack.summary || {}).recentStateDelta || []).slice(0, 12),
    timeline: ((pack.summary || {}).timeline || []).slice(0, 12),
    continuityQuestions: ((pack.summary || {}).continuityQuestions || []).slice(0, 12),
  };
}

function resolveChapterDraft(root, task, chapter, volume) {
  const roots = [path.join(root, String((task || {}).task_dir || ''), 'artifacts'), path.join(root, '追踪/story-system/work', String((task || {}).workflow_id || '')), path.join(root, '正文')];
  const candidates = [];
  for (const base of roots) walk(base, 5, (file) => { const rel = relative(root, file); const baseName = path.basename(file); if (!/\.md$/i.test(baseName)) return; if (chapterNumber(baseName) !== chapter) return; if (volume && (rel.startsWith('正文/') || rel.includes('/正文/')) && !rel.includes(`/${volume}/`)) return; candidates.push(file); });
  candidates.sort((a, b) => scoreDraft(b) - scoreDraft(a) || fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  return candidates[0] || '';
}

function walk(dir, depth, visit) { if (depth < 0 || !dir || !fs.existsSync(dir)) return; let entries = []; try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; } for (const entry of entries) { const file = path.join(dir, entry.name); if (entry.isDirectory()) walk(file, depth - 1, visit); else if (entry.isFile()) visit(file); } }
function chapterNumber(name) { const match = String(name || '').match(/第\s*0*(\d+)\s*章/); return match ? Number(match[1]) : 0; }
function scoreDraft(file) { const rel = String(file).replace(/\\/g, '/'); return /story-system\/work/.test(rel) ? 30 : /候选|草稿/.test(rel) ? 20 : /正文/.test(rel) ? 10 : 0; }
function contextPackRelative(chapter, volume) { return `${volume ? `追踪/context-pack/${volume}` : '追踪/context-pack'}/第${String(chapter).padStart(3, '0')}章.json`; }
function renderMarkdown({ task, stageId, chapter, volume, tokenBudget, entries }) { const lines = [`# 长篇当前章节最小上下文包`, '', `> workflow=${task.workflow_id || ''} stage=${stageId} chapter=${chapter}${volume ? ` volume=${volume}` : ''}`, `> 预算 ${tokenBudget} tokens。只使用包内内容；发现 gate.fail 时修复缺口，不得自由扩读。`, '']; for (const entry of entries) { lines.push(`## ${entry.id}`, `路径：${entry.path || '内嵌摘要'}`, '', entry.content, ''); } lines.push('## 禁止扩读', '- 完整总纲、卷纲、细纲原文', '- 完整任务日志和历史回执', '- 平台脚本源码', '- 无关章节正文和旧聊天'); return `${lines.join('\n')}\n`; }
function relative(root, file) { return path.relative(root, file).split(path.sep).join('/'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
function positiveInt(value) { const n = Number(value); return Number.isInteger(n) && n > 0 ? n : 0; }

module.exports = { LONG_STAGES, buildLongStageContextPacket, inferLongChapter, resolveChapterDraft };
