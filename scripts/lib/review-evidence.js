'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { ensureDir, parseChapterNo, readDirSafe, readText, writeJson, writeJsonl } = require('./oh-story-artifacts');

const SOURCE_SCHEMA = 3;
const SOURCE_ASSET = 2;
const SOURCE_FILESYSTEM = 1;

function parseRange(raw) {
  const match = String(raw || '').trim().match(/^(\d+)(?:\s*(?:-|:|\.\.)\s*(\d+))?$/);
  if (!match) throw new Error('--range must be a positive chapter number or range such as 43-44');
  const start = Number(match[1]);
  const end = Number(match[2] || match[1]);
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) {
    throw new Error('--range must contain positive ascending chapter numbers');
  }
  return { start, end };
}

function buildEvidenceMap(projectRoot, range, options = {}) {
  const root = path.resolve(projectRoot);
  const candidates = collectCandidates(root);
  const chapterLayout = readChapterLayout(root);
  const legacyMixed = isLegacyMixedLayout(candidates, chapterLayout);
  const canonical = canonicalCandidates(candidates);
  const sourceContext = collectContextSources(root);
  const priorReportFindings = options.skipPriorReports
    ? []
    : inspectPriorReports(root, options.scriptDir || path.resolve(__dirname, '..'));
  const staticFindings = [];

  if (legacyMixed) {
    for (const candidate of canonical) {
      staticFindings.push(staticFinding({
        type: 'legacy-mixed-layout',
        severity: 'blocking',
        path: candidate.path,
        line: 1,
        column: 1,
        sourceStatus: 'legacy_mixed_layout',
        count: 1,
      }));
    }
  }

  staticFindings.push(...priorReportFindings);
  staticFindings.push(...missingVolumeChapterFindings(canonical, chapterLayout));
  const orderResolution = resolveGlobalOrders(canonical, range);
  staticFindings.push(...orderResolution.findings);
  if (legacyMixed || orderResolution.status !== 'ok') {
    return evidenceResult(
      legacyMixed ? 'blocked_mixed_chapter_layout' : orderResolution.status,
      range,
      [],
      staticFindings,
    );
  }

  const ordered = orderResolution.ordered;
  const requested = ordered.filter(candidate => candidate.globalDraftOrder >= range.start && candidate.globalDraftOrder <= range.end);
  const unavailable = requested.filter(candidate => !hasDraftFile(root, candidate));
  for (const candidate of unavailable) {
    staticFindings.push(staticFinding({
      type: 'missing-source-file', severity: 'blocking', path: candidate.path, line: 0, column: 0,
      globalDraftOrder: candidate.globalDraftOrder, sourceStatus: candidate.sourceStatus, count: 1,
    }));
  }
  const chapters = requested
    .filter(candidate => hasDraftFile(root, candidate))
    .map(candidate => chapterEvidence(root, candidate, range, sourceContext, staticFindings, options));
  const covered = new Set(chapters.map(chapter => chapter.globalDraftOrder));
  for (let order = range.start; order <= range.end; order += 1) {
    if (covered.has(order)) continue;
    staticFindings.push(staticFinding({
      type: 'missing-chapter',
      severity: 'advisory',
      path: '',
      line: 0,
      column: 0,
      globalDraftOrder: order,
      sourceStatus: legacyMixed ? 'legacy_mixed_layout' : 'trusted',
      count: 1,
    }));
  }

  for (const chapter of chapters) {
    chapter.staticRiskTags = Array.from(new Set(staticFindings
      .filter(finding => finding.globalDraftOrder === chapter.globalDraftOrder && ['punctuation', 'ai-pattern', 'degeneration'].includes(finding.type))
      .map(finding => finding.type)))
      .sort();
  }

  staticFindings.sort(compareFindings);
  return evidenceResult(
    unavailable.length ? 'blocked_missing_source_file' : (covered.size === range.end - range.start + 1 ? 'ok' : 'partial'),
    range,
    chapters,
    staticFindings,
  );
}

