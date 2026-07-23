#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { checkShortPlanContract } = require('./lib/short-plan-contract');

function parseArgs(argv) {
  const args = { projectRoot: '', json: false, compact: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--json') args.json = true;
    else if (arg === '--compact') args.compact = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.projectRoot) {
    throw new Error('Usage: node scripts/short-review-entry.js --project-root <dir> [--json]');
  }
  return args;
}

function compactFindings(findings) {
  const groups = new Map();
  for (const finding of Array.isArray(findings) ? findings : []) {
    const code = String(finding.code || 'unknown');
    if (!groups.has(code)) groups.set(code, { code, sections: [], missing_signals: [], section_findings: [] });
    const group = groups.get(code);
    const section = Number(finding.section || 0);
    if (section > 0 && !group.sections.includes(section)) group.sections.push(section);
    for (const signal of Array.isArray(finding.missing_signals) ? finding.missing_signals : []) {
      if (!group.missing_signals.includes(signal)) group.missing_signals.push(signal);
    }
    const message = String(finding.message || '');
    if (section > 0) {
      group.section_findings.push({
        section,
        role: String(finding.role || ''),
        missing_signals: Array.isArray(finding.missing_signals) ? finding.missing_signals : [],
        message,
      });
    } else if (message && !group.message) {
      group.message = message;
    }
    for (const key of ['legacy_format', 'planned_sections', 'detected_sections']) {
      if (finding[key] !== undefined && group[key] === undefined) group[key] = finding[key];
    }
  }
  return [...groups.values()].map((group) => {
    if (!group.sections.length) delete group.sections;
    if (!group.missing_signals.length) delete group.missing_signals;
    if (!group.section_findings.length) delete group.section_findings;
    return group;
  });
}

const SIGNAL_LABELS = Object.freeze({
  structure: '结构功能', emotion: '情绪变化', causality: '因果推进', handoff: '节尾承接',
  scene_action: '可见场景行动', protagonist_choice: '主角选择', opening_hook: '开场钩子',
  story_promise: '故事承诺', handoff_in: '承接上节', pressure_shift: '压力变化',
  visible_opposition: '可见阻力', section_payoff: '本节兑现', relationship_change: '关系变化',
  cost_escalation: '代价升级', core_payoff: '核心承诺兑现', decisive_action: '决定性行动',
  immediate_cost: '即时代价', consequences: '现实后果', relationship_closure: '关系收束',
  theme_callback: '主题回扣', causal_events: '至少两个因果事件', live_scene_collision: '人物现场碰撞',
});

function buildPlanRepairChecklist(plan) {
  const bySection = new Map();
  const global = [];
  for (const finding of Array.isArray((plan || {}).findings) ? plan.findings : []) {
    const section = Number(finding.section || 0);
    if (!section) {
      global.push({ code: String(finding.code || 'unknown'), message: String(finding.message || '') });
      continue;
    }
    if (!bySection.has(section)) bySection.set(section, { section, unresolved_signals: new Set(), findings: [] });
    const item = bySection.get(section);
    for (const signal of Array.isArray(finding.missing_signals) ? finding.missing_signals : []) item.unresolved_signals.add(signal);
    item.findings.push({ code: String(finding.code || 'unknown'), message: String(finding.message || '') });
  }
  return {
    blocking_for_drafting: (plan || {}).status !== 'current',
    blocking_for_read_only_review: false,
    instruction: '优先把现有主事件、子事件、情绪、因果链、角色选择和钩子映射到合同；只有无法从现有内容确定时才补剧情，不要机械改字段名。',
    global_findings: global,
    sections: [...bySection.values()].sort((left, right) => left.section - right.section).map((item) => ({
      section: item.section,
      unresolved_signals: [...item.unresolved_signals],
      unresolved_labels: [...item.unresolved_signals].map((signal) => SIGNAL_LABELS[signal] || signal),
      findings: item.findings,
    })),
  };
}

