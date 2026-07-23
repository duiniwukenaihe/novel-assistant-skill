#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const {
  readText,
  readJson,
  readDirSafe,
  nowIso,
} = require('./lib/oh-story-artifacts');

if (require.main === module) main();

function main() {
  const args = process.argv.slice(2);
  const projectRoot = args.find(arg => !arg.startsWith('--'));
  if (!projectRoot || args.includes('-h') || args.includes('--help')) {
    console.log('Usage: node story-domain-profile.js <book-project-dir> [--json]');
    process.exit(projectRoot ? 0 : 1);
  }

  const root = path.resolve(projectRoot);
  const profile = buildDomainProfile(root);

  if (args.includes('--json')) {
    process.stdout.write(`${JSON.stringify(profile, null, 2)}\n`);
  } else {
    console.log(`${profile.primaryDomain}: ${profile.growthAxisLabel}`);
  }
}

function buildDomainProfile(projectDir) {
  const corpus = collectCorpus(projectDir);
  const scores = scoreCorpus(corpus.text);
  const primaryDomain = choosePrimaryDomain(scores);
  const labels = labelsFor(primaryDomain);

  return {
    schemaVersion: '0.1.0',
    generatedAt: nowIso(),
    primaryDomain,
    confidence: confidenceFor(primaryDomain, scores),
    growthAxisLabel: labels.growthAxisLabel,
    settingFileName: labels.settingFileName,
    settingPath: slash(path.join('设定', '世界观', labels.settingFileName)),
    matrixLabel: labels.matrixLabel,
    defaultReviewDimensions: [
      '剧情连贯性',
      '人物状态持续发展',
      labels.growthAxisLabel,
      '钩子/伏笔铺设与回收',
      '世界规则一致性',
      'AI味与表达自然度',
    ],
    bannedDefaultLabels: labels.bannedDefaultLabels,
    evidence: {
      files: corpus.files,
      scores,
      matchedKeywords: matchedKeywords(corpus.text),
    },
  };
}

function collectCorpus(projectDir) {
  const state = readJson(path.join(projectDir, '.book-state.json'), {}) || {};
  const chunks = [];
  const files = [];

  addChunk(chunks, 'book-state', [
    state.bookTitle,
    state.title,
    state.targetGenre,
    state.genre,
    state.bookType,
    state.targetPlatform,
  ].filter(Boolean).join('\n'));

  for (const relDir of ['设定', '大纲']) {
    for (const file of collectTextFiles(path.join(projectDir, relDir), relDir, 16)) {
      files.push(file.relPath);
      addChunk(chunks, file.relPath, readText(file.absPath, '').slice(0, 6000));
    }
  }

  for (const file of collectTrustedTrackingFiles(projectDir)) {
    files.push(file.relPath);
    addChunk(chunks, file.relPath, readText(file.absPath, '').slice(0, 3000));
  }

  for (const file of collectTextFiles(path.join(projectDir, '正文'), '正文', 8)) {
    files.push(file.relPath);
    addChunk(chunks, file.relPath, readText(file.absPath, '').slice(0, 2500));
  }

  return {
    text: chunks.map(chunk => chunk.text).join('\n'),
    files: Array.from(new Set(files)).slice(0, 40),
  };
}

function addChunk(chunks, source, text) {
  const clean = String(text || '').trim();
  if (clean) chunks.push({ source, text: clean });
}

function collectTextFiles(absDir, relDir, limit) {
  const files = [];
  walk(absDir, relDir, files, limit);
  return files;
}

function collectTrustedTrackingFiles(projectDir) {
  const names = [
    '上下文.md',
    '伏笔.md',
    '主线承诺.md',
    '时间线.md',
    '人物状态.md',
  ];
  const files = [];
  for (const name of names) {
    const absPath = path.join(projectDir, '追踪', name);
    try {
      const stat = fs.statSync(absPath);
      if (stat.isFile()) files.push({ absPath, relPath: slash(path.join('追踪', name)) });
    } catch {
      // optional tracking fact file
    }
  }
  return files;
}

function walk(absDir, relDir, files, limit) {
  if (files.length >= limit) return;
  for (const name of readDirSafe(absDir)) {
    if (files.length >= limit) return;
    const absPath = path.join(absDir, name);
    const relPath = slash(path.join(relDir, name));
    let stat;
    try {
      stat = fs.statSync(absPath);
    } catch {
      continue;
    }
    if (stat.isDirectory()) walk(absPath, relPath, files, limit);
    else if (stat.isFile() && /\.(md|txt|json|jsonl)$/i.test(name)) files.push({ absPath, relPath });
  }
}

