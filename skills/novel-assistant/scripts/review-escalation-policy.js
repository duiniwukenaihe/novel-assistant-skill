#!/usr/bin/env node
'use strict';

const SCHEMA_VERSION = '1.0.0';

function parseArgs(argv) {
  const args = {
    json: false,
    chapter: 0,
    batchSize: 5,
    chapterType: 'normal',
    machineGate: 'pass',
    storyValue: 'pass',
    userFeedback: '',
    crossVolume: false,
    expansion: false,
    release: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const readValue = () => {
      if (i + 1 >= argv.length) return '';
      i += 1;
      return argv[i];
    };

    if (arg === '--json') args.json = true;
    else if (arg === '--chapter') args.chapter = Number(readValue()) || 0;
    else if (arg === '--batch-size') args.batchSize = Number(readValue()) || 5;
    else if (arg === '--chapter-type') args.chapterType = String(readValue() || 'normal');
    else if (arg === '--machine-gate') args.machineGate = String(readValue() || 'pass');
    else if (arg === '--story-value') args.storyValue = String(readValue() || 'pass');
    else if (arg === '--user-feedback') args.userFeedback = String(readValue() || '');
    else if (arg === '--scope') args.scope = String(readValue() || '');
    else if (arg === '--cross-volume') args.crossVolume = true;
    else if (arg === '--expansion') args.expansion = true;
    else if (arg === '--release') args.release = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
  }

  return args;
}

function normalize(value) {
  return String(value || '').trim().toLowerCase().replace(/-/g, '_');
}

function includesNegativeFeedback(text) {
  return /(不好看|不吸引|人物不像人|人物生硬|剧情不合理|逻辑不通|动机不成立|没爽点|没有爽点|没爆点|没有爆点|跑题|太平|无聊|没看点|没共鸣|不真实|没代入)/.test(text || '');
}

function result({ escalation, reasonCodes, roles, costClass, nextAction }) {
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'ok',
    review_escalation_result: escalation,
    escalation,
    reason_codes: reasonCodes,
    roles,
    cost_class: costClass,
    next_action: nextAction,
  };
}

function decide(args) {
  const machineGate = normalize(args.machineGate);
  const storyValue = normalize(args.storyValue);
  const chapterType = normalize(args.chapterType || 'normal');
  const chapter = Number(args.chapter || 0);
  const batchSize = Math.max(1, Number(args.batchSize || 5));

  if (['blocking', 'blocked', 'failed', 'fail', 'error'].includes(machineGate)) {
    return result({
      escalation: 'none',
      reasonCodes: ['machine_blocking_repair_first'],
      roles: [],
      costClass: 'low',
      nextAction: 'repair_current_unit',
    });
  }

  const reasonCodes = [];
  const keyChapterTypes = new Set([
    'key',
    'climax',
    'reversal',
    'volume_start',
    'volume_end',
    'relationship_shift',
    'payoff',
    'major_reveal',
  ]);

  if (['revise', 'blocking', 'blocked', 'failed', 'fail'].includes(storyValue)) {
    reasonCodes.push('story_value_gate_not_passed');
  }
  if (keyChapterTypes.has(chapterType)) reasonCodes.push(`key_chapter_type_${chapterType}`);
  if (args.crossVolume) reasonCodes.push('cross_volume_handoff');
  if (args.expansion) reasonCodes.push('expansion_or_insert_chapter');
  if (args.release) reasonCodes.push('release_gate');
  if (includesNegativeFeedback(args.userFeedback)) reasonCodes.push('user_quality_complaint');

  if (reasonCodes.length > 0) {
    return result({
      escalation: 'full_multi_role',
      reasonCodes,
      roles: ['reader_value', 'continuity', 'character_motivation', 'commercial_hook'],
      costClass: 'high',
      nextAction: 'run_full_review',
    });
  }

  if (chapter > 0 && chapter % batchSize === 0) {
    return result({
      escalation: 'light_dual_role',
      reasonCodes: [`periodic_every_${batchSize}_units`],
      roles: ['reader_value', 'continuity'],
      costClass: 'medium',
      nextAction: 'run_light_review',
    });
  }

  return result({
    escalation: 'none',
    reasonCodes: ['normal_unit_passed'],
    roles: [],
    costClass: 'low',
    nextAction: 'continue_handoff',
  });
}

function printHelp() {
  console.log(`review-escalation-policy ${SCHEMA_VERSION}

Usage:
  node scripts/review-escalation-policy.js --json --chapter 5 --machine-gate pass --story-value pass

Common flags:
  --chapter <n>
  --batch-size <n>
  --chapter-type normal|climax|reversal|volume_start|volume_end|relationship_shift
  --machine-gate pass|blocking|failed
  --story-value pass|revise|blocked
  --user-feedback <text>
  --cross-volume
  --expansion
  --release
`);
}

function printText(policy) {
  console.log(`审阅升级策略：${policy.escalation}`);
  console.log(`下一步：${policy.next_action}`);
  console.log(`成本等级：${policy.cost_class}`);
  console.log(`原因：${policy.reason_codes.join(', ')}`);
  if (policy.roles.length > 0) console.log(`角色：${policy.roles.join(', ')}`);
}

if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    process.exit(0);
  }
  const policy = decide(args);
  if (args.json) console.log(JSON.stringify(policy, null, 2));
  else printText(policy);
}

module.exports = { decide, parseArgs, includesNegativeFeedback };
