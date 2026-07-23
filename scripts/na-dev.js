#!/usr/bin/env node
const { spawnSync } = require('child_process');
const path = require('path');

const USAGE = `Usage: node scripts/na-dev.js <command> [args...]

Maintainer command facade for novel-assistant-skill. It keeps old script paths
stable while giving maintainers one place to run common workflows.

Commands:
  verify              Run the default local verification suite
  smoke [args...]     Run production-smoke-matrix.js
  audit [args...]     Run maintainability-audit.js
  release-audit       Run public-release-audit.js against the current branch
  release-status      Show local/public/GitHub release branch status
  prepare-public      Rebuild and audit the GitHub public release branch
  publish-public      Create/update sanitized GitHub public branch in a worktree
  static              Run static-check.sh
  bundle              Rebuild novel-assistant and oh-story bundles
  install-local-private
                      Build and install the local private bundle to Claude/Codex/zcode
  upstream [args...]  Run check-upstream.sh
  reference-watch     Watch non-upstream inspiration projects and write research reports
  short-write-sync    Sync public story-short-write and private absorbed method pack
  host-discovery      Validate one host's read-only skill discovery contract
  skill-policy        Validate top-level skills/ directory roles
  panlong [args...]   Compare Panlong benchmark candidate with demo baseline
  behavior-eval [args...]
                      Compatibility alias for behavior-eval-plan
  behavior-eval-plan [args...]
                      Create a behavior-evaluation dry-run plan; never starts a host
  behavior-eval-run [args...]
                      Run explicit paid behavior evaluation; requires --execute-paid and confirmation
  supervisor [args...] Run the opt-in workflow supervisor; it never changes host permissions
  test [args...]      Run run-bats-tests.sh
  help                Show this help
`;

const repoRoot = path.resolve(__dirname, '..');
const localPrivateInstallTargets = [
  path.join(process.env.HOME || '', '.claude', 'skills', 'novel-assistant'),
  path.join(process.env.HOME || '', '.codex', 'skills', 'novel-assistant'),
  path.join(process.env.HOME || '', '.zcode', 'skills', 'novel-assistant')
];

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    stdio: 'inherit',
    shell: false,
    env: options.env || process.env
  });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  if (result.status !== 0) process.exit(result.status || 1);
}

function runMany(steps) {
  for (const [command, args, options] of steps) run(command, args, options || {});
}

function installLocalPrivate() {
  run('bash', ['scripts/build-oh-story-bundle.sh'], {
    env: {
      ...process.env,
      NOVEL_ASSISTANT_INCLUDE_PRIVATE: '1'
    }
  });

  for (const target of localPrivateInstallTargets) {
    run('mkdir', ['-p', path.dirname(target)]);
    run('rsync', ['-a', '--delete', 'skills/novel-assistant/', `${target}/`]);
  }

  run('node', ['-e', `
const fs = require('fs');
const path = require('path');
const targets = ${JSON.stringify(localPrivateInstallTargets)};
for (const target of targets) {
  const manifestPath = path.join(target, 'novel-assistant-manifest.json');
  if (!fs.existsSync(manifestPath)) throw new Error('missing manifest: ' + manifestPath);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (Number(manifest.privateInternalSkillCount || 0) < 1) {
    throw new Error('local private install missing private internal skills: ' + target);
  }
  const privateRoot = path.join(target, 'references', 'private-internal-skills');
  if (!fs.existsSync(privateRoot)) throw new Error('missing private internal skill root: ' + privateRoot);
  const workflow = require('child_process').spawnSync('node', ['scripts/workflow-state-machine.js', 'templates', '--json'], {cwd: target, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024});
  if (workflow.status !== 0) throw new Error(workflow.stderr || workflow.stdout || 'workflow template check failed');
  const parsed = JSON.parse(workflow.stdout);
  if (Number(parsed.privateRegistryCount || 0) < 1) throw new Error('private registry not loaded: ' + target);
  if (!(parsed.templates || []).some((item) => item.workflow_type === 'private_short_startup')) {
    throw new Error('private short startup workflow missing: ' + target);
  }
}
console.log('local private novel-assistant install verified:', targets.join(', '));
`]);
}