function evidenceResult(status, range, chapters, staticFindings) {
  const sourceHashes = Object.fromEntries(chapters
    .flatMap(chapter => [{ path: chapter.path, hash: chapter.hash }, ...chapter.sourceRefs])
    .filter(source => source.path && source.hash)
    .map(source => [source.path, source.hash])
    .sort(([left], [right]) => left.localeCompare(right, 'zh-Hans-CN')));
  return {
    schemaVersion: '1.0.0',
    status,
    range: { start: range.start, end: range.end },
    chapters,
    staticFindings,
    sourceHashes,
    summary: {
      requestedChapters: range.end - range.start + 1,
      mappedChapters: chapters.length,
      missingChapters: staticFindings.filter(item => item.type === 'missing-chapter').length,
      staticFindings: staticFindings.length,
      blockingSignals: staticFindings.filter(item => item.severity === 'blocking').length,
      sourceStatus: status,
    },
  };
}

function writeEvidenceMap(projectRoot, evidenceMap) {
  const evidenceDir = path.join(projectRoot, 'evidence');
  ensureDir(evidenceDir);
  writeJsonl(path.join(evidenceDir, 'chapter-evidence.jsonl'), evidenceMap.chapters);
  writeJsonl(path.join(evidenceDir, 'static-findings.jsonl'), evidenceMap.staticFindings);
  writeJson(path.join(evidenceDir, 'risk-summary.json'), {
    schemaVersion: evidenceMap.schemaVersion,
    status: evidenceMap.status,
    range: evidenceMap.range,
    sourceHashes: evidenceMap.sourceHashes,
    summary: evidenceMap.summary,
  });
}

function collectCandidates(root) {
  const byPath = new Map();
  addCandidates(byPath, readSchemaCandidates(root), SOURCE_SCHEMA);
  addCandidates(byPath, readAssetCandidates(root), SOURCE_ASSET);
  addCandidates(byPath, scanDraftCandidates(root), SOURCE_FILESYSTEM);
  return Array.from(byPath.values());
}

function addCandidates(byPath, items, priority) {
  for (const item of items) {
    if (!item.path || !safeProjectPath(item.path)) continue;
    const previous = byPath.get(item.path);
    if (!previous || priority > previous.priority) {
      byPath.set(item.path, previous
        ? mergeCandidateEvidence({ ...item, priority }, previous)
        : { ...item, priority });
      continue;
    }
    byPath.set(item.path, mergeCandidateEvidence(previous, { ...item, priority }));
  }
}

function readSchemaCandidates(root) {
  return readJsonl(path.join(root, '追踪', 'schema', 'chapters.jsonl')).flatMap((chapter) => {
    if (!chapter || !chapter.draftPath) return [];
    return [candidateFromSource(chapter, chapter.draftPath, 'schema')];
  });
}

function readAssetCandidates(root) {
  return readJsonl(path.join(root, '追踪', '章节资产.jsonl')).flatMap((asset) => {
    if (!asset || !asset.draftPath) return [];
    return [candidateFromSource(asset, asset.draftPath, 'asset')];
  });
}

function candidateFromSource(source, draftPath, sourceKind) {
  const normalizedPath = slash(draftPath);
  const inferred = inferChapterFromPath(draftPath);
  const globalDraftOrder = positiveInt(source.globalDraftOrder) || positiveInt(source.chapterNo) || null;
  return {
    path: normalizedPath,
    volume: source.volume || inferred.volume,
    volumeChapterNo: positiveInt(source.volumeChapterNo) || inferred.volumeChapterNo,
    globalDraftOrder,
    outlinePath: source.outlinePath || '',
    contractPath: source.contractPath || '',
    handoffPath: source.handoffPath || '',
    sourceKind,
    authoritative: true,
    authoritativePaths: [normalizedPath],
    authoritativePathEvidence: [{ path: normalizedPath, sourceKind, backup: isBackupDraftPath(normalizedPath) }],
    orderEvidence: [{
      value: globalDraftOrder,
      sourceKind,
      path: normalizedPath,
      backup: isBackupDraftPath(normalizedPath),
    }],
  };
}

function scanDraftCandidates(root) {
  const result = [];
  walkFiles(path.join(root, '正文'), '正文', (absPath, relPath) => {
    if (!/\.(?:md|txt)$/i.test(relPath)) return;
    if (isBackupDraftPath(relPath)) return;
    const chapter = inferChapterFromPath(relPath);
    if (!chapter.volumeChapterNo) return;
    result.push({
      path: relPath, ...chapter, globalDraftOrder: null, outlinePath: '', contractPath: '', handoffPath: '',
      sourceKind: 'filesystem', authoritative: false, authoritativePaths: [], authoritativePathEvidence: [], orderEvidence: [],
    });
  });
  return result;
}

