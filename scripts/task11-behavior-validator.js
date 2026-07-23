#!/usr/bin/env node
'use strict';

const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');

const MAX_CHAPTERS_PER_RUN = 3;
const REQUIRED_BRIEF_FIELDS = ['goal', 'pressure', 'irreversibleChange', 'handoff'];
const WRITER_CARD_FIELDS = [
  'scenePressure',
  'readerPromise',
  'visibleActions',
  'languageBoundary',
  'avoid',
];
const MECHANICAL_EDIT_KINDS = new Set([
  'line_break',
  'punctuation_swap',
  'function_word_swap',
  'chapter_reorder',
]);

function evaluateLongWrite(request = {}) {
  const emptyDecision = {
    scheduledChapters: [],
    deferredChapters: [],
    proseCandidates: [],
    writerPackets: [],
  };

  const chapters = Array.isArray(request.chapters) ? request.chapters : [];
  if (request.invocation !== 'explicit' || !hasText(request.bookId) || chapters.length === 0) {
    return {
      decision: 'dock_preconditions',
      blockingReason: 'explicit_book_and_chapter_required',
      ...emptyDecision,
    };
  }

  if (!request.outline || request.outline.status !== 'passed') {
    return {
      decision: 'blocked',
      blockingReason: 'outline_underfilled',
      ...emptyDecision,
    };
  }

  const briefs = indexByChapter(request.chapterBriefs);
  const contracts = indexByChapter(request.chapterContracts);
  for (const chapter of chapters) {
    const brief = briefs.get(chapter);
    if (!isPassedBrief(brief)) {
      return {
        decision: 'blocked',
        blockingReason: 'outline_underfilled',
        missingChapter: chapter,
        ...emptyDecision,
      };
    }
  }

  const scheduledChapters = chapters.slice(0, MAX_CHAPTERS_PER_RUN);
  const deferredChapters = chapters.slice(MAX_CHAPTERS_PER_RUN);
  const writerPackets = [];

  for (const chapter of scheduledChapters) {
    const chapterContract = contracts.get(chapter);
    if (!chapterContract || chapterContract.status !== 'passed') {
      return {
        decision: 'blocked',
        blockingReason: 'chapter_contract_required',
        missingChapter: chapter,
        ...emptyDecision,
      };
    }

    const selectedCard = selectGenreCard(request.genreCards, request.primaryGenre);
    if (!selectedCard) {
      return {
        decision: 'blocked',
        blockingReason: 'genre_prose_card_required',
        missingChapter: chapter,
        ...emptyDecision,
      };
    }

    writerPackets.push({
      chapter,
      assemblyOrder: ['chapter_contract', 'genre_prose_card'],
      chapterContract: cloneJson(chapterContract),
      genreProseCards: [trimCardToContract(selectedCard, chapterContract)],
    });
  }

  return {
    decision: 'execute',
    blockingReason: null,
    scheduledChapters,
    deferredChapters,
    proseCandidates: scheduledChapters.map(chapter => ({ chapter, status: 'eligible' })),
    writerPackets,
  };
}

function evaluateDeslop(request = {}) {
  const facts = cloneJson(Array.isArray(request.facts) ? request.facts : []);
  const structure = cloneJson(Array.isArray(request.structure) ? request.structure : []);
  const findings = Array.isArray(request.findings) ? request.findings : [];
  const blocking = findings.some(item => item && item.severity === 'blocking');
  const proposedEdits = Array.isArray(request.proposedEdits) ? request.proposedEdits : [];
  const rejectedActions = proposedEdits
    .filter(item => item && MECHANICAL_EDIT_KINDS.has(item.kind))
    .map(item => ({ ...cloneJson(item), reason: 'mechanical_detector_pandering_rejected' }));
  const rejectedReasons = [];

  if (request.antiPandering && request.proposedOutput) {
    if (!sameJson(request.proposedOutput.facts, facts)) rejectedReasons.push('fact_change_rejected');
    if (!sameJson(request.proposedOutput.structure, structure)) rejectedReasons.push('structure_change_rejected');
  }

  return {
    decision: blocking ? 'blocked' : 'advisory_review',
    blocking,
    automaticRewriteActions: blocking ? proposedEdits.filter(item => item && !MECHANICAL_EDIT_KINDS.has(item.kind)) : [],
    rejectedActions,
    rejectedReasons,
    facts,
    structure,
  };
}

