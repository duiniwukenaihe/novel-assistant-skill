'use strict';

const fs = require('fs');
const path = require('path');
const { shortStateFile } = require('./short-project-state');
const { resolvePlannedSectionCount } = require('./short-workflow-state');

function plannedTargetChars(text) {
  return plannedTargetSpec(text).chars;
}

function plannedTargetSpec(text) {
  const normalized = String(text || '').replace(/[，,]/gu, '');
  const range = normalized.match(/(?:目标(?:字数|篇幅)?|本节目标|字数预算|篇幅预算|本节预算)\s*[:：=]?\s*([0-9]+)\s*(?:-|~|—|–|至|到)\s*([0-9]+)\s*(?:个)?(?:中文字|中文字符|中文|字)/u);
  if (range) {
    const left = Number(range[1]);
    const right = Number(range[2]);
    const min = Math.min(left, right);
    const max = Math.max(left, right);
    return { chars: Math.round((min + max) / 2), range: { min, max } };
  }
  const single = normalized.match(/(?:目标(?:字数|篇幅)?|本节目标|字数预算|篇幅预算|本节预算)\s*[:：=]?\s*([0-9]+)\s*(?:个)?(?:中文字|中文字符|中文|字)/u);
  return single ? { chars: Number(single[1]) } : { chars: 0 };
}

function plannedStoryTargetChars(text) {
  const normalized = String(text || '').replace(/[，,]/gu, '');
  const range = normalized.match(/(?:目标(?:总字数|长度)|总字数)\s*[:：=]?\s*([0-9]+)\s*(?:-|~|—|–|至|到)\s*([0-9]+)\s*字/u);
  if (range) return Math.round((Number(range[1]) + Number(range[2])) / 2);
  const single = normalized.match(/(?:目标(?:总字数|长度)|总字数)\s*[:：=]?\s*([0-9]+)\s*字/u);
  return single ? Number(single[1]) : 0;
}

function resolveSectionLengthTarget(root, projectState, sectionIndex) {
  const projectRoot = path.resolve(root || '');
  const briefRel = `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`;
  const briefTarget = plannedTargetSpec(readText(path.join(projectRoot, briefRel)));
  if (briefTarget.chars) return { ...briefTarget, source: 'explicit_section_target', enforcement: 'hard' };

  const outlineRel = '小节大纲.md';
  const outlineText = readText(path.join(projectRoot, outlineRel));
  const outlineTarget = plannedTargetSpec(sectionBlock(outlineText, sectionIndex));
  if (outlineTarget.chars) return { ...outlineTarget, source: 'outline_section_target', enforcement: 'hard' };

  const restored = acceptedOutlineTarget(projectRoot, outlineText, sectionIndex);
  if (restored.chars) return restored;

  const settingText = readText(path.join(projectRoot, '设定.md'));
  const totalTarget = plannedStoryTargetChars(`${settingText}\n${outlineText}`);
  const plan = resolvePlannedSectionCount({
    projectState: projectState || {},
    titleLock: readJson(shortStateFile(projectRoot, 'section-title-lock.json')) || {},
    outlineText,
  });
  if (totalTarget && plan.status === 'locked' && Number(plan.count || 0) > 0) {
    return {
      chars: Math.round(totalTarget / Number(plan.count)),
      source: 'project_average_target',
      enforcement: 'advisory',
    };
  }
  return { chars: 0, source: 'accepted_section_median', enforcement: 'advisory' };
}

function acceptedOutlineTarget(root, currentOutline, sectionIndex) {
  const commitsDir = path.join(root, '追踪/story-system/commits');
  let commits = [];
  try {
    commits = fs.readdirSync(commitsDir)
      .filter((name) => name.endsWith('.json'))
      .map((name) => readJson(path.join(commitsDir, name)))
      .filter((commit) => commit && String(commit.status || '') === 'accepted'
        && (Array.isArray(commit.artifacts) ? commit.artifacts : [])
          .some((artifact) => String((artifact || {}).target || '') === '小节大纲.md'))
      .sort((left, right) => String(right.accepted_at || '').localeCompare(String(left.accepted_at || '')));
  } catch (_) {
    return { chars: 0 };
  }
  for (const commit of commits) {
    const transactionId = String(commit.transaction_id || '');
    if (!transactionId || !/^[-A-Za-z0-9_.]+$/u.test(transactionId)) continue;
    const transaction = readJson(path.join(root, '追踪/story-system/transactions', transactionId, 'transaction.json'));
    if (!transaction || String(transaction.status || '') !== 'accepted') continue;
    const artifact = (Array.isArray(transaction.artifacts) ? transaction.artifacts : [])
      .find((item) => String((item || {}).target || '') === '小节大纲.md');
    const stagedRel = String((artifact || {}).staged || '');
    const stagedFile = safeRelativeFile(root, stagedRel);
    if (!stagedFile) continue;
    const historicalOutline = readText(stagedFile);
    if (!outlinesCompatible(currentOutline, historicalOutline, sectionIndex)) continue;
    const target = plannedTargetSpec(sectionBlock(historicalOutline, sectionIndex));
    if (target.chars) {
      return {
        ...target,
        source: 'accepted_outline_section_target',
        enforcement: 'hard',
        evidence_path: stagedRel,
      };
    }
  }
  return { chars: 0 };
}

function outlinesCompatible(current, historical, sectionIndex) {
  const currentSections = sectionHeadings(current);
  const historicalSections = sectionHeadings(historical);
  if (!currentSections.length || currentSections.length !== historicalSections.length) return false;
  const currentSection = currentSections.find((item) => item.section_index === Number(sectionIndex));
  const historicalSection = historicalSections.find((item) => item.section_index === Number(sectionIndex));
  return Boolean(currentSection && historicalSection && currentSection.title === historicalSection.title);
}

function sectionBlock(text, sectionIndex) {
  const matches = sectionHeadingMatches(text);
  const found = matches.findIndex((item) => item.section_index === Number(sectionIndex));
  if (found < 0) return '';
  return String(text || '').slice(matches[found].start, matches[found + 1] ? matches[found + 1].start : undefined);
}

function sectionHeadings(text) {
  return sectionHeadingMatches(text).map(({ section_index, title }) => ({ section_index, title }));
}

function sectionHeadingMatches(text) {
  return [...String(text || '').matchAll(/^#{1,6}\s+第\s*0*(\d+)\s*节(?:\s*[：:｜|]?\s*([^\n]*))?$/gmu)]
    .map((match) => ({
      section_index: Number(match[1]),
      title: normalizeTitle(match[2]),
      start: Number(match.index || 0),
    }));
}

function normalizeTitle(value) {
  return String(value || '')
    .trim()
    .replace(/[“”「」『』]/gu, '"')
    .replace(/\s+/gu, ' ');
}

function safeRelativeFile(root, rel) {
  if (!rel || path.isAbsolute(rel) || String(rel).split(/[\\/]+/u).includes('..')) return '';
  const file = path.resolve(root, rel);
  return file.startsWith(`${path.resolve(root)}${path.sep}`) ? file : '';
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

module.exports = {
  acceptedOutlineTarget,
  outlinesCompatible,
  plannedStoryTargetChars,
  plannedTargetChars,
  plannedTargetSpec,
  resolveSectionLengthTarget,
  sectionBlock,
};