function canonicalCandidates(candidates) {
  const byIdentity = new Map();
  for (const candidate of candidates) {
    const key = `${candidate.volume}|${candidate.volumeChapterNo}`;
    const group = byIdentity.get(key) || [];
    group.push(candidate);
    byIdentity.set(key, group);
  }
  return Array.from(byIdentity.values()).map((group) => {
    const selected = group.slice().sort(compareCandidateTrust)[0];
    return group
      .filter(candidate => candidate !== selected)
      .reduce((merged, candidate) => mergeCandidateEvidence(merged, candidate), selected);
  });
}

function mergeCandidateEvidence(primary, secondary) {
  const preferred = compareCandidateTrust(primary, secondary) <= 0 ? primary : secondary;
  const fallback = preferred === primary ? secondary : primary;
  return {
    ...fallback,
    ...preferred,
    authoritative: Boolean(primary.authoritative || secondary.authoritative),
    authoritativePaths: Array.from(new Set([...(primary.authoritativePaths || []), ...(secondary.authoritativePaths || [])])),
    authoritativePathEvidence: uniquePathEvidence([
      ...(primary.authoritativePathEvidence || []),
      ...(secondary.authoritativePathEvidence || []),
    ]),
    orderEvidence: [...(primary.orderEvidence || []), ...(secondary.orderEvidence || [])],
  };
}

function compareCandidateTrust(left, right) {
  if (left.priority !== right.priority) return right.priority - left.priority;
  const leftVolumeLocal = isVolumeLocalPath(left.path) ? 0 : 1;
  const rightVolumeLocal = isVolumeLocalPath(right.path) ? 0 : 1;
  return leftVolumeLocal - rightVolumeLocal || left.path.localeCompare(right.path, 'zh-Hans-CN');
}

function isLegacyMixedLayout(candidates, chapterLayout) {
  if (chapterLayout === 'volume' || chapterLayout === 'flat') return false;
  const volumeCandidates = candidates.filter(candidate => isVolumeLocalPath(candidate.path));
  const volumes = new Set(volumeCandidates.map(candidate => candidate.volume));
  if (volumes.size < 2) return false;
  const orderedVolumes = Array.from(volumes).sort((left, right) => volumeOrder(left) - volumeOrder(right));
  return orderedVolumes.slice(1).some((volume) => {
    const chapterNos = volumeCandidates.filter(candidate => candidate.volume === volume).map(candidate => candidate.volumeChapterNo);
    return chapterNos.length > 0 && Math.min(...chapterNos) > chapterNos.length + 1 && Math.min(...chapterNos) > 10;
  });
}