function evaluateCase(item) {
  if (!item || !hasText(item.id)) throw new Error('fixture case requires id');
  if (item.type === 'long_write') return evaluateLongWrite(item.request);
  if (item.type === 'deslop') return evaluateDeslop(item.request);
  throw new Error(`unsupported fixture case type: ${item.type}`);
}

function evaluateFixture(fixture, caseId = null) {
  if (!fixture || fixture.schemaVersion !== '1.0.0' || !Array.isArray(fixture.cases)) {
    throw new Error('fixture must use schemaVersion 1.0.0 and contain cases[]');
  }

  if (caseId) {
    const item = fixture.cases.find(candidate => candidate.id === caseId);
    if (!item) throw new Error(`fixture case not found: ${caseId}`);
    return {
      schemaVersion: '1.0.0',
      status: 'pass',
      caseId,
      result: evaluateCase(item),
    };
  }

  const results = fixture.cases.map(item => ({
    caseId: item.id,
    result: evaluateCase(item),
  }));
  return {
    schemaVersion: '1.0.0',
    status: 'pass',
    caseCount: results.length,
    results,
  };
}

function auditRepository(repoRoot) {
  const files = {
    longWrite: readRepoFile(repoRoot, 'src/internal-skills/story-long-write/SKILL.md'),
    daily: readRepoFile(repoRoot, 'src/internal-skills/story-long-write/references/workflow-daily.md'),
    claudeWriter: readRepoFile(repoRoot, 'src/internal-skills/story-setup/references/templates/agents/narrative-writer.md'),
    openCodeWriter: readRepoFile(repoRoot, 'src/internal-skills/story-setup/references/opencode/agents/narrative-writer.md'),
    deslop: readRepoFile(repoRoot, 'src/internal-skills/story-deslop/SKILL.md'),
  };
  const findings = [];
  let checkCount = 0;
  const check = (condition, code, message) => {
    checkCount += 1;
    if (!condition) findings.push({ code, message });
  };

  const routeRows = parseMarkdownTable(section(files.longWrite, '## 写作流程'));
  const startupRow = routeRows.find(row => row.some(cell => cell.includes('新书启动')));
  const explicitRow = routeRows.find(row => row.some(cell => cell.includes('显式正文执行')));
  check(Boolean(startupRow
    && startupRow.join(' ').includes('不进入 Phase 4→5')
    && startupRow.join(' ').includes('不生成正文候选')),
  'bare_route_must_dock', 'new-book bare route must stop before prose');
  check(Boolean(explicitRow
    && explicitRow.join(' ').includes('目标书/项目')
    && explicitRow.join(' ').includes('目标章节')
    && explicitRow.join(' ').includes('已通过')),
  'explicit_route_requires_target', 'prose route must require an explicit book, chapter, and passed brief');

  const preflight = files.daily.indexOf('## Step 0：正文准入预检');
  const stepOne = files.daily.indexOf('## Step 1：快速上下文加载');
  check(preflight >= 0 && preflight < stepOne,
    'daily_preflight_order', 'daily preflight must run before context loading');
  check(section(files.daily, '## Step 0：正文准入预检').includes('禁止创建/写入正文候选'),
    'underfilled_zero_candidate', 'daily preflight must suppress prose candidates when underfilled');
  check(section(files.daily, '## Step 0：正文准入预检').includes('第四章及之后'),
    'fourth_chapter_deferred', 'daily preflight must defer chapter four and later');

  const contractMarker = '**2.5 Chapter Contract**';
  const cardMarker = '**2.5a 单张题材正文卡**';
  const proseMarker = '**2.6 正文写作';
  const contractIndex = files.daily.indexOf(contractMarker);
  const cardIndex = files.daily.indexOf(cardMarker);
  const proseIndex = files.daily.indexOf(proseMarker);
  check(countOccurrences(files.daily, contractMarker) === 1,
    'single_chapter_contract_step', 'daily workflow must define one Chapter Contract step');
  check(contractIndex >= 0 && cardIndex > contractIndex && proseIndex > cardIndex,
    'contract_before_card', 'Chapter Contract must precede one-card trimming and prose writing');
  check(sectionAround(files.daily, cardMarker).includes('只向 writer packet 传这一张裁剪卡'),
    'single_sanitized_card', 'daily workflow must pass one trimmed card to the writer');

  for (const [name, content] of [['claude', files.claudeWriter], ['opencode', files.openCodeWriter]]) {
    const boundary = section(content, '### 长篇正文准入硬边界');
    check(boundary.includes('outline_underfilled')
      && boundary.includes('不得生成正文片段/候选稿')
      && boundary.includes('不得调用 Write/Edit')
      && boundary.includes('不得自行补情节'),
    `${name}_writer_underfilled_boundary`, `${name} writer must hard-stop underfilled outlines`);
  }

  const advisory = section(files.deslop, '### 任务块与隐喻密度的 advisory 复核');
  check(advisory.includes('不是计数型阻断器')
    && advisory.includes('机械换行')
    && advisory.includes('重排章节')
    && advisory.includes('改变事实'),
  'advisory_preserves_story', 'advisory detector evidence must not trigger mechanical or structural rewrites');

  return {
    schemaVersion: '1.0.0',
    status: findings.length ? 'fail' : 'pass',
    checkCount,
    findings,
  };
}