function scoreCorpus(text) {
  const normalized = String(text || '');
  const groups = keywordGroups();
  const scores = {};
  for (const [group, keywords] of Object.entries(groups)) {
    scores[group] = keywords.reduce((sum, keyword) => sum + countKeyword(normalized, keyword), 0);
  }
  return scores;
}

function keywordGroups() {
  return {
    xiuzhen: ['修真', '修仙', '仙侠', '炼气', '筑基', '金丹', '元婴', '化神', '灵气', '修真界', '仙界', '飞升'],
    martial: ['武侠', '魔教', '江湖', '心法', '内功', '内力', '武学', '门派', '掌门', '内门', '外门', '圣女'],
    foodBusiness: ['美食', '蛋炒饭', '后厨', '厨艺', '中央厨房', '经营', '商战', '配方', '菜谱', '红袖坊'],
    system: ['系统', '面板', '属性', '技能', '熟练度', '加点', '任务奖励'],
    fantasy: ['玄幻', '血脉', '灵兽', '御兽', '斗气', '魔法', '神通'],
  };
}

function choosePrimaryDomain(scores) {
  if (scores.xiuzhen >= 3 && scores.xiuzhen >= scores.martial + scores.foodBusiness) return 'xiuzhen_xianxia';
  if (scores.martial >= 2 && scores.foodBusiness >= 2) return 'martial_food_business';
  if (scores.system >= 2 && scores.foodBusiness >= 2) return 'system_food_business';
  if (scores.system >= 2) return 'system_growth';
  if (scores.martial >= 2) return 'martial_wuxia';
  if (scores.fantasy >= 2) return 'fantasy_growth';
  return 'general_story';
}

function labelsFor(primaryDomain) {
  const sharedBan = ['xiuzhen_progress_label', 'xiuzhen_matrix_label', 'xiuzhen_system_label', 'power_system_filename'];
  const map = {
    xiuzhen_xianxia: {
      growthAxisLabel: '修真进度一致性',
      settingFileName: '修真境界与规则.md',
      matrixLabel: '修真进度矩阵',
      bannedDefaultLabels: ['力量体系.md'],
    },
    martial_food_business: {
      growthAxisLabel: '修炼/武学与经营规则一致性',
      settingFileName: '修炼与能力规则.md',
      matrixLabel: '修炼/经营规则矩阵',
      bannedDefaultLabels: sharedBan,
    },
    system_food_business: {
      growthAxisLabel: '系统能力与经营成长一致性',
      settingFileName: '系统能力与成长规则.md',
      matrixLabel: '系统/经营成长矩阵',
      bannedDefaultLabels: sharedBan,
    },
    system_growth: {
      growthAxisLabel: '系统能力与成长规则一致性',
      settingFileName: '系统能力与成长规则.md',
      matrixLabel: '系统成长矩阵',
      bannedDefaultLabels: sharedBan,
    },
    martial_wuxia: {
      growthAxisLabel: '武学与境界一致性',
      settingFileName: '武学与境界.md',
      matrixLabel: '武学境界矩阵',
      bannedDefaultLabels: sharedBan,
    },
    fantasy_growth: {
      growthAxisLabel: '能力/成长规则一致性',
      settingFileName: '能力与规则.md',
      matrixLabel: '能力成长矩阵',
      bannedDefaultLabels: sharedBan,
    },
    general_story: {
      growthAxisLabel: '能力/成长规则一致性',
      settingFileName: '能力与规则.md',
      matrixLabel: '能力/成长规则矩阵',
      bannedDefaultLabels: sharedBan,
    },
  };
  return map[primaryDomain] || map.general_story;
}

function confidenceFor(primaryDomain, scores) {
  if (primaryDomain === 'general_story') return 'low';
  const total = Object.values(scores).reduce((sum, value) => sum + value, 0);
  if (total >= 10) return 'high';
  if (total >= 4) return 'medium';
  return 'low';
}

function matchedKeywords(text) {
  const matched = {};
  for (const [group, keywords] of Object.entries(keywordGroups())) {
    matched[group] = keywords.filter(keyword => countKeyword(text, keyword) > 0);
  }
  return matched;
}

function countKeyword(text, keyword) {
  const escaped = String(keyword).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return (String(text || '').match(new RegExp(escaped, 'g')) || []).length;
}

function slash(value) {
  return String(value || '').replace(/\\/g, '/');
}

module.exports = { buildDomainProfile };
