#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { buildHotSourceSelection } = require('./lib/hot-source-registry');
const { resolvePrivateModule } = require('./lib/private-runtime-resolver');

const TOPIC_SEED_PATTERN = /彩礼|断亲|打脸|反杀|复仇|追妻|火葬场|重生|真假千金/u;

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: args.workflowId }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'info_source_pool'
      || String(execution.status || '') !== 'running'
      || String(execution.stage_id || '') !== 'info_source_pool') {
    return finish({ status: 'short_info_source_stage_not_running', current_stage: String(task.current_stage || '') }, 0, args.json);
  }
  const captureRel = String(execution.info_source_capture || `${task.task_dir}/artifacts/info-source-pool/source-capture.json`);
  const captureFile = safeProjectFile(root, captureRel);
  const captureCommand = buildCaptureCommand(task, captureRel);
  if (!isFile(captureFile)) {
    return finish({
      status: 'short_info_source_capture_required',
      source_capture_path: captureRel,
      capture_command: captureCommand,
      instruction: '运行 capture_command，由私有确定性采集器生成来源快照；不要自行 WebFetch/WebSearch 拼接热点。',
    }, 0, args.json);
  }
  const capture = readJson(captureFile);
  const captureFindings = validateCapture(capture, captureFile);
  if (captureFindings.length) {
    return finish({
      status: 'short_info_source_capture_revision_required',
      source_capture_path: captureRel,
      findings: captureFindings,
      capture_command: captureCommand,
      instruction: '重新运行确定性采集命令；不得把搜索摘要或模型推测标记为实时来源成功。',
    }, 0, args.json);
  }
  const privateRuntime = resolvePrivateRuntime();
  if (!privateRuntime) return finish({ status: 'private_short_runtime_missing' }, 1, args.json);
  const sourceProfiles = readJson(privateRuntime.profiles) || {};
  const sourceProviders = readJson(privateRuntime.providers) || {};
  const selection = buildHotSourceSelection(sourceProfiles, { availableIds: Object.keys(sourceProviders.source_routes || {}) });
  const captureDiscovery = capture.discovery_evidence && typeof capture.discovery_evidence === 'object' ? capture.discovery_evidence : {};
  const attempts = Array.isArray(captureDiscovery.source_attempts) ? captureDiscovery.source_attempts : [];
  const successful = attempts.filter(item => String((item || {}).status || '') === 'success');
  const fallbackPlan = Array.isArray(capture.fallback_plan) ? capture.fallback_plan : [];
  if (successful.length < selection.minimumSuccessfulSources && fallbackPlan.length) {
    const externalRel = path.posix.join(path.posix.dirname(captureRel), 'external-hits.json');
    return finish({
      status: 'short_info_source_external_fallback_required',
      source_capture_path: captureRel,
      external_hits_path: externalRel,
      successful_sources: successful.length,
      required_successful_sources: selection.minimumSuccessfulSources,
      fallback_plan: fallbackPlan,
      external_hits_schema: {
        schemaVersion: '1.0.0',
        queried_at: 'ISO-8601 time',
        methods: ['browser_cdp or web_search or site_search'],
        queries: ['实际使用的查询'],
        hits: [{ source_id: '', source_name: '', title: '', url: '', summary: '', observed_at: 'YYYY-MM-DD', rank: 1, heat_signal: 'public_hotlist_rank', heat_value: '1' }],
      },
      capture_command: buildCaptureCommand(task, captureRel, externalRel),
      instruction: '按 fallback_plan 读取公开可见榜面；把真实标题、原链接、观测时间和榜位写入 external_hits_path，再运行 capture_command。',
    }, 0, args.json);
  }
  const candidateRel = String(execution.info_source_candidate || `${task.task_dir}/artifacts/info-source-pool/discovery-result.json`);
  const candidateFile = safeProjectFile(root, candidateRel);
  if (!isFile(candidateFile)) {
    const contextRel = path.posix.join(path.posix.dirname(candidateRel), 'enrichment-context.json');
    atomicWriteJson(safeProjectFile(root, contextRel), buildInfoSourceEnrichmentContext(capture, 12, task));
    return finish({
      status: 'short_info_source_card_enrichment_required',
      candidate_path: candidateRel,
      context_path: contextRel,
      capture_id: String(capture.capture_id || ''),
      instruction: '只读取 context_path，按其中 candidate_shape 生成 info_source_cards；资讯只评估写作价值，不展开完整故事。每张卡必须保留 capture_refs，不再联网抓取，也不得读取原始来源快照或校验器源码。',
    }, 0, args.json);
  }
  const payload = normalizeCandidatePayload(readJson(candidateFile), capture);
  if (!payload) return finish({ status: 'short_info_source_candidate_invalid_json', candidate_path: candidateRel }, 0, args.json);
  payload.capture_id = String(capture.capture_id || '');
  payload.discovery_evidence = captureDiscovery;
  atomicWriteJson(candidateFile, payload);
  const discovery = captureDiscovery;
  const queries = Array.isArray(discovery.queries) ? discovery.queries.map(String) : [];
  const attemptedIds = new Set(attempts.map(item => String((item || {}).source_id || '')).filter(Boolean));
  const missingSources = selection.selectedIds.filter(id => !attemptedIds.has(id));
  const invalidSkipped = attempts.filter(item => String((item || {}).status || '') === 'skipped' && !String((item || {}).skip_reason || '').trim());
  const seededQueries = queries.filter(query => TOPIC_SEED_PATTERN.test(query));
  const evidenceFindings = [];
  if (discovery.performed !== true) evidenceFindings.push({ code: 'live_discovery_not_performed' });
  if (!String(discovery.queried_at || '').trim()) evidenceFindings.push({ code: 'queried_at_missing' });
  if (!hasCurrentCaptureMethod(discovery.methods)) evidenceFindings.push({ code: 'current_source_capture_evidence_missing' });
  if (missingSources.length) evidenceFindings.push({ code: 'selected_sources_not_attempted', source_ids: missingSources });
  if (invalidSkipped.length) evidenceFindings.push({ code: 'skipped_source_reason_missing', source_ids: invalidSkipped.map(item => String(item.source_id || '')) });
  if (successful.length < selection.minimumSuccessfulSources) evidenceFindings.push({ code: 'successful_sources_insufficient', actual: successful.length, required: selection.minimumSuccessfulSources });
  if (seededQueries.length) evidenceFindings.push({ code: 'fiction_trope_seeded_discovery_query', queries: seededQueries });
  const captureItems = new Set((Array.isArray(capture.source_items) ? capture.source_items : []).map(item => String((item || {}).capture_item_id || '')).filter(Boolean));
  const cards = Array.isArray(payload.info_source_cards) ? payload.info_source_cards : [];
  const unlinkedCards = cards.filter(card => ['hot_topic', 'news_event'].includes(String((card || {}).source_kind || ''))
    && !(Array.isArray((card || {}).capture_refs)
      && card.capture_refs.length > 0
      && card.capture_refs.every(ref => captureItems.has(String(ref)))));
  if (unlinkedCards.length) evidenceFindings.push({ code: 'capture_lineage_missing', info_ids: unlinkedCards.map(card => String(card.info_id || '')) });
  if (evidenceFindings.length) {
    return finish({
      status: 'short_info_source_discovery_revision_required',
      candidate_path: candidateRel,
      findings: evidenceFindings,
      instruction: '只修正缺少采集血缘的资讯卡，或按 fallback_plan 用浏览器/联网搜索补齐真实榜面证据后重新运行采集器；不要把搜索摘要伪装成热榜。',
    }, 0, args.json);
  }

  const validation = run(process.env.PYTHON || 'python3', [privateRuntime.pipeline, 'validate-fresh', candidateFile, '--policy', privateRuntime.policy], root);
  const validationJson = parseJson(validation.stdout) || { status: 'error', detail: String(validation.stderr || '').trim().slice(0, 500) };
  if (validation.status !== 0) {
    return finish({
      status: 'short_info_source_freshness_revision_required',
      candidate_path: candidateRel,
      validation: validationJson,
      instruction: '按锁定时间窗补真实热点，或报告热点不足并返回时间窗选择；不得用旧案例或方法论补数量。',
    }, 0, args.json);
  }
  const poolAssessment = assessInfoSourcePool(cards);
  if (poolAssessment.status === 'insufficient') {
    return finish({
      status: 'short_info_source_value_insufficient',
      candidate_path: candidateRel,
      assessment: poolAssessment,
      rejected_summary: payload.rejected_summary || {},
      retry_same_candidate: false,
      instruction: '本轮真实热点没有形成可展示的高价值写作素材。保留采集证据，不得补造卡片，也不得重写同一候选；等待作者扩大时间窗、调整来源方向或暂停。',
    }, 0, args.json);
  }
  if (!args.apply) return finish({ status: 'short_info_source_ready', candidate_path: candidateRel, validation: validationJson, assessment: poolAssessment }, 0, args.json);

  const roundId = String(execution.stage_attempt_id || `round-${Date.now()}`);
  const imported = run(process.env.PYTHON || 'python3', [privateRuntime.pipeline, 'info-pool', 'import', '--workspace', root, '--input', candidateFile, '--round', roundId], root);
  const importedJson = parseJson(imported.stdout) || { status: 'error', detail: String(imported.stderr || '').trim().slice(0, 500) };
  if (imported.status !== 0 || String(importedJson.status || '') === 'error') {
    return finish({ status: 'short_info_source_import_blocked', candidate_path: candidateRel, import_result: importedJson }, 0, args.json);
  }

  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/info_source_pool.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  const poolRel = '追踪/private-short-extension/cards/info-source-cards.jsonl';
  atomicWriteJson(packetFile, {
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'info_source_pool',
    step_id: 'info_source_pool',
    owner_module: String(execution.owner_module || 'private-short-extension'),
    step_status: 'completed',
    outputs: [poolRel, candidateRel],
    changed_files: [poolRel],
    created_files: [],
    evidence: [{ capture_id: String(capture.capture_id || ''), source_capture_path: captureRel, attempted_sources: attempts.length, required_selected_sources: selection.selectedIds.length, configured_source_pool_size: selection.configuredIds.length, successful_sources: successful.length, card_assessment: poolAssessment, rejected_summary: payload.rejected_summary || {}, validation: validationJson, import_result: importedJson }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: 'info_source_pool', completed_range: '资讯池已抓取并入库', remaining_range: '从资讯生成脑洞卡', resume_from: '' },
    handoff_summary: poolAssessment.status === 'partial'
      ? `已从 ${successful.length} 个可用来源筛出 ${poolAssessment.visible_count} 张可选资讯卡；本轮素材偏少，但均可直接查看或选择，未为凑数补造卡片。`
      : `已从 ${successful.length} 个可用来源形成 ${poolAssessment.visible_count} 张可选资讯卡，其中 ${poolAssessment.write_count} 张推荐改编。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'), 'apply-result',
    '--project-root', root,
    '--workflow-id', String(task.workflow_id || ''),
    '--result', packetFile,
    '--compact', '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  return finish({
    status: outcome.applied ? 'short_info_source_pool_accepted' : 'short_info_source_pool_apply_blocked',
    workflow_id: String(task.workflow_id || ''),
    candidate_path: candidateRel,
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function resolvePrivateRuntime() {
  const root = resolvePrivateModule('private-short-extension', [
    path.join('scripts', 'card_pipeline.py'),
    path.join('references', 'fresh-news-policy.json'),
    path.join('references', 'hot-source-profiles.json'),
    path.join('references', 'hot-source-providers.json'),
  ]);
  if (!root) return null;
  return {
    pipeline: path.join(root, 'scripts', 'card_pipeline.py'),
    policy: path.join(root, 'references', 'fresh-news-policy.json'),
    profiles: path.join(root, 'references', 'hot-source-profiles.json'),
    providers: path.join(root, 'references', 'hot-source-providers.json'),
  };
}
function buildCaptureCommand(task, captureRel, externalHitsRel = '') {
  const windowDays = Math.max(1, Number((((task || {}).freshness_window || {}).days) || 1));
  const argv = [
    process.execPath,
    path.join(__dirname, 'hot-source-capture.js'),
    '--project-root', '.',
    '--workflow-id', String((task || {}).workflow_id || ''),
    '--window-days', String(windowDays),
    '--as-of', new Date().toISOString().slice(0, 10),
    '--max-items', '3',
    '--output', captureRel,
    '--json',
  ];
  if (externalHitsRel) argv.splice(argv.length - 1, 0, '--external-hits', externalHitsRel);
  return argv.map(value => JSON.stringify(String(value))).join(' ');
}
function validateCapture(capture, captureFile) {
  const findings = [];
  if (!capture || typeof capture !== 'object') return [{ code: 'capture_invalid_json' }];
  const discovery = capture.discovery_evidence && typeof capture.discovery_evidence === 'object' ? capture.discovery_evidence : {};
  if (!String(capture.capture_id || '').trim()) findings.push({ code: 'capture_id_missing' });
  if (!hasCurrentCaptureMethod(discovery.methods)) findings.push({ code: 'current_source_capture_evidence_missing' });
  const attempts = Array.isArray(discovery.source_attempts) ? discovery.source_attempts : [];
  for (const attempt of attempts.filter(item => String((item || {}).status || '') === 'success')) {
    if (!String(attempt.provider || '').trim()) findings.push({ code: 'capture_provider_missing', source_id: String(attempt.source_id || '') });
    const snapshotRel = String(attempt.snapshot_path || '').trim();
    const expectedHash = String(attempt.snapshot_sha256 || '').trim();
    if (!snapshotRel || !expectedHash) {
      findings.push({ code: 'capture_snapshot_evidence_missing', source_id: String(attempt.source_id || '') });
      continue;
    }
    const snapshotFile = path.resolve(path.dirname(captureFile), snapshotRel);
    if (!snapshotFile.startsWith(`${path.dirname(captureFile)}${path.sep}`) || !isFile(snapshotFile)) {
      findings.push({ code: 'capture_snapshot_missing', source_id: String(attempt.source_id || '') });
      continue;
    }
    const actualHash = crypto.createHash('sha256').update(fs.readFileSync(snapshotFile)).digest('hex');
    if (actualHash !== expectedHash) findings.push({ code: 'capture_snapshot_hash_mismatch', source_id: String(attempt.source_id || '') });
  }
  const items = Array.isArray(capture.source_items) ? capture.source_items : [];
  if (!items.length) findings.push({ code: 'capture_items_missing' });
  if (items.some(item => !String((item || {}).capture_item_id || '').trim() || !String((item || {}).url || '').trim())) findings.push({ code: 'capture_item_identity_invalid' });
  return findings;
}
function normalizeCandidatePayload(payload, capture) {
  if (!payload || typeof payload !== 'object') return payload;
  const aliases = Array.isArray(payload.info_source_cards) && payload.info_source_cards.length
    ? payload.info_source_cards
    : Array.isArray(payload.hot_topic_cards)
    ? payload.hot_topic_cards
    : Array.isArray(payload.hot_topics) ? payload.hot_topics : [];
  if (!aliases.length) return payload;
  const items = new Map((Array.isArray((capture || {}).source_items) ? capture.source_items : [])
    .map(item => [String((item || {}).capture_item_id || ''), item]));
  payload.info_source_cards = aliases.map((card, index) => {
    const refs = (Array.isArray((card || {}).capture_refs) ? card.capture_refs : [])
      .map(ref => items.get(String(ref || '')))
      .filter(Boolean);
    const title = String((card || {}).topic_title || (card || {}).title || `热点素材 ${index + 1}`);
    const conflict = String((card || {}).character_conflict || (card || {}).human_conflict || title);
    const providedRoutes = Array.isArray((card || {}).route_fit) ? card.route_fit.filter(item => String(item || '').trim()) : [];
    const angleCandidates = Array.isArray((card || {}).angle_candidates) ? card.angle_candidates.filter(item => String(item || '').trim()) : [];
    const mainRoute = String((card || {}).main_route || angleCandidates[0] || providedRoutes[0] || '').trim();
    const backupRoute = String((card || {}).backup_route || angleCandidates[1] || providedRoutes[1] || '').trim();
    const sourceNames = refs.map(ref => String(ref.source_name || ref.source_id || '')).filter(Boolean);
    const learning = String((card || {}).learning_notes || '').trim() || conflict;
    return normalizeInfoSourceVerdict({
      ...card,
      card_type: 'info_source_card',
      info_id: String((card || {}).info_id || (card || {}).card_id || (card || {}).hot_topic_id || `info-${index + 1}`),
      source_kind: 'hot_topic',
      title,
      capture_refs: refs.map(ref => String(ref.capture_item_id || '')).filter(Boolean),
      source_refs: refs.map(ref => ({
        source: String(ref.source_name || ref.source_id || ''),
        title: String(ref.title || ''),
        url: String(ref.url || ''),
        observed_at: String(ref.observed_at || ''),
        published_at: String(ref.published_at || ''),
        heat_signal: String(ref.heat_signal || ''),
        heat_value: String(ref.heat_value || ref.rank || ''),
        provider: String(ref.provider || ''),
      })),
      factual_summary: String((card || {}).factual_summary || (card || {}).summary || title),
      human_conflict: conflict,
      verdict: String((card || {}).verdict || (card || {}).decision || (card || {}).judgment || 'backup'),
      route_fit: providedRoutes.length ? providedRoutes : [mainRoute, backupRoute].filter(Boolean),
      scorecard: { material_score: Number((card || {}).material_score || 0) },
      event_fingerprint: crypto.createHash('sha256').update(title).digest('hex').slice(0, 16),
      heat_evidence: refs.map(ref => ({
        source: String(ref.source_name || ref.source_id || ''),
        signal: String(ref.heat_signal || 'public_hotlist_rank'),
        value: String(ref.heat_value || ref.rank || ''),
        observed_at: String(ref.observed_at || ''),
      })),
      verification_status: refs.length > 1 ? 'corroborated' : 'single_source',
      discussion_value: {
        question: `围绕“${title}”，人物为何会作出相反选择？`,
        positions: ['维持现状以规避眼前代价', '改变现状并承担后果'],
        fiction_entry: mainRoute || conflict,
      },
      learning_notes: {
        source_pattern: learning,
        reusable_conflict_pattern: conflict,
        platform_signal: sourceNames.join(' / ') || '当前公开热榜',
        query_expansion_hint: String((card || {}).category || title),
        next_reuse_rule: mainRoute || learning,
      },
    });
  });
  return finalizeInfoSourcePayload(payload);
}
function normalizeInfoSourceVerdict(card) {
  const scorecard = card && card.scorecard && typeof card.scorecard === 'object' ? card.scorecard : {};
  const materialScore = Number((card || {}).material_score || scorecard.material_score || 0);
  const rawVerdict = String((card || {}).verdict || (card || {}).decision || 'backup');
  const rawSignals = card && card.story_value_signals && typeof card.story_value_signals === 'object'
    ? card.story_value_signals
    : null;
  const explicitSignals = rawSignals && ['immediate_stakes', 'protagonist_action', 'escalation_path', 'credible_payoff']
    .every(field => String(rawSignals[field] || '').trim())
    ? rawSignals
    : null;
  const discussion = card && card.discussion_value && typeof card.discussion_value === 'object'
    ? card.discussion_value
    : {};
  const angles = Array.isArray((card || {}).angle_candidates) ? card.angle_candidates.map(String).filter(Boolean) : [];
  const routes = Array.isArray((card || {}).route_fit) ? card.route_fit.map(item => typeof item === 'string' ? item : String((item || {}).route_name || '')).filter(Boolean) : [];
  const storyValueSignals = explicitSignals || {
    immediate_stakes: String(discussion.immediate_stakes || (card || {}).human_conflict || (card || {}).character_conflict || ''),
    protagonist_action: String(discussion.protagonist_action || angles[0] || routes[0] || ''),
    escalation_path: String(discussion.escalation_path || angles[1] || (card || {}).human_conflict || (card || {}).character_conflict || ''),
    credible_payoff: String(discussion.credible_payoff || angles[2] || angles[0] || routes[0] || ''),
  };
  const storyValueValid = hasActionableStorySignals(explicitSignals);
  let verdict = rawVerdict;
  if (!storyValueValid) verdict = 'discard';
  else if (verdict === 'write' && materialScore < 8) verdict = 'backup';
  if (verdict === 'backup' && materialScore < 6) verdict = 'discard';
  return {
    ...card,
    verdict,
    decision: verdict,
    scorecard: { ...scorecard, material_score: Number.isFinite(materialScore) ? materialScore : 0 },
    story_value_signals: storyValueSignals,
    story_value_signals_origin: explicitSignals ? 'explicit' : 'derived_legacy',
    story_value_valid: storyValueValid,
  };
}
function finalizeInfoSourcePayload(payload) {
  const cards = Array.isArray(payload.info_source_cards) ? payload.info_source_cards : [];
  const discarded = cards.filter(card => String((card || {}).verdict || '') === 'discard' || (card || {}).story_value_valid !== true);
  payload.info_source_cards = cards
    .filter(card => ['write', 'backup'].includes(String((card || {}).verdict || '')) && (card || {}).story_value_valid === true)
    .sort((left, right) => Number((((right || {}).scorecard || {}).material_score) || 0) - Number((((left || {}).scorecard || {}).material_score) || 0))
    .slice(0, 8);
  payload.rejected_summary = {
    discarded: discarded.length,
    reasons: {
      weak_or_generic_story_engine: discarded.filter(card => (card || {}).story_value_valid !== true).length,
      low_material_score: discarded.filter(card => Number((((card || {}).scorecard || {}).material_score) || 0) < 6).length,
    },
  };
  delete payload.hot_topics;
  delete payload.hot_topic_cards;
  delete payload.info_cards;
  return payload;
}
function buildInfoSourceEnrichmentContext(capture, limit = 12, task = {}) {
  const clusters = clusterCaptureItems(Array.isArray((capture || {}).source_items) ? capture.source_items : []);
  const selected = clusters
    .sort((left, right) => right.story_affordance_score - left.story_affordance_score)
    .slice(0, Math.max(1, Number(limit || 12)))
    .map(compactCaptureCluster);
  return {
    schemaVersion: '1.0.0',
    capture_id: String((capture || {}).capture_id || ''),
    purpose: '从真实热点中筛选有写作价值的资讯燃料，不生成故事正文或完整大纲',
    target_platform: String((task || {}).target_platform || '番茄短篇'),
    selection_note: '候选已按事件聚类、跨源热度和个人叙事抓手排序。宏观通稿可以保留为背景，但不得仅凭热度判为 write。',
    source_items: selected,
    candidate_shape: {
      root_fields: ['info_source_cards'],
      info_source_cards: {
        count: '3-8，宁缺毋滥；不足 3 张时如实返回，不得凑数',
        required_fields: [
          'info_id', 'capture_refs', 'title', 'factual_summary', 'human_conflict',
          'material_score', 'verdict', 'main_route', 'backup_route', 'unsuitable_route',
          'discussion_value', 'story_value_signals', 'learning_notes',
        ],
        story_value_signals: ['immediate_stakes', 'protagonist_action', 'escalation_path', 'credible_payoff'],
        verdict_values: ['write', 'backup', 'discard'],
      },
    },
    scoring_rule: 'material_score 只衡量小说改编价值；write 必须同时有具体人物、眼前损失、外部行动、至少三级升级和可见后果。只有身份对立、宏观意义或平台标签时必须判为 discard。',
  };
}
function assessInfoSourcePool(cards) {
  const visible = (Array.isArray(cards) ? cards : []).filter(card => ['write', 'backup'].includes(String((card || {}).verdict || '')) && (card || {}).story_value_valid === true);
  const writeCount = visible.filter(card => String((card || {}).verdict || '') === 'write').length;
  const backupCount = visible.length - writeCount;
  return {
    status: writeCount >= 2 && visible.length >= 3 ? 'ready' : visible.length > 0 ? 'partial' : 'insufficient',
    visible_count: visible.length,
    write_count: writeCount,
    backup_count: backupCount,
    minimum: { visible_count: 3, write_count: 2 },
  };
}
function hasActionableStorySignals(signals) {
  if (!signals || typeof signals !== 'object') return false;
  const stakes = String(signals.immediate_stakes || '').trim();
  const action = String(signals.protagonist_action || '').trim();
  const escalation = String(signals.escalation_path || '').trim();
  const payoff = String(signals.credible_payoff || '').trim();
  const generic = /^(人物|主角)?(面临|遭遇)?(冲突|压力|选择|困难)|^(公开|揭露|查明)?真相$|^(完成|形成)?反转$|矛盾(逐渐)?升级|维持现状|改变现状|承担后果|适合(番茄|公众号|知乎)/u;
  if ([stakes, action, escalation, payoff].some(value => value.length < 8 || generic.test(value))) return false;
  if (!/(查|录|存|复制|拒|公开|举报|追|阻止|联合|提交|直播|拆穿|揭露|撤回|带走|追回|保护|辞职|起诉|报警|投票|夺回|关闭|承认|偿还|反击|调查)/u.test(action)) return false;
  if (escalation.length < 18 || !/(先|再|随后|继而|直到|最后|升级|逼|冻结|威胁|删|停|追责)/u.test(escalation)) return false;
  if (!/(退款|补发|停职|撤回|公开|处罚|召回|恢复|失去|保住|判决|整改|道歉|追责|离开|获救|解除|归还|赔偿)/u.test(payoff)) return false;
  return new Set([stakes, action, escalation, payoff].map(value => value.replace(/\s+/gu, ''))).size === 4;
}
function clusterCaptureItems(items) {
  const clusters = [];
  for (const item of items) {
    if (!item || typeof item !== 'object' || !String(item.title || '').trim()) continue;
    const match = clusters.find(cluster => titleSimilarity(cluster.leader.title, item.title) >= 0.34);
    if (match) match.items.push(item);
    else clusters.push({ leader: item, items: [item] });
  }
  return clusters.map(cluster => {
    const leader = cluster.items
      .slice()
      .sort((left, right) => storyAffordanceScore(right) - storyAffordanceScore(left))[0];
    return {
      leader,
      items: cluster.items,
      story_affordance_score: storyAffordanceScore(leader) + Math.min(6, (new Set(cluster.items.map(item => String(item.source_id || item.source_name || ''))).size - 1) * 3),
    };
  });
}
function storyAffordanceScore(item) {
  const title = String((item || {}).title || '');
  const positive = title.match(/员工|工资|老板|公司|同事|举报|侵吞|诈骗|被骗|理财|银行|退款|赔偿|家庭|父母|母亲|父亲|孩子|婚|恋|遗产|房产|学校|学生|老师|医院|医生|外卖|骑手|直播|网红|工厂|食品|消费|隐私|AI|人工智能|事故|预警|失效|网暴|推荐信|责任/gu) || [];
  const negative = title.match(/外交|战争|关税|产业高质量|高质量发展|进入新阶段|预拨|三农|市值|国资|上市|总统|总理|省份发展|宏观数据/gu) || [];
  const rank = Math.max(1, Number((item || {}).rank || (item || {}).heat_value || 10));
  return positive.length * 2 - negative.length * 5 + Math.max(0, 4 - rank) * 0.25;
}
function titleSimilarity(left, right) {
  const a = titleBigrams(left);
  const b = titleBigrams(right);
  if (!a.size || !b.size) return 0;
  let overlap = 0;
  for (const token of a) if (b.has(token)) overlap += 1;
  return overlap / (a.size + b.size - overlap);
}
function titleBigrams(value) {
  const text = String(value || '').replace(/[\s\p{P}\p{S}\d]+/gu, '');
  const generic = new Set(['热点', '热搜', '新闻', '视频', '曝光', '回应', '事件', '最新', '引热', '为何']);
  const out = new Set();
  for (let index = 0; index < text.length - 1; index += 1) {
    const token = text.slice(index, index + 2);
    if (!generic.has(token)) out.add(token);
  }
  return out;
}
function compactCaptureCluster(cluster) {
  const item = cluster.leader;
  const refs = cluster.items.map(row => String(row.capture_item_id || '')).filter(Boolean);
  const sources = [...new Set(cluster.items.map(row => String(row.source_name || row.source_id || '')).filter(Boolean))];
  return {
    ...compactCaptureItem(item),
    capture_refs: refs,
    corroboration_count: sources.length,
    source_names: sources,
    related_titles: [...new Set(cluster.items.map(row => String(row.title || '')).filter(Boolean))],
    story_affordance_score: cluster.story_affordance_score,
  };
}
function compactCaptureItem(item) {
  return {
    capture_item_id: String(item.capture_item_id || ''),
    source_id: String(item.source_id || ''),
    source_name: String(item.source_name || ''),
    title: String(item.title || '').slice(0, 180),
    summary: String(item.summary || item.description || '').slice(0, 320),
    url: String(item.url || ''),
    observed_at: String(item.observed_at || ''),
    published_at: String(item.published_at || ''),
    rank: Number(item.rank || 0),
    heat_signal: String(item.heat_signal || ''),
    heat_value: String(item.heat_value || ''),
  };
}
function hasCurrentCaptureMethod(methods) {
  const accepted = new Set(['structured_provider', 'external_hits_json', 'browser_cdp', 'web_search', 'site_search']);
  return Array.isArray(methods) && methods.some(method => accepted.has(String(method || '')));
}
function run(command, args, cwd) { return spawnSync(command, args, { cwd, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 }); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }
function isFile(file) { return fs.existsSync(file) && fs.statSync(file).isFile(); }
function safeProjectFile(root, relative) {
  const file = path.resolve(root, relative);
  if (!file.startsWith(`${root}${path.sep}`)) throw new Error(`unsafe project path: ${relative}`);
  return file;
}
function parseArgs(argv) {
  const out = { projectRoot: '.', workflowId: '', apply: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '.';
    else if (arg === '--workflow-id') out.workflowId = argv[++index] || '';
    else if (arg === '--apply') out.apply = true;
    else if (arg === '--json') out.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!out.workflowId) throw new Error('--workflow-id is required');
  return out;
}
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : String(value.status || '')}\n`); return code; }

if (require.main === module) process.exitCode = main();

module.exports = { buildInfoSourceEnrichmentContext, normalizeCandidatePayload, assessInfoSourcePool };