function auditTrace(repoRoot, range, reportPath) {
  if (!hasText(range)) throw new Error('--range is required for --audit-trace');
  if (!hasText(reportPath)) throw new Error('--report is required for --audit-trace');
  const report = fs.readFileSync(path.resolve(repoRoot, reportPath), 'utf8');
  const match = /<!-- task11-trace:start -->([\s\S]*?)<!-- task11-trace:end -->/.exec(report);
  if (!match) throw new Error('Task 11 trace markers are missing from report');

  const commits = childProcess.execFileSync('git', ['rev-list', '--reverse', range], {
    cwd: repoRoot,
    encoding: 'utf8',
  }).trim().split(/\r?\n/).filter(Boolean).map(commit => commit.slice(0, 7));
  const rows = match[1].split(/\r?\n/).map(line => {
    const row = /^\| `([0-9a-f]{7,40})` \| `(absorb|already-covered|skip-with-reason)` \| (.+) \|$/.exec(line.trim());
    return row ? { commit: row[1].slice(0, 7), decision: row[2], evidence: row[3] } : null;
  }).filter(Boolean);
  const expected = new Set(commits);
  const seen = new Map();
  const findings = [];
  const counts = { absorb: 0, 'already-covered': 0, 'skip-with-reason': 0 };

  for (const row of rows) {
    counts[row.decision] += 1;
    if (seen.has(row.commit)) findings.push({ code: 'duplicate_commit', commit: row.commit });
    seen.set(row.commit, row);
    if (!expected.has(row.commit)) findings.push({ code: 'unexpected_commit', commit: row.commit });
    if (row.evidence.includes('`A0`')) {
      const ancestry = childProcess.spawnSync('git', ['merge-base', '--is-ancestor', row.commit, 'HEAD'], {
        cwd: repoRoot,
        encoding: 'utf8',
      });
      if (ancestry.status !== 0) findings.push({ code: 'invalid_exact_ancestor_evidence', commit: row.commit });
    }
  }
  for (const commit of commits) {
    if (!seen.has(commit)) findings.push({ code: 'missing_commit', commit });
  }

  return {
    schemaVersion: '1.0.0',
    status: findings.length ? 'fail' : 'pass',
    range,
    commitCount: commits.length,
    tracedCount: rows.length,
    counts,
    findings,
  };
}