const [command, ...args] = process.argv.slice(2);

switch (command || 'help') {
  case 'verify':
    runMany([
      ['bash', ['scripts/run-bats-lite.sh',
        'tests/test-repo-docs-cleanup.bats',
        'tests/test-readme-longform-release.bats',
        'tests/test-production-smoke-matrix.bats',
        'tests/test-maintainability-kernel.bats',
        'tests/test-github-release-tooling.bats',
        'tests/test-oh-story-bundle.bats',
        'tests/test-entry-runtime-contract-index.bats',
        'tests/test-release-status.bats',
        'tests/test-workflow-entry-guard.bats',
        'tests/test-workflow-entry-guard-setup.bats',
        'tests/test-workflow-recovery.bats',
        'tests/test-workflow-state-invariants.bats',
        'tests/test-workflow-review-batches.bats',
        'tests/test-story-memory-migration.bats'
      ]],
      ['node', ['scripts/production-smoke-matrix.js', '--repo-root', '.', '--json']],
      ['node', ['scripts/maintainability-audit.js', '--repo-root', '.', '--json']],
      ['node', ['scripts/check-skill-directory-policy.js', '--repo-root', '.', '--json']],
      ['bash', ['scripts/static-check.sh']],
      ['git', ['diff', '--check']]
    ]);
    break;
  case 'smoke':
    run('node', ['scripts/production-smoke-matrix.js', ...args]);
    break;
  case 'audit':
    run('node', ['scripts/maintainability-audit.js', ...args]);
    break;
  case 'release-audit':
    run('node', ['scripts/public-release-audit.js', '--repo-root', '.', ...args]);
    break;
  case 'release-status':
    run('node', ['scripts/release-status.js', '--repo-root', '.', ...args]);
    break;
  case 'prepare-public':
    run('bash', ['scripts/prepare-github-public-release.sh', ...args]);
    break;
  case 'publish-public':
    run('bash', ['scripts/publish-github-public-branch.sh', ...args]);
    break;
  case 'static':
    run('bash', ['scripts/static-check.sh']);
    break;
  case 'bundle':
    run('bash', ['scripts/build-oh-story-bundle.sh']);
    break;
  case 'install-local-private':
    installLocalPrivate();
    break;
  case 'upstream':
    run('bash', ['scripts/check-upstream.sh', ...args]);
    break;
  case 'reference-watch':
    run('node', ['scripts/reference-project-watch.js', ...args]);
    break;
  case 'short-write-sync':
    run('node', ['scripts/sync-private-short-write-absorption.js', ...args]);
    break;
  case 'host-discovery':
    run('node', ['scripts/check-host-skill-discovery.js', ...args]);
    break;
  case 'skill-policy':
    run('node', ['scripts/check-skill-directory-policy.js', '--repo-root', '.', ...args]);
    break;
  case 'panlong':
    run('node', ['scripts/panlong-benchmark-compare.js', '--repo-root', '.', ...args]);
    break;
  case 'behavior-eval':
  case 'behavior-eval-plan':
    run('node', ['scripts/behavior-eval.js', 'plan', ...args]);
    break;
  case 'behavior-eval-run':
    run('node', ['scripts/behavior-eval.js', 'run', ...args]);
    break;
  case 'supervisor':
    run('node', ['scripts/workflow-supervisor.js', ...args]);
    break;
  case 'test':
    run('bash', ['scripts/run-bats-tests.sh', ...args]);
    break;
  case 'help':
  case '--help':
  case '-h':
    process.stdout.write(USAGE);
    break;
  default:
    console.error(`Unknown command: ${command}\n`);
    process.stderr.write(USAGE);
    process.exit(2);
}
