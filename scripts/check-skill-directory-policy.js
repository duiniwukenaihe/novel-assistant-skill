#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node scripts/check-skill-directory-policy.js [--repo-root <dir>] [--json]

Validates novel-assistant repository skill layout:
  - skills/ top level must contain only novel-assistant
  - novel-assistant: only recommended user install target
  - src/internal-skills: canonical source modules consumed by bundle build
  - src/private-internal-skills: optional private internal modules for local/internal bundles only
  - skills/novel-assistant/references/internal-skills: generated runtime copies
`;

const EXPECTED = {
  installable: ['novel-assistant'],
  internalSource: [
    'browser-cdp',
    'story',
    'story-cover',
    'story-deslop',
    'story-import',
    'story-long-analyze',
    'story-long-scan',
    'story-long-write',
    'story-memory',
    'story-review',
    'story-setup',
    'story-short-analyze',
    'story-short-scan',
    'story-short-write',
    'story-workflow'
  ]
};

function parseArgs(argv) {
  const out = { repoRoot: process.cwd(), json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--repo-root') {
      out.repoRoot = path.resolve(argv[++i] || '');
    } else if (arg === '--json') {
      out.json = true;
    } else if (arg === '--help' || arg === '-h') {
      process.stdout.write(USAGE);
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return out;
}

function readSkillDirs(repoRoot) {
  const skillsDir = path.join(repoRoot, 'skills');
  return fs.readdirSync(skillsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => fs.existsSync(path.join(skillsDir, name, 'SKILL.md')))
    .sort();
}

function readInternalSourceDirs(repoRoot) {
  const sourceDir = path.join(repoRoot, 'src', 'internal-skills');
  if (!fs.existsSync(sourceDir)) return [];
  return fs.readdirSync(sourceDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => fs.existsSync(path.join(sourceDir, name, 'SKILL.md')))
    .sort();
}

function readPrivateInternalSourceDirs(repoRoot) {
  const sourceDir = path.join(repoRoot, 'src', 'private-internal-skills');
  if (!fs.existsSync(sourceDir)) return [];
  return fs.readdirSync(sourceDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => fs.existsSync(path.join(sourceDir, name, 'SKILL.md')))
    .sort();
}

function checkDocs(repoRoot, findings) {
  const docs = [
    ['README.md', ['skills/novel-assistant', 'src/internal-skills', '不要直接调用 /story-long-write']],
    ['docs/skill-directory-policy.md', [
      'only recommended user install target',
      'src/internal-skills',
      'skills/ top level must contain only novel-assistant'
    ]],
    ['docs/scripts-map.md', ['src/internal-skills']]
  ];
  for (const [rel, anchors] of docs) {
    const file = path.join(repoRoot, rel);
    const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
    for (const anchor of anchors) {
      if (!text.includes(anchor)) findings.push({ id: 'missing_doc_anchor', file: rel, anchor });
    }
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const dirs = readSkillDirs(args.repoRoot);
  const sourceDirs = readInternalSourceDirs(args.repoRoot);
  const privateSourceDirs = readPrivateInternalSourceDirs(args.repoRoot);
  const findings = [];

  for (const dir of dirs) {
    if (!EXPECTED.installable.includes(dir)) findings.push({ id: 'unexpected_skill_dir', dir });
  }
  for (const dir of EXPECTED.installable) {
    if (!dirs.includes(dir)) findings.push({ id: 'missing_installable_skill_dir', dir });
  }
  for (const dir of EXPECTED.internalSource) {
    if (!sourceDirs.includes(dir)) findings.push({ id: 'missing_internal_source_dir', dir });
  }
  checkDocs(args.repoRoot, findings);

  const result = {
    schemaVersion: '1.0.0',
    status: findings.length ? 'fail' : 'pass',
    topLevelPolicy: 'novel-assistant-only',
    repoRoot: args.repoRoot,
    roles: EXPECTED,
    detected: dirs.map((dir) => ({ dir, role: EXPECTED.installable.includes(dir) ? 'installable' : 'unexpected' })),
    internalSourceDetected: sourceDirs.map((dir) => ({ dir, role: EXPECTED.internalSource.includes(dir) ? 'internalSource' : 'unexpected' })),
    privateInternalSourceDetected: privateSourceDirs.map((dir) => ({ dir, role: 'privateInternalSource' })),
    findings
  };

  if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else if (findings.length) {
    console.error('Skill directory policy failed:');
    for (const finding of findings) console.error(`- ${JSON.stringify(finding)}`);
  } else {
    console.log('Skill directory policy: pass');
  }

  process.exit(findings.length ? 1 : 0);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