function resolveGlobalOrders(candidates, range) {
  const sorted = [...candidates].sort(compareCandidateOrder);
  if (!sorted.some(candidate => candidate.authoritative)) {
    return {
      status: 'ok',
      findings: [],
      ordered: sorted.map((candidate, index) => ({ ...candidate, globalDraftOrder: index + 1, sourceStatus: 'trusted' })),
    };
  }

  const findings = [];
  const resolved = [];
  for (const candidate of sorted) {
    const pathEvidence = uniquePathEvidence(candidate.authoritativePathEvidence || []);
    const authoritativePaths = Array.from(new Set(candidate.authoritativePaths || []));
    const activePaths = pathEvidence.filter(item => !item.backup).map(item => item.path);
    const backupPaths = pathEvidence.filter(item => item.backup).map(item => item.path);
    const ignoresBackupPaths = authoritativePaths.length > 1 && activePaths.length === 1 && backupPaths.length;
    const evidence = ignoresBackupPaths
      ? (candidate.orderEvidence || []).filter(item => !item.backup)
      : (candidate.orderEvidence || []);
    const values = Array.from(new Set(evidence.map(item => item.value).filter(Boolean)));
    if (ignoresBackupPaths) {
      findings.push(ignoredBackupPathFinding(candidate, activePaths[0], backupPaths));
    } else if (authoritativePaths.length > 1) {
      findings.push(identityPathFinding(candidate, authoritativePaths));
    }
    if (!candidate.authoritative) {
      findings.push(staticFinding({
        type: 'global-order-incomplete',
        severity: 'advisory',
        path: candidate.path,
        line: 0,
        column: 0,
        globalDraftOrder: null,
        sourceStatus: 'filesystem_unindexed',
        count: 1,
      }));
    } else if (evidence.some(item => !item.value)) {
      findings.push(orderFinding('global-order-incomplete', candidate, values[0] || null));
    } else if (values.length !== 1) {
      findings.push(orderFinding('global-order-conflict', candidate, values[0] || null, values));
    } else {
      resolved.push({ ...candidate, globalDraftOrder: values[0], sourceStatus: 'trusted' });
    }
  }
  const byOrder = new Map();
  for (const candidate of resolved) {
    const list = byOrder.get(candidate.globalDraftOrder) || [];
    list.push(candidate);
    byOrder.set(candidate.globalDraftOrder, list);
  }
  for (const [order, group] of byOrder) {
    if (group.length < 2) continue;
    for (const candidate of group) findings.push(orderFinding('global-order-conflict', candidate, order));
  }
  const scopedFindings = findings.map(finding => scopeFinding(finding, range));
  const blockingFindings = scopedFindings.filter(finding => finding.severity === 'blocking');
  if (blockingFindings.length) {
    for (const candidate of resolved.filter(item => item.globalDraftOrder >= range.start && item.globalDraftOrder <= range.end)) {
      findings.push(staticFinding({
        type: 'global-order-evidence',
        severity: 'advisory',
        path: candidate.path,
        line: 0,
        column: 0,
        globalDraftOrder: candidate.globalDraftOrder,
        sourceStatus: 'trusted',
        count: 1,
      }));
    }
    const resultFindings = findings.map(finding => scopeFinding(finding, range));
    const hasIdentityConflict = resultFindings.some(finding => finding.type === 'chapter-identity-path-conflict');
    const hasOrderConflict = resultFindings.some(finding => finding.type === 'global-order-conflict');
    return {
      status: hasIdentityConflict ? 'blocked_chapter_identity_conflict' : (hasOrderConflict ? 'blocked_global_order_conflict' : 'blocked_global_order_incomplete'),
      findings: resultFindings,
      ordered: [],
    };
  }
  return {
    status: 'ok',
    findings: scopedFindings,
    ordered: resolved.sort((left, right) => left.globalDraftOrder - right.globalDraftOrder || compareCandidateOrder(left, right)),
  };
}

function scopeFinding(finding, range) {
  const observedOrders = Array.isArray(finding.observedGlobalDraftOrders)
    ? finding.observedGlobalDraftOrders.filter(Number.isInteger)
    : [];
  const touchesRange = [finding.globalDraftOrder, ...observedOrders]
    .some(order => Number.isInteger(order) && order >= range.start && order <= range.end);
  if (!Number.isInteger(finding.globalDraftOrder) || touchesRange) {
    return finding;
  }
  return {
    ...finding,
    severity: 'advisory',
    sourceStatus: 'out_of_range',
  };
}

function orderFinding(type, candidate, globalDraftOrder, observedGlobalDraftOrders = []) {
  return staticFinding({
    type,
    severity: 'blocking',
    path: candidate.path,
    line: 0,
    column: 0,
    globalDraftOrder,
    sourceStatus: 'untrusted',
    count: 1,
    observedGlobalDraftOrders,
  });
}

function identityPathFinding(candidate, observedPaths) {
  return staticFinding({
    type: 'chapter-identity-path-conflict',
    severity: 'blocking',
    path: candidate.path,
    line: 0,
    column: 0,
    globalDraftOrder: candidate.globalDraftOrder || null,
    sourceStatus: 'untrusted',
    count: observedPaths.length,
    observedPaths,
  });
}

function ignoredBackupPathFinding(candidate, currentPath, backupPaths) {
  return staticFinding({
    type: 'chapter-backup-path-ignored',
    severity: 'advisory',
    path: currentPath,
    line: 0,
    column: 0,
    globalDraftOrder: candidate.globalDraftOrder || null,
    sourceStatus: 'trusted',
    count: backupPaths.length,
    observedPaths: backupPaths,
  });
}

