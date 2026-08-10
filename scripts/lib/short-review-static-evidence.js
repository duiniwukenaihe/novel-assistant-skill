'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function collectShortReviewStaticEvidence(storyFile) {
  const absolute = path.resolve(String(storyFile || ''));
  if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
    return {
      static_findings: [],
      detector_status: [{ detector: 'static-evidence', status: 'unavailable', reason: 'story_file_missing' }],
    };
  }
  const text = fs.readFileSync(absolute, 'utf8');
  const sectionAtLine = buildSectionLineResolver(text);
  const findings = [];
  const statuses = [];

  for (const [script, detector] of [
    ['check-ai-patterns.js', 'ai-pattern'],
    ['check-degeneration.js', 'degeneration'],
  ]) {
    const run = runDetector(script, ['--check', '--json', '--fail-on=all', absolute]);
    const parsed = parseDetectorJson(run.stdout);
    if (!parsed || run.status === 2 || String(parsed.status || '') === 'partial') {
      statuses.push({ detector, status: 'unavailable', reason: detectorFailureReason(run, parsed) });
      continue;
    }
    statuses.push({ detector, status: 'complete' });
    for (const item of Array.isArray(parsed.findings) ? parsed.findings : []) {
      const line = Number((item || {}).line) || 0;
      findings.push({
        section_index: sectionAtLine(line),
        detector,
        severity: String((item || {}).severity || '') === 'blocking' ? 'blocking' : 'advisory',
        type: String((item || {}).type || ''),
        line,
        column: Number((item || {}).column) || 0,
        message: String((item || {}).message || ''),
      });
    }
  }

  const punctuation = runDetector('normalize-punctuation.js', ['--check', absolute]);
  if (![0, 1].includes(Number(punctuation.status))) {
    statuses.push({ detector: 'punctuation', status: 'unavailable', reason: detectorFailureReason(punctuation, null) });
  } else {
    statuses.push({ detector: 'punctuation', status: 'complete' });
    for (const lineText of `${String(punctuation.stdout || '')}\n${String(punctuation.stderr || '')}`.split(/\r?\n/u)) {
      const match = lineText.match(/^(.*):(\d+):(\d+):\s*([^:]+):\s*(.*)$/u);
      if (!match || path.resolve(match[1]) !== absolute) continue;
      const line = Number(match[2]) || 0;
      findings.push({
        section_index: sectionAtLine(line),
        detector: 'punctuation',
        severity: 'advisory',
        type: String(match[4] || '').trim(),
        line,
        column: Number(match[3]) || 0,
        message: String(match[5] || '').trim(),
      });
    }
  }

  findings.sort((left, right) => (
    Number(left.section_index || 0) - Number(right.section_index || 0)
    || Number(left.line || 0) - Number(right.line || 0)
    || String(left.detector || '').localeCompare(String(right.detector || ''))
  ));
  return { static_findings: findings, detector_status: statuses };
}

function runDetector(script, args) {
  return spawnSync(process.execPath, [path.join(__dirname, '..', script), ...args], {
    encoding: 'utf8',
    shell: false,
    maxBuffer: 16 * 1024 * 1024,
  });
}

function parseDetectorJson(value) {
  try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; }
}

function detectorFailureReason(run, parsed) {
  if (parsed && String(parsed.status || '') === 'partial') return 'partial_scan';
  return String((run || {}).error || (run || {}).stderr || 'detector_output_invalid').trim().slice(0, 300);
}

function buildSectionLineResolver(text) {
  const starts = [];
  String(text || '').split(/\r?\n/u).forEach((line, index) => {
    const match = line.match(/^##\s+第\s*0*(\d+)\s*节/u);
    if (match) starts.push({ line: index + 1, section_index: Number(match[1]) });
  });
  return (line) => {
    let sectionIndex = 0;
    for (const start of starts) {
      if (start.line > Number(line || 0)) break;
      sectionIndex = start.section_index;
    }
    return sectionIndex;
  };
}

module.exports = { collectShortReviewStaticEvidence };