function indexByChapter(items) {
  return new Map((Array.isArray(items) ? items : []).map(item => [item.chapter, item]));
}

function isPassedBrief(brief) {
  return Boolean(brief
    && brief.status === 'passed'
    && REQUIRED_BRIEF_FIELDS.every(field => hasText(brief[field])));
}

function selectGenreCard(cards, primaryGenre) {
  const candidates = Array.isArray(cards) ? cards : [];
  return candidates.find(card => card && card.genre === primaryGenre) || null;
}

function trimCardToContract(card, contract) {
  const forbidden = new Set(Array.isArray(contract.forbiddenGenreConstraints)
    ? contract.forbiddenGenreConstraints
    : []);
  const result = {};
  for (const field of WRITER_CARD_FIELDS) {
    if (!(field in card)) continue;
    const value = cloneJson(card[field]);
    result[field] = Array.isArray(value) ? value.filter(item => !forbidden.has(item)) : value;
  }
  return result;
}

function hasText(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function cloneJson(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function readRepoFile(repoRoot, relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function section(content, heading) {
  const start = content.indexOf(heading);
  if (start < 0) return '';
  const depth = (heading.match(/^#+/) || [''])[0].length;
  const pattern = new RegExp(`^#{1,${depth}}\\s+`, 'm');
  const remainder = content.slice(start + heading.length);
  const match = pattern.exec(remainder);
  return match ? remainder.slice(0, match.index) : remainder;
}

function sectionAround(content, marker) {
  const start = content.indexOf(marker);
  if (start < 0) return '';
  const next = content.indexOf('\n   - **2.', start + marker.length);
  return next < 0 ? content.slice(start) : content.slice(start, next);
}

function parseMarkdownTable(content) {
  return content.split(/\r?\n/)
    .filter(line => /^\|.*\|$/.test(line.trim()))
    .map(line => line.trim().slice(1, -1).split('|').map(cell => cell.trim()))
    .filter(row => !row.every(cell => /^-+$/.test(cell)));
}

function countOccurrences(content, needle) {
  return content.split(needle).length - 1;
}

function readOption(args, name) {
  const eq = args.find(arg => arg.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] || '' : '';
}

function main() {
  const args = process.argv.slice(2);
  const repoRoot = path.resolve(readOption(args, '--repo-root') || path.join(__dirname, '..'));
  const fixturePath = readOption(args, '--fixture');
  const caseId = readOption(args, '--case') || null;
  const jsonOutput = args.includes('--json');
  if (args.includes('--audit-trace')) {
    const audit = auditTrace(
      repoRoot,
      readOption(args, '--range'),
      readOption(args, '--report'),
    );
    if (jsonOutput) process.stdout.write(`${JSON.stringify(audit, null, 2)}\n`);
    else process.stdout.write(`task11 trace audit: ${audit.status} (${audit.tracedCount}/${audit.commitCount})\n`);
    process.exit(audit.status === 'pass' ? 0 : 2);
  }
  if (args.includes('--audit-repo')) {
    const audit = auditRepository(repoRoot);
    if (jsonOutput) process.stdout.write(`${JSON.stringify(audit, null, 2)}\n`);
    else process.stdout.write(`task11 repository audit: ${audit.status} (${audit.checkCount} checks)\n`);
    process.exit(audit.status === 'pass' ? 0 : 2);
  }
  if (!fixturePath) throw new Error('--fixture is required');

  const fixture = JSON.parse(fs.readFileSync(path.resolve(fixturePath), 'utf8'));
  const result = evaluateFixture(fixture, caseId);
  if (jsonOutput) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else process.stdout.write(`task11 behavior validator: ${result.status} (${result.caseCount || result.caseId})\n`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`task11 behavior validator: ${error.message}\n`);
    process.exit(2);
  }
}

module.exports = {
  auditRepository,
  auditTrace,
  evaluateDeslop,
  evaluateFixture,
  evaluateLongWrite,
  trimCardToContract,
};