function reviewableProse(projectRoot) {
  const root = path.resolve(projectRoot);
  const assembled = path.join(root, '正文.md');
  if (fs.existsSync(assembled) && fs.statSync(assembled).isFile() && fs.readFileSync(assembled, 'utf8').trim()) return true;
  const proseDir = path.join(root, '正文');
  if (!fs.existsSync(proseDir) || !fs.statSync(proseDir).isDirectory()) return false;
  return fs.readdirSync(proseDir, { withFileTypes: true }).some((entry) => entry.isFile() && /\.md$/iu.test(entry.name));
}

function compactResult(result) {
  const plan = result.plan_contract || {};
  return {
    schemaVersion: result.schemaVersion,
    status: result.status,
    route_receipt: result.route_receipt,
    review_scope: result.review_scope,
    plan_contract: {
      schema_version: plan.schema_version,
      status: plan.status,
      plan_format: plan.plan_format || 'current',
      migration_required: Boolean(plan.migration_required),
      planned_sections: plan.planned_sections,
      outlined_sections: plan.outlined_sections,
      findings: compactFindings(plan.findings),
    },
    plan_repair_checklist: result.plan_repair_checklist,
    review_limitations: result.review_limitations,
    next_action: result.next_action,
    full_prose_scan_allowed: result.full_prose_scan_allowed,
    user_visible_summary: result.user_visible_summary,
  };
}

function privateContextAvailable(projectRoot) {
  const sentinel = path.join(path.resolve(projectRoot || process.cwd()), '.story-deployed');
  if (fs.existsSync(sentinel)) {
    const text = fs.readFileSync(sentinel, 'utf8');
    const marker = text.match(/^novel_assistant_private_overlay:\s*(true|false)\s*$/m);
    if (marker) return marker[1] === 'true';
  }
  const roots = [
    path.resolve(__dirname, '..', 'src', 'private-internal-skills', 'private-short-extension'),
    path.resolve(__dirname, '..', 'references', 'private-internal-skills', 'private-short-extension'),
  ];
  return roots.some((root) => fs.existsSync(path.join(root, 'workflow-registry.json')));
}

function buildResult(projectRoot) {
  const root = path.resolve(projectRoot);
  const plan = checkShortPlanContract(root);
  const planRisk = plan.status !== 'current';
  const proseAvailable = reviewableProse(root);
  return {
    schemaVersion: '1.0.0',
    status: !proseAvailable
      ? 'blocked_review_source_missing'
      : planRisk ? 'ready_for_professional_review_with_plan_risk' : 'ready_for_professional_review',
    route_receipt: {
      entry_skill: 'novel-assistant',
      workflow_type: 'short_review',
      owner_module: 'story-review',
      writing_context: privateContextAvailable(root) ? 'private_enhanced' : 'public',
    },
    review_scope: {
      kind: 'book',
      visible_label: '当前完整短篇',
      planned_sections: Number(plan.planned_sections || 0),
      outlined_sections: Array.isArray(plan.outlined_sections) ? plan.outlined_sections : [],
    },
    plan_contract: plan,
    plan_repair_checklist: buildPlanRepairChecklist(plan),
    review_limitations: planRisk
      ? ['允许审阅正文的逻辑、人物、情绪、钩子和文字质量；规划兑现结论标记为暂定，直到规划合同补齐。']
      : [],
    next_action: proseAvailable ? 'build_compact_review_plan' : 'locate_reviewable_prose',
    full_prose_scan_allowed: proseAvailable,
    user_visible_summary: !proseAvailable
      ? '未找到可审阅的正式正文；先定位或导入正文。'
      : planRisk
      ? '规划合同存在格式或内容风险；只读审阅继续进行，同时按小节输出规划补全清单。'
      : '小节大纲合同通过；进入专业短篇验收。',
  };
}

try {
  const args = parseArgs(process.argv);
  const result = buildResult(args.projectRoot);
  const output = args.compact ? compactResult(result) : result;
  process.stdout.write(`${JSON.stringify(output, null, args.json ? 2 : 0)}\n`);
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}

module.exports = { buildResult, compactResult, compactFindings, buildPlanRepairChecklist, privateContextAvailable, reviewableProse };