function missingVolumeChapterFindings(candidates, chapterLayout) {
  if (chapterLayout !== 'volume') return [];
  const byVolume = new Map();
  for (const candidate of candidates) {
    if (!isVolumeLocalPath(candidate.path) || !candidate.volumeChapterNo) continue;
    const group = byVolume.get(candidate.volume) || [];
    group.push(candidate);
    byVolume.set(candidate.volume, group);
  }
  const findings = [];
  for (const [volume, group] of byVolume) {
    const chapterNos = new Set(group.map(candidate => candidate.volumeChapterNo));
    const maxChapterNo = Math.max(...chapterNos);
    const location = path.dirname(group.slice().sort(compareCandidateOrder)[0].path);
    for (let volumeChapterNo = 1; volumeChapterNo <= maxChapterNo; volumeChapterNo += 1) {
      if (chapterNos.has(volumeChapterNo)) continue;
      findings.push(staticFinding({
        type: 'missing-volume-chapter',
        severity: 'advisory',
        path: location,
        line: 0,
        column: 0,
        sourceStatus: 'trusted',
        count: 1,
        volume,
        volumeChapterNo,
      }));
    }
  }
  return findings;
}

function chapterEvidence(root, candidate, range, sourceContext, staticFindings, options) {
  const absolute = resolveProjectFile(root, candidate.path);
  const text = readText(absolute, '');

  const outlineRefs = uniquePaths([candidate.outlinePath, inferOutlinePath(root, candidate)].filter(Boolean));
  const sourceRefs = [];
  for (const outlinePath of outlineRefs) addSourceRef(root, sourceRefs, outlinePath, 'outline', 'trusted');
  for (const context of sourceContext) addSourceRef(root, sourceRefs, context.path, context.kind, 'trusted');
  if (candidate.contractPath) addSourceRef(root, sourceRefs, candidate.contractPath, 'contract', 'trusted');
  if (candidate.handoffPath) addSourceRef(root, sourceRefs, candidate.handoffPath, 'handoff', 'trusted');

  if (!options.skipChapterChecks) {
    staticFindings.push(...runChapterChecks(root, candidate.path, candidate.globalDraftOrder, candidate.sourceStatus, options));
  }
  const boundaryTags = [];
  if (candidate.globalDraftOrder === range.start) boundaryTags.push('range-start');
  if (candidate.globalDraftOrder === range.end) boundaryTags.push('range-end');
  if (outlineRefs.length) boundaryTags.push('outline-source');
  for (const context of sourceContext) boundaryTags.push(`${context.kind}-source`);
  if (candidate.handoffPath) boundaryTags.push('handoff-source');

  return {
    chapterKey: `v${String(volumeOrder(candidate.volume)).padStart(2, '0')}-c${String(candidate.volumeChapterNo).padStart(3, '0')}`,
    globalDraftOrder: candidate.globalDraftOrder,
    volume: candidate.volume,
    volumeChapterNo: candidate.volumeChapterNo,
    path: candidate.path,
    chars: text.replace(/\s/g, '').length,
    hash: sha256(text),
    outlineRefs,
    staticRiskTags: [],
    boundaryTags,
    sourceStatus: candidate.sourceStatus,
    sourceRefs,
  };
}

function runChapterChecks(root, relPath, globalDraftOrder, sourceStatus, options) {
  const scriptDir = options.scriptDir || path.resolve(__dirname, '..');
  const absolute = resolveProjectFile(root, relPath);
  if (!absolute || !fs.existsSync(absolute)) return [];
  const results = [];
  results.push(...parseTextCheck(runNode(scriptDir, 'normalize-punctuation.js', ['--check', absolute]), 'punctuation', relPath, globalDraftOrder, sourceStatus));
  results.push(...parseJsonCheck(runNode(scriptDir, 'check-ai-patterns.js', ['--json', '--fail-on=all', absolute]), 'ai-pattern', relPath, globalDraftOrder, sourceStatus));
  results.push(...parseJsonCheck(runNode(scriptDir, 'check-degeneration.js', ['--json', '--fail-on=all', absolute]), 'degeneration', relPath, globalDraftOrder, sourceStatus));
  return results;
}

function runNode(scriptDir, script, args) {
  return spawnSync(process.execPath, [path.join(scriptDir, script), ...args], { encoding: 'utf8', shell: false });
}

function parseTextCheck(result, detector, relPath, globalDraftOrder, sourceStatus) {
  const findings = [];
  for (const line of String(result.stdout || '').split(/\r?\n/)) {
    const match = line.match(/:(\d+):(\d+):\s*([^:]+):\s*(.*)$/);
    if (!match) continue;
    findings.push(staticFinding({
      type: detector, severity: 'advisory', path: relPath, line: Number(match[1]), column: Number(match[2]),
      globalDraftOrder, sourceStatus, count: 1, detectorType: match[3].trim(),
    }));
  }
  return findings;
}

