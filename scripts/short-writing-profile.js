#!/usr/bin/env node
'use strict';

const PLATFORM_PROFILES = {
  'fanqie-short': {
    id: 'fanqie-short',
    label: '番茄短篇',
    opening_pitch: '尽早建立人物困境、可感损失与继续阅读的问题。',
    reading_breakpoint: '每个小节都要改变关系、风险或认知，不能只重复情绪。',
    ending_contract: '完成核心承诺与情绪兑现，避免用解释性总结代替结局。',
  },
  'zhihu-yanxuan': {
    id: 'zhihu-yanxuan',
    label: '知乎盐选',
    opening_pitch: '用异常处境、信息落差或关系裂口建立叙述牵引。',
    reading_breakpoint: '持续提供新事实和因果翻转，避免只靠标题承诺。',
    ending_contract: '让真相、选择与人物代价同时闭合。',
  },
  'mini-program': {
    id: 'mini-program',
    label: '小程序短篇',
    opening_pitch: '快速明确冲突对象、主角目标和近期代价。',
    reading_breakpoint: '在关键关系或信息变化处形成自然停顿。',
    ending_contract: '兑现主卖点，并留下与题材一致的余味。',
  },
};

const PLATFORM_ALIASES = new Map([
  ['番茄', 'fanqie-short'],
  ['番茄短篇', 'fanqie-short'],
  ['盐言', 'zhihu-yanxuan'],
  ['知乎', 'zhihu-yanxuan'],
  ['知乎盐选', 'zhihu-yanxuan'],
  ['小程序', 'mini-program'],
  ['小程序短篇', 'mini-program'],
]);

const GENRE_ALIASES = new Map([
  ['复仇', '复仇打脸.md'],
  ['复仇打脸', '复仇打脸.md'],
  ['宅斗', '宅斗宫斗.md'],
  ['宫斗', '宅斗宫斗.md'],
  ['宅斗宫斗', '宅斗宫斗.md'],
  ['总裁', '总裁豪门.md'],
  ['豪门', '总裁豪门.md'],
  ['总裁豪门', '总裁豪门.md'],
  ['追妻', '追妻火葬场.md'],
  ['追妻火葬场', '追妻火葬场.md'],
  ['世情', '世情打脸.md'],
  ['世情打脸', '世情打脸.md'],
  ['民俗', '民俗怪谈.md'],
  ['怪谈', '民俗怪谈.md'],
  ['民俗怪谈', '民俗怪谈.md'],
  ['悬疑', '悬疑.md'],
  ['悬疑反转', '悬疑.md'],
  ['甜宠', '甜宠.md'],
  ['双男主', '双男主.md'],
  ['沙雕', '沙雕脑洞.md'],
  ['脑洞', '沙雕脑洞.md'],
  ['沙雕脑洞', '沙雕脑洞.md'],
]);

function normalize(value) {
  return String(value || '').trim().replace(/[\s·/]+/g, '');
}

function lookupAlias(aliases, input) {
  const normalized = normalize(input);
  if (aliases.has(normalized)) return aliases.get(normalized);
  for (const [alias, value] of aliases.entries()) {
    if (normalized.includes(alias)) return value;
  }
  return null;
}

function selectProfile({ platform, genre }) {
  const platformId = lookupAlias(PLATFORM_ALIASES, platform);
  const genreFile = lookupAlias(GENRE_ALIASES, genre);
  const verified = Boolean(platformId && genreFile);

  return {
    status: verified ? 'ok' : 'fallback',
    platform_profile: platformId
      ? { ...PLATFORM_PROFILES[platformId] }
      : {
          id: 'generic',
          label: platform || '未指定平台',
          opening_pitch: '先确认目标读者、开篇承诺与冲突入口。',
          reading_breakpoint: '按信息变化和因果推进设置自然停顿。',
          ending_contract: '兑现已确认的故事承诺与人物选择。',
        },
    genre_card: genreFile
      ? `references/genre-styles/${genreFile}`
      : 'references/genre-writing-formulas.md',
    evidence: {
      source: 'references/submission-profile.md',
      platform_input: platform,
      genre_input: genre,
    },
    confidence: verified ? 'reviewed' : 'unverified',
  };
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (item === '--platform') options.platform = argv[++index];
    else if (item === '--genre') options.genre = argv[++index];
    else if (item === '--json') options.json = true;
    else throw new Error(`Unknown argument: ${item}`);
  }
  if (!options.platform || !options.genre) {
    throw new Error('Usage: short-writing-profile.js --platform <name> --genre <name> [--json]');
  }
  return options;
}

function main() {
  try {
    const options = parseArgs(process.argv.slice(2));
    const result = selectProfile(options);
    process.stdout.write(`${JSON.stringify(result, null, options.json ? 2 : 0)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 2;
  }
}

if (require.main === module) main();

module.exports = { selectProfile };
