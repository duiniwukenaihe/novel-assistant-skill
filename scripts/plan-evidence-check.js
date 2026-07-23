#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const EVIDENCE_REQUIRED = new Set(['verified', 'installed', 'released']);
const NEXT_NOT_REQUIRED = new Set(['released', 'blocked']);
const PHASE_STATUSES = new Set(['planned', 'implemented', 'verified', 'installed', 'released', 'blocked']);
const REPORT_SUCCESS_STATUSES = new Set(['pass', 'passed', 'verified', 'completed', 'success']);

function parseArgs(argv) {
  const args = { json: false, plan: '', repoRoot: path.resolve(__dirname, '..') };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--json') args.json = true;
    else if (arg === '--plan') args.plan = argv[index + 1] || '';
    else if (arg === '--repo-root') args.repoRoot = argv[index + 1] || '';
  }
  return args;
}

function parseTopLevelHeadings(markdown) {
  const headings = [];
  stripIgnoredMarkdown(markdown).split(/\r?\n/).forEach((line, index) => {
    if (/^ {0,3}#(?:[ \t]+|$)/.test(line)) {
      headings.push({ line: index + 1, text: line.replace(/^ {0,3}#[ \t]*/, '') });
    }
  });

  return headings;
}

function parseSetextTopLevelHeadings(markdown) {
  const lines = stripIgnoredMarkdown(markdown).split(/\r?\n/);
  const headings = [];
  for (let index = 1; index < lines.length; index += 1) {
    if (/^ {0,3}=+[ \t]*$/.test(lines[index]) && lines[index - 1].trim()) {
      headings.push({ line: index, text: lines[index - 1].trim() });
    }
  }
  return headings;
}

function splitRow(line) {
  const source = line.trim().replace(/^\||\|$/g, '');
  const cells = [];
  let cell = '';

  for (let index = 0; index < source.length; index += 1) {
    if (source[index] === '\\' && source[index + 1] === '|') {
      cell += '|';
      index += 1;
    } else if (source[index] === '|') {
      cells.push(cell.trim());
      cell = '';
    } else {
      cell += source[index];
    }
  }
  cells.push(cell.trim());
  return cells;
}

function stripIgnoredMarkdown(markdown) {
  const lines = markdown.split(/\r?\n/);
  const visibleLines = [];
  let inComment = false;
  let fence = null;
  let inlineCodeLength = 0;

  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (fence) {
      const closing = line.match(/^ {0,3}(`+|~+)[ \t]*$/);
      if (closing && closing[1][0] === fence.marker && closing[1].length >= fence.length) fence = null;
      visibleLines.push('');
      continue;
    }

    if (!inComment && inlineCodeLength === 0) {
      const opening = line.match(/^ {0,3}(`{3,}|~{3,})/);
      if (opening) {
        fence = { marker: opening[1][0], length: opening[1].length };
        visibleLines.push('');
        continue;
      }
    }

    let visible = '';
    let cursor = 0;
    while (cursor < line.length) {
      if (inComment) {
        const commentEnd = line.indexOf('-->', cursor);
        if (commentEnd === -1) {
          cursor = line.length;
          break;
        }
        inComment = false;
        cursor = commentEnd + 3;
        continue;
      }

      if (line[cursor] === '`') {
        let end = cursor + 1;
        while (line[end] === '`') end += 1;
        const runLength = end - cursor;
        if (inlineCodeLength === 0 && hasClosingInlineCodeRun(lines, lineIndex, end, runLength)) {
          inlineCodeLength = runLength;
        } else if (inlineCodeLength === runLength) inlineCodeLength = 0;
        visible += line.slice(cursor, end);
        cursor = end;
        continue;
      }

      if (inlineCodeLength === 0 && line.startsWith('<!--', cursor) && !isEscaped(line, cursor)) {
        inComment = true;
        cursor += 4;
        continue;
      }

      visible += line[cursor];
      cursor += 1;
    }
    visibleLines.push(visible);
  }

  return visibleLines.join('\n');
}

function hasClosingInlineCodeRun(lines, lineIndex, column, runLength) {
  for (let index = lineIndex; index < lines.length; index += 1) {
    const line = lines[index];
    if (index > lineIndex && isInlineBlockBoundary(line)) return false;
    let cursor = index === lineIndex ? column : 0;
    while (cursor < line.length) {
      if (line[cursor] !== '`') {
        cursor += 1;
        continue;
      }
      let end = cursor + 1;
      while (line[end] === '`') end += 1;
      if (end - cursor === runLength) return true;
      cursor = end;
    }
  }
  return false;
}

function isInlineBlockBoundary(line) {
  return !line.trim()
    || /^ {0,3}(?:#{1,6}(?:[ \t]+|$)|>|(?:[-+*]|\d+[.)])[ \t]+|`{3,}|~{3,}|<!--)/.test(line);
}

function isEscaped(line, index) {
  let slashCount = 0;
  for (let cursor = index - 1; cursor >= 0 && line[cursor] === '\\'; cursor -= 1) slashCount += 1;
  return slashCount % 2 === 1;
}

function isValidSeparator(line) {
  const cells = splitRow(line);
  return cells.length === 4 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function parsePlanStatus(markdown) {
  const lines = stripIgnoredMarkdown(markdown).split(/\r?\n/);
  const phases = [];
  const schemaFindings = [];
  let hasPlanStatus = false;
  const planStatusLines = lines.flatMap((line, index) => (
    /^ {0,3}##[ \t]+Plan Status[ \t]*#*[ \t]*$/i.test(line) ? [index] : []
  ));
  const planStatusLine = planStatusLines[0] ?? -1;

  if (planStatusLine === -1) return {
    hasPlanStatus, phases, schemaFindings, planStatusLine: -1,
  };

  schemaFindings.push(...planStatusLines.slice(1)
    .map((line) => ({ code: 'duplicate_plan_status_section', line: line + 1 })));

  for (let index = planStatusLine + 1; index < lines.length; index += 1) {
    if (/^ {0,3}#{1,6}(?:[ \t]+|$)/.test(lines[index])) break;
    const header = splitRow(lines[index]);
    if (header.join('|').toLowerCase() !== 'phase|status|evidence|next') continue;
    hasPlanStatus = true;
    if (!isValidSeparator(lines[index + 1] || '')) {
      schemaFindings.push({ code: 'invalid_phase_separator', line: index + 2 });
      break;
    }

    for (let rowIndex = index + 2; rowIndex < lines.length; rowIndex += 1) {
      const line = lines[rowIndex];
      if (!line.trim().startsWith('|')) break;
      const cells = splitRow(line);
      if (cells.length !== 4) {
        schemaFindings.push({ code: 'invalid_phase_row', line: rowIndex + 1 });
        continue;
      }
      phases.push({
        phase: cells[0],
        status: cells[1].toLowerCase(),
        evidence: cells[2],
        next: cells[3],
        line: rowIndex + 1,
      });
    }
    break;
  }

  const seenPhases = new Set();
  let validPhaseCount = 0;
  phases.forEach((row) => {
    const phaseKey = row.phase.trim().toLowerCase();
    if (!phaseKey) schemaFindings.push({ code: 'empty_phase', line: row.line });
    if (!PHASE_STATUSES.has(row.status)) {
      schemaFindings.push({ code: 'unknown_phase_status', phase: row.phase, status: row.status, line: row.line });
    }
    if (phaseKey && seenPhases.has(phaseKey)) {
      schemaFindings.push({ code: 'duplicate_phase', phase: row.phase, line: row.line });
    }
    if (phaseKey) seenPhases.add(phaseKey);
    if (phaseKey && PHASE_STATUSES.has(row.status)) validPhaseCount += 1;
  });
  if (hasPlanStatus && validPhaseCount === 0) schemaFindings.push({ code: 'missing_phase_rows' });

  return {
    hasPlanStatus, phases, schemaFindings, planStatusLine: planStatusLine + 1,
  };
}

function parsePhases(markdown) {
  return parsePlanStatus(markdown).phases;
}

function isParseableIdentifier(value) {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value);
}

function hasValidDeclaredIdentifiers(record, repoRoot) {
  const validOpaqueIdentifiers = ['sourceTreeId', 'bundleId'].every((field) => (
    !Object.prototype.hasOwnProperty.call(record, field) || isParseableIdentifier(record[field])
  ));
  const validSourceCommit = !Object.prototype.hasOwnProperty.call(record, 'sourceCommit')
    || isCurrentHeadAncestor(record.sourceCommit, repoRoot);
  return validOpaqueIdentifiers && validSourceCommit;
}

function hasValidDeclaredStatus(record) {
  return !Object.prototype.hasOwnProperty.call(record, 'status')
    || (typeof record.status === 'string' && REPORT_SUCCESS_STATUSES.has(record.status.trim().toLowerCase()));
}

function isParseableCommand(command) {
  return typeof command === 'string'
    && /^(node|bash|sh|bats|npm|pnpm|yarn|npx)\s+\S+/.test(command.trim());
}

function hasResultSummary(record) {
  const declared = ['result', 'output'].filter((field) => Object.prototype.hasOwnProperty.call(record, field));
  return declared.length > 0 && declared.every((field) => (
    typeof record[field] === 'string' && record[field].trim().length > 0
  ));
}

function hasResultSummaryFields(get) {
  const declared = ['result', 'output'].filter((field) => get(field) !== undefined);
  return declared.length > 0 && declared.every((field) => (
    typeof get(field) === 'string' && get(field).trim().length > 0
  ));
}

function isSuccessfulExit(exit) {
  return exit === 0 || exit === '0';
}

function resolveReportPath(reportPath, repoRoot) {
  if (typeof reportPath !== 'string' || !reportPath.trim() || path.isAbsolute(reportPath.trim())) return null;

  const root = path.resolve(repoRoot);
  const candidate = path.resolve(root, reportPath.trim());
  const relative = path.relative(root, candidate);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return null;

  try {
    const stat = fs.lstatSync(candidate);
    if (!stat.isFile()) return null;
    if (!fs.realpathSync(candidate).startsWith(`${fs.realpathSync(root)}${path.sep}`)) return null;
    return candidate;
  } catch {
    return null;
  }
}

function isValidReport(reportPath, repoRoot) {
  const resolved = resolveReportPath(reportPath, repoRoot);
  if (!resolved) return false;
  if (path.extname(resolved).toLowerCase() !== '.json') return false;

  try {
    const report = JSON.parse(fs.readFileSync(resolved, 'utf8'));
    return report
      && typeof report === 'object'
      && !Array.isArray(report)
      && hasValidDeclaredIdentifiers(report, repoRoot)
      && Object.prototype.hasOwnProperty.call(report, 'status')
      && hasValidDeclaredStatus(report);
  } catch {
    return false;
  }
}

function unwrapCodeSpan(value) {
  const trimmed = value.trim();
  const match = trimmed.match(/^(`+)([\s\S]*?)\1$/);
  return (match ? match[2] : trimmed).trim();
}

function parsePlainEvidenceFields(value) {
  const fields = {};
  let invalid = false;

  value.split(';').forEach((segment) => {
    const trimmed = segment.trim();
    let match = trimmed.match(/^(command|exit|result|output|report|commit)\s*:\s*([\s\S]*)$/i);
    if (!match) {
      match = trimmed.match(/^(?:.*\bvalidation\s*:\s*)(command|report)\s*:\s*([\s\S]*)$/i);
    }
    if (!match) return;

    const key = match[1].toLowerCase();
    const fieldValue = unwrapCodeSpan(match[2]);
    if (Object.prototype.hasOwnProperty.call(fields, key) || !fieldValue) invalid = true;
    fields[key] = fieldValue;
  });

  return { fields, invalid };
}

function parseJsonEvidence(value, repoRoot) {
  try {
    const parsed = JSON.parse(value);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    if (!hasValidDeclaredIdentifiers(parsed, repoRoot) || !hasValidDeclaredStatus(parsed)) return null;
    return parsed;
  } catch {
    return null;
  }
}

function evidenceFields(value, repoRoot) {
  const parsed = parseJsonEvidence(value, repoRoot);
  if (parsed) {
    return {
      commandFields: ['command', 'test', 'testCommand']
        .filter((field) => Object.prototype.hasOwnProperty.call(parsed, field)),
      reportFields: ['report', 'reportPath', 'path']
        .filter((field) => Object.prototype.hasOwnProperty.call(parsed, field)),
      commitFields: ['commit']
        .filter((field) => Object.prototype.hasOwnProperty.call(parsed, field)),
      get: (field) => parsed[field],
    };
  }

  if (/^\s*[{[]/.test(value)) return null;
  const { fields, invalid } = parsePlainEvidenceFields(value);
  if (invalid) return null;
  return {
    commandFields: Object.prototype.hasOwnProperty.call(fields, 'command') ? ['command'] : [],
    reportFields: Object.prototype.hasOwnProperty.call(fields, 'report') ? ['report'] : [],
    commitFields: Object.prototype.hasOwnProperty.call(fields, 'commit') ? ['commit'] : [],
    get: (field) => fields[field],
  };
}

function hasRecognizableEvidence(evidence, repoRoot) {
  const value = evidence.trim();
  if (!value) return false;
  const fields = evidenceFields(value, repoRoot);
  if (!fields) return false;
  if (fields.commandFields.length === 0
    && fields.reportFields.length === 0
    && fields.commitFields.length === 0) return false;
  if (fields.commandFields.length > 0 && !(
    fields.commandFields.every((field) => isParseableCommand(fields.get(field)))
    && isSuccessfulExit(fields.get('exit'))
    && hasResultSummaryFields(fields.get)
  )) return false;
  if (fields.reportFields.length > 0
    && !fields.reportFields.every((field) => isValidReport(fields.get(field), repoRoot))) return false;
  if (fields.commitFields.length > 0
    && !fields.commitFields.every((field) => isCurrentHeadAncestor(fields.get(field), repoRoot))) return false;
  return true;
}

function hasDurableEvidence(evidence, repoRoot) {
  const fields = evidenceFields(evidence.trim(), repoRoot);
  if (!fields) return false;
  return fields.reportFields.some((field) => isValidReport(fields.get(field), repoRoot))
    || fields.commitFields.some((field) => isCurrentHeadAncestor(fields.get(field), repoRoot));
}

function parseTaskCheckboxes(markdown) {
  const lines = stripIgnoredMarkdown(markdown).split(/\r?\n/);
  const tasks = [];
  let current = null;

  function ensureTask(line) {
    if (!current) {
      current = { line, anonymous: true, checkboxes: [], notes: [] };
      tasks.push(current);
    }
    return current;
  }

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const taskHeading = line.match(/^###\s+Task\s+(\d+)\s*:/i);
    if (taskHeading) {
      current = { line: index + 1, task: Number(taskHeading[1]), checkboxes: [], notes: [] };
      tasks.push(current);
      continue;
    }
    if (/^#{1,3}\s+/.test(line)) current = null;

    const checkbox = line.match(/^\s*[-*+]\s+\[([ xX])\]\s+(.+)$/);
    if (checkbox) {
      ensureTask(index + 1).checkboxes.push({ line: index + 1, checked: checkbox[1].toLowerCase() === 'x', text: checkbox[2] });
    }
    if (/\bCompleted by\b/i.test(line) && current && !current.anonymous) current.notes.push(line.trim());
  }

  return tasks;
}

function extractCompletedByCommit(note) {
  const completedBy = note.match(/\bCompleted by\b/i);
  if (!completedBy) return '';
  const hash = note.slice(completedBy.index + completedBy[0].length)
    .match(/(?:^|[^0-9a-f])([0-9a-f]{7,40})(?![0-9a-f])/i);
  return hash ? hash[1] : '';
}

function isExistingCommit(commit, repoRoot) {
  if (!/^[0-9a-f]{7,40}$/i.test(commit)) return false;
  try {
    const resolved = execFileSync(
      'git',
      ['-C', path.resolve(repoRoot), 'rev-parse', '--verify', `${commit}^{commit}`],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim();
    if (!/^[0-9a-f]{40}$/i.test(resolved)) return false;
    execFileSync(
      'git',
      ['-C', path.resolve(repoRoot), 'cat-file', '-e', `${resolved}^{commit}`],
      { stdio: 'ignore' },
    );
    execFileSync(
      'git',
      ['-C', path.resolve(repoRoot), 'merge-base', '--is-ancestor', resolved, 'HEAD'],
      { stdio: 'ignore' },
    );
    return true;
  } catch {
    return false;
  }
}

function isCurrentHeadAncestor(commit, repoRoot) {
  return typeof commit === 'string' && isExistingCommit(commit.trim(), repoRoot);
}

function hasTaskCompletionNote(task, repoRoot) {
  return task.notes.some((note) => {
    const commit = extractCompletedByCommit(note);
    const parsed = parsePlainEvidenceFields(note);
    const declaresEvidence = Object.keys(parsed.fields).length > 0;
    return isCurrentHeadAncestor(commit, repoRoot)
      && !parsed.invalid
      && (!declaresEvidence || hasRecognizableEvidence(note, repoRoot));
  });
}

function validatePhase(row, repoRoot) {
  const findings = [];
  if (EVIDENCE_REQUIRED.has(row.status)) {
    if (!row.evidence.trim()) findings.push({ code: 'missing_phase_evidence', phase: row.phase });
    else if (!hasRecognizableEvidence(row.evidence, repoRoot)
      || !hasDurableEvidence(row.evidence, repoRoot)) {
      findings.push({ code: 'invalid_phase_evidence', phase: row.phase });
    }
  }
  if (!NEXT_NOT_REQUIRED.has(row.status) && !row.next.trim()) {
    findings.push({ code: 'missing_phase_next', phase: row.phase });
  }
  return findings;
}

function validatePlan(markdown, repoRoot = path.resolve(__dirname, '..')) {
  const {
    hasPlanStatus, phases, schemaFindings, planStatusLine,
  } = parsePlanStatus(markdown);
  const tasks = parseTaskCheckboxes(markdown);
  const topLevelHeadings = parseTopLevelHeadings(markdown);
  const setextTopLevelHeadings = parseSetextTopLevelHeadings(markdown);
  const findings = hasPlanStatus
    ? [...schemaFindings, ...phases.flatMap((phase) => validatePhase(phase, repoRoot))]
    : [{ code: 'missing_plan_status' }];
  if (topLevelHeadings.length === 0) findings.push({ code: 'missing_top_level_heading' });
  findings.push(...topLevelHeadings.slice(1)
    .map((heading) => ({ code: 'unexpected_top_level_heading', line: heading.line, heading: heading.text })));
  findings.push(...setextTopLevelHeadings
    .map((heading) => ({ code: 'setext_top_level_heading', line: heading.line, heading: heading.text })));
  if (planStatusLine !== -1 && topLevelHeadings[0] && topLevelHeadings[0].line > planStatusLine) {
    findings.push({
      code: 'plan_status_before_top_level_heading',
      line: planStatusLine,
      headingLine: topLevelHeadings[0].line,
    });
  }
  const anonymousCompletedTasks = tasks.filter((task) => task.anonymous).flatMap((task) => task.checkboxes
    .filter((checkbox) => checkbox.checked)
    .map((checkbox) => ({ code: 'anonymous_completed_task', line: checkbox.line })));
  findings.push(...anonymousCompletedTasks);
  const missingCheckboxEvidence = tasks.filter((task) => !task.anonymous).flatMap((task) => task.checkboxes
    .filter((checkbox) => checkbox.checked && !hasTaskCompletionNote(task, repoRoot))
    .map((checkbox) => ({ code: 'missing_checkbox_evidence', line: checkbox.line, taskLine: task.line })));
  findings.push(...missingCheckboxEvidence);

  return {
    status: findings.length ? 'fail' : 'pass',
    findings,
    phases,
    missingEvidence: findings.filter((finding) => /phase_evidence$/.test(finding.code)),
    missingNext: findings.filter((finding) => finding.code === 'missing_phase_next'),
    missingCheckboxEvidence,
    anonymousCompletedTasks,
    missingPlanStatus: findings.filter((finding) => finding.code === 'missing_plan_status'),
    missingPhaseRows: findings.filter((finding) => finding.code === 'missing_phase_rows'),
    missingTopLevelHeadings: findings.filter((finding) => finding.code === 'missing_top_level_heading'),
    unexpectedTopLevelHeadings: findings.filter((finding) => finding.code === 'unexpected_top_level_heading'),
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.plan || !args.json) {
    process.stderr.write('Usage: node scripts/plan-evidence-check.js --plan <file> --json\n');
    process.exitCode = 2;
    return;
  }

  try {
    const result = validatePlan(fs.readFileSync(args.plan, 'utf8'), args.repoRoot);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'pass') process.exitCode = 1;
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 2;
  }
}

if (require.main === module) main();

module.exports = {
  hasRecognizableEvidence,
  parsePhases,
  parseTaskCheckboxes,
  resolveReportPath,
  stripIgnoredMarkdown,
  validatePhase,
  validatePlan,
};