function parseJsonCheck(result, detector, relPath, globalDraftOrder, sourceStatus) {
  let parsed;
  try {
    parsed = JSON.parse(result.stdout || '{}');
  } catch (_error) {
    return [];
  }
  return (Array.isArray(parsed.findings) ? parsed.findings : []).map((finding) => staticFinding({
    type: detector,
    severity: finding.severity === 'blocking' ? 'blocking' : 'advisory',
    path: relPath,
    line: Number(finding.line) || 0,
    column: Number(finding.column) || 0,
    globalDraftOrder,
    sourceStatus,
    count: 1,
    detectorType: String(finding.type || ''),
  }));
}

function collectContextSources(root) {
  const known = [
    ['hooks', '追踪/伏笔.md'],
    ['timeline', '追踪/时间线.md'],
    ['character-state', '追踪/人物状态.md'],
    ['character-state', '追踪/角色状态.md'],
  ];
  return known
    .filter(([, relPath]) => fs.existsSync(resolveProjectFile(root, relPath)))
    .map(([kind, relPath]) => ({ kind, path: relPath }));
}

function readChapterLayout(root) {
  const stateFile = path.join(root, '.book-state.json');
  try {
    const state = JSON.parse(readText(stateFile, '{}'));
    const layout = String(state.chapterLayout || 'auto').trim().toLowerCase();
    if (['volume', 'volume-local', 'volume_local', '卷内'].includes(layout)) return 'volume';
    if (['flat', 'legacy', 'legacy-flat', 'legacy_flat'].includes(layout)) return 'flat';
  } catch (_error) {
    // An unreadable layout declaration cannot establish a legacy numbering policy.
  }
  return 'auto';
}

function hasDraftFile(root, candidate) {
  const file = resolveProjectFile(root, candidate.path);
  return Boolean(file && fs.existsSync(file) && fs.statSync(file).isFile());
}

function inspectPriorReports(root, scriptDir) {
  const findings = [];
  walkFiles(root, '', (absolute, relPath) => {
    if (!isPriorReport(relPath) || !/\.md$/i.test(relPath)) return;
    const result = runNode(scriptDir, 'output-pollution-check.js', ['--json', absolute]);
    let parsed;
    try {
      parsed = JSON.parse(result.stdout || '{}');
    } catch (_error) {
      return;
    }
    const count = Array.isArray(parsed.findings) ? parsed.findings.length : 0;
    if (!count) return;
    findings.push(staticFinding({
      type: 'polluted-prior-report', severity: 'advisory', path: relPath, line: 1, column: 1,
      sourceStatus: 'polluted', count, usableForCanon: false,
    }));
  });
  return findings;
}

function isPriorReport(relPath) {
  const text = slash(relPath);
  return /(?:报告|审阅|review|report)/i.test(text) && !text.startsWith('evidence/');
}

function inferOutlinePath(root, candidate) {
  const volumePath = `大纲/${candidate.volume}/细纲_第${String(candidate.volumeChapterNo).padStart(3, '0')}章.md`;
  const unpaddedVolumePath = `大纲/${candidate.volume}/细纲_第${candidate.volumeChapterNo}章.md`;
  const flatPath = `大纲/细纲_第${String(candidate.volumeChapterNo).padStart(3, '0')}章.md`;
  return [volumePath, unpaddedVolumePath, flatPath].find(relPath => fs.existsSync(resolveProjectFile(root, relPath))) || '';
}

function addSourceRef(root, refs, relPath, kind, sourceStatus) {
  const normalized = slash(relPath);
  if (refs.some(ref => ref.path === normalized)) return;
  const absolute = resolveProjectFile(root, normalized);
  if (!absolute || !fs.existsSync(absolute)) return;
  refs.push({ path: normalized, kind, hash: sha256(readText(absolute, '')), sourceStatus });
}

function staticFinding(fields) {
  return {
    schemaVersion: '1.0.0',
    type: fields.type,
    severity: fields.severity,
    path: fields.path,
    line: fields.line,
    column: fields.column,
    globalDraftOrder: fields.globalDraftOrder || null,
    sourceStatus: fields.sourceStatus,
    count: fields.count,
    ...(fields.detectorType ? { detectorType: fields.detectorType } : {}),
    ...(fields.usableForCanon === false ? { usableForCanon: false } : {}),
    ...(Array.isArray(fields.observedGlobalDraftOrders) && fields.observedGlobalDraftOrders.length
      ? { observedGlobalDraftOrders: fields.observedGlobalDraftOrders } : {}),
    ...(Array.isArray(fields.observedPaths) && fields.observedPaths.length ? { observedPaths: fields.observedPaths } : {}),
    ...(fields.volume ? { volume: fields.volume } : {}),
    ...(Number.isInteger(fields.volumeChapterNo) ? { volumeChapterNo: fields.volumeChapterNo } : {}),
  };
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(line => line.trim()).filter(Boolean).flatMap((line) => {
    try {
      return [JSON.parse(line)];
    } catch (_error) {
      return [];
    }
  });
}

