#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { buildHotSourceSelection } = require('./lib/hot-source-registry');
const { resolvePrivateModule } = require('./lib/private-runtime-resolver');
const { readJson } = require('./lib/cli-utils');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const profilesFile = resolveProfilesFile(args.profiles);
  if (!profilesFile) return finish({ status: 'hot_source_profiles_missing' }, 1, args.json);
  const config = readJson(profilesFile);
  if (!config || !Array.isArray(config.source_profiles)) {
    return finish({ status: 'hot_source_profiles_invalid', profiles: profilesFile }, 1, args.json);
  }
  const asOf = parseDate(args.asOf) || new Date();
  const windowDays = Number.isInteger(args.windowDays) && args.windowDays > 0 ? args.windowDays : 1;
  const start = new Date(asOf.getTime());
  start.setUTCDate(start.getUTCDate() - windowDays);
  const selection = buildHotSourceSelection(config);
  const batches = selection.selectedIds.map(id => buildBatch(selection.byId.get(id), asOf, selection));
  const reserveSources = selection.reserveIds.map(id => buildBatch(selection.byId.get(id), asOf, selection));
  const report = {
    schemaVersion: '1.0.0',
    status: selection.coreIds.length > 0 && batches.length >= selection.coreIds.length
      ? 'hot_source_discovery_plan_ready'
      : 'hot_source_discovery_plan_partial',
    discovery_mode: 'source_first_no_genre_filter',
    window: { days: windowDays, start_date: isoDate(start), end_date: isoDate(asOf) },
    source_batches: batches,
    reserve_sources: reserveSources,
    coverage_contract: {
      configured_source_ids: selection.configuredIds,
      core_source_ids: selection.coreIds,
      selected_source_ids: selection.selectedIds,
      reserve_source_ids: selection.reserveIds,
      selected_expansion_groups: selection.selectedGroups,
      attempted_source_ids_required: selection.selectedIds,
      minimum_successful_sources: selection.minimumSuccessfulSources,
      expansion_policy: '固定调用预算内按来源组补齐受众与事件覆盖；候补源仅在已选来源不可用时接替',
      unselected_sources_require_status: false,
      fallback_per_source: 1,
      maximum_selected_sources: selection.maximumSourcesPerRound,
      maximum_total_tool_calls: batches.length * 2,
    },
    query_contract: {
      source_specific_only: true,
      topic_seed_policy: 'forbidden',
      discover_before_fictionalize: true,
    },
    capture_contract: {
      discovery_evidence_fields: ['performed', 'methods', 'queried_at', 'source_attempts', 'queries'],
      source_attempt_fields: ['source_id', 'status', 'entry_url', 'query', 'observed_at', 'result_count', 'skip_reason'],
      card_output: 'info_source_cards',
      rule: '先记录真实榜面与讨论，再评估小说化价值；不得用题材词替代热点发现。',
    },
  };
  return finish(report, report.status === 'hot_source_discovery_plan_ready' ? 0 : 1, args.json);
}

function buildBatch(profile, asOf, selection) {
  const domains = Array.isArray(profile.domains) ? profile.domains.filter(Boolean) : [];
  const entryUrls = Array.isArray(profile.entry_urls) ? profile.entry_urls.filter(Boolean) : [];
  const domain = domains[0] || '';
  const display = String(profile.display_name || profile.source_id || '热点来源');
  const date = isoDate(asOf);
  const query = domain
    ? `site:${domain} ${display} 热榜 ${date}`
    : `${display} 热榜 ${date}`;
  return {
    source_id: String(profile.source_id || ''),
    source_tier: selection.coreIds.includes(String(profile.source_id || '')) ? 'core' : 'expansion',
    display_name: display,
    entry_urls: entryUrls,
    domains,
    preferred_access: (Array.isArray(profile.access_modes) ? profile.access_modes : [])
      .filter(mode => ['static_html', 'rendered_page', 'site_search', 'web_search'].includes(String(mode))),
    primary_action: entryUrls.length ? 'open_public_entry' : 'source_specific_search',
    fallback_query: query,
    forbidden_behavior: '不得加入题材、人物关系或网文套路词缩窄搜索。',
  };
}

function resolveProfilesFile(explicit) {
  const privateRoot = resolvePrivateModule('private-short-extension', [
    path.join('references', 'hot-source-profiles.json'),
  ]);
  const candidates = [
    explicit,
    privateRoot ? path.join(privateRoot, 'references', 'hot-source-profiles.json') : '',
    path.join(__dirname, '..', 'references', 'private-internal-skills', 'private-short-extension', 'references', 'hot-source-profiles.json'),
    path.join(__dirname, '..', 'src', 'private-internal-skills', 'private-short-extension', 'references', 'hot-source-profiles.json'),
  ].filter(Boolean).map(item => path.resolve(item));
  return candidates.find(file => fs.existsSync(file) && fs.statSync(file).isFile()) || '';
}

function parseDate(value) {
  const text = String(value || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return null;
  const date = new Date(`${text}T00:00:00.000Z`);
  return Number.isNaN(date.getTime()) ? null : date;
}

function isoDate(value) { return value.toISOString().slice(0, 10); }

function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function parseArgs(argv) {
  const out = { profiles: '', windowDays: 1, asOf: '', json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--profiles') out.profiles = argv[++index] || '';
    else if (arg === '--window-days') out.windowDays = Number(argv[++index] || 0);
    else if (arg === '--as-of') out.asOf = argv[++index] || '';
    else if (arg === '--json') out.json = true;
    else usage(`unknown argument: ${arg}`);
  }
  return out;
}
function usage(message) {
  process.stderr.write(`${message}\nUsage: node hot-source-discovery-plan.js [--profiles FILE] [--window-days N] [--as-of YYYY-MM-DD] [--json]\n`);
  process.exit(2);
}

process.exitCode = main();