function walkFiles(absDir, relDir, visit) {
  for (const name of readDirSafe(absDir)) {
    const absolute = path.join(absDir, name);
    const relative = slash(path.join(relDir, name));
    let stat;
    try {
      stat = fs.statSync(absolute);
    } catch (_error) {
      continue;
    }
    if (stat.isDirectory()) walkFiles(absolute, relative, visit);
    else if (stat.isFile()) visit(absolute, relative);
  }
}

function uniquePathEvidence(items) {
  const byKey = new Map();
  for (const item of items) {
    if (!item || !item.path) continue;
    const normalized = { ...item, path: slash(item.path), backup: Boolean(item.backup) };
    byKey.set(`${normalized.sourceKind || ''}|${normalized.path}`, normalized);
  }
  return Array.from(byKey.values());
}

function isBackupDraftPath(relPath) {
  const normalized = slash(relPath);
  const basename = path.basename(normalized);
  return /(?:^|_)原稿(?:_|\.)/.test(basename)
    || /(?:^|[/_-])(?:备份|backup|archive)(?:[/_.-]|$)/i.test(normalized)
    || /(?:\.bak|~)$/i.test(basename);
}

function inferChapterFromPath(relPath) {
  const volume = slash(relPath).split('/').find(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part)) || '第1卷';
  const base = path.basename(relPath);
  const englishChapter = base.match(/\bchapter[-_\s]*0*([1-9]\d*)\b/i);
  return { volume, volumeChapterNo: parseChapterNo(base) || (englishChapter ? Number(englishChapter[1]) : null) };
}

function isVolumeLocalPath(relPath) {
  return slash(relPath).split('/').some(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part));
}

function compareCandidateOrder(left, right) {
  return volumeOrder(left.volume) - volumeOrder(right.volume)
    || left.volumeChapterNo - right.volumeChapterNo
    || left.path.localeCompare(right.path, 'zh-Hans-CN');
}

function compareFindings(left, right) {
  return (left.globalDraftOrder || Number.MAX_SAFE_INTEGER) - (right.globalDraftOrder || Number.MAX_SAFE_INTEGER)
    || left.path.localeCompare(right.path, 'zh-Hans-CN')
    || left.line - right.line
    || left.column - right.column
    || left.type.localeCompare(right.type);
}

function volumeOrder(volume) {
  const arabic = String(volume).match(/第\s*([0-9]+)\s*卷/);
  if (arabic) return Number(arabic[1]);
  const values = { 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const chinese = String(volume).match(/第\s*([一二三四五六七八九十两]+)\s*卷/);
  if (!chinese) return 1;
  if (chinese[1] === '十') return 10;
  const ten = chinese[1].indexOf('十');
  if (ten >= 0) return (values[chinese[1][0]] || 1) * 10 + (values[chinese[1][ten + 1]] || 0);
  return values[chinese[1]] || 1;
}

function resolveProjectFile(root, relPath) {
  if (!safeProjectPath(relPath)) return null;
  const resolved = path.resolve(root, ...slash(relPath).split('/'));
  return resolved.startsWith(`${root}${path.sep}`) ? resolved : null;
}

function safeProjectPath(relPath) {
  const normalized = slash(relPath);
  return Boolean(normalized) && !path.posix.isAbsolute(normalized) && !normalized.split('/').some(part => !part || part === '.' || part === '..');
}

function uniquePaths(paths) {
  return Array.from(new Set(paths.map(slash))).sort((left, right) => left.localeCompare(right, 'zh-Hans-CN'));
}

function positiveInt(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

function sha256(text) {
  return crypto.createHash('sha256').update(String(text || ''), 'utf8').digest('hex');
}

function slash(value) {
  return String(value || '').split(path.sep).join('/');
}

module.exports = { buildEvidenceMap, parseRange, writeEvidenceMap };
