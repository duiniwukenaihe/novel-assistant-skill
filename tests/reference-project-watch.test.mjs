import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const repo = path.resolve(new URL('..', import.meta.url).pathname)
const script = path.join(repo, 'scripts/reference-project-watch.js')

function run(command, args, cwd) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'Novel Assistant Test',
      GIT_AUTHOR_EMAIL: 'test@example.com',
      GIT_COMMITTER_NAME: 'Novel Assistant Test',
      GIT_COMMITTER_EMAIL: 'test@example.com',
    },
  })
  assert.equal(result.status, 0, result.stderr || result.stdout)
  return result.stdout.trim()
}

function makeGitRepo(root) {
  run('git', ['init', '-q', '-b', 'main'], root)
  writeFileSync(path.join(root, 'README.md'), '# fixture\n', 'utf8')
  run('git', ['add', 'README.md'], root)
  run('git', ['commit', '-q', '-m', 'initial'], root)
  const first = run('git', ['rev-parse', 'HEAD'], root)
  writeFileSync(path.join(root, 'README.md'), '# fixture\n\nsecond\n', 'utf8')
  run('git', ['add', 'README.md'], root)
  run('git', ['commit', '-q', '-m', 'feat: second'], root)
  const second = run('git', ['rev-parse', 'HEAD'], root)
  return { first, second }
}

function makeMasterGitRepo(root) {
  run('git', ['init', '-q', '-b', 'master'], root)
  writeFileSync(path.join(root, 'README.md'), '# master fixture\n', 'utf8')
  run('git', ['add', 'README.md'], root)
  run('git', ['commit', '-q', '-m', 'initial master'], root)
  return run('git', ['rev-parse', 'HEAD'], root)
}

test('reference project watch reports changed non-upstream projects without treating them as primary upstream', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-'))
  try {
    const remote = path.join(root, 'remote')
    const reportDir = path.join(root, 'reports')
    const registry = path.join(root, 'registry.json')
    run('mkdir', ['-p', remote], root)
    const commits = makeGitRepo(remote)

    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.0.0',
      policy: {
        primaryUpstream: 'worldwonderer/oh-story-claudecode',
        referenceCadence: 'weekly-or-manual',
      },
      projects: [
        {
          id: 'fixture-webnovel',
          name: 'Fixture Webnovel',
          repo: remote,
          branch: 'main',
          priority: 'reference',
          cadenceDays: 14,
          license: 'GPL-3.0',
          absorbMode: 'clean-room-design-only',
          focusAreas: ['chapter_commit', 'workflow_memory'],
          lastReviewedCommit: commits.first,
        },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--report-dir',
      reportDir,
      '--write',
      '--json',
    ], { encoding: 'utf8', timeout: 10000 })

    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.status, 'ok')
    assert.equal(parsed.summary.changed, 1)
    assert.equal(parsed.summary.primaryUpstream, 'worldwonderer/oh-story-claudecode')
    assert.equal(parsed.projects[0].status, 'changed')
    assert.equal(parsed.projects[0].head, commits.second)
    assert.equal(parsed.projects[0].absorbMode, 'clean-room-design-only')
    assert.equal(parsed.projects[0].recommendedAction, 'research_report_then_clean_room_triage')

    const report = readFileSync(parsed.reportPath, 'utf8')
    assert.match(report, /参考项目观察报告/)
    assert.match(report, /主上游仍优先/)
    assert.match(report, /Fixture Webnovel/)
    assert.match(report, /clean-room-design-only/)
    assert.match(report, /不 merge、不 cherry-pick/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('na-dev exposes reference-watch as a maintainer command', () => {
  const help = spawnSync(process.execPath, [path.join(repo, 'scripts/na-dev.js'), 'help'], {
    encoding: 'utf8',
    timeout: 5000,
  })
  assert.equal(help.status, 0, help.stderr || help.stdout)
  assert.match(help.stdout, /reference-watch/)
})

test('reference project watch falls back to remote HEAD when configured branch is missing', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-head-'))
  try {
    const remote = path.join(root, 'remote')
    const registry = path.join(root, 'registry.json')
    run('mkdir', ['-p', remote], root)
    const head = makeMasterGitRepo(remote)
    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.0.0',
      policy: { primaryUpstream: 'worldwonderer/oh-story-claudecode' },
      projects: [
        {
          id: 'master-only',
          name: 'Master Only',
          repo: remote,
          branch: 'main',
          priority: 'reference-low',
          cadenceDays: 90,
          license: 'unknown-check-before-use',
          absorbMode: 'prompt-pattern-review',
          focusAreas: ['skill_packaging'],
        },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--json',
    ], { encoding: 'utf8', timeout: 10000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.summary.error, 0)
    assert.equal(parsed.projects[0].head, head)
    assert.equal(parsed.projects[0].branchResolvedFromHead, true)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('reference project watch treats lastObservedCommit as a baseline without implying review', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-observed-'))
  try {
    const remote = path.join(root, 'remote')
    const registry = path.join(root, 'registry.json')
    run('mkdir', ['-p', remote], root)
    const commits = makeGitRepo(remote)
    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.0.0',
      policy: { primaryUpstream: 'worldwonderer/oh-story-claudecode' },
      projects: [
        {
          id: 'observed',
          name: 'Observed Only',
          repo: remote,
          branch: 'main',
          priority: 'reference-low',
          cadenceDays: 90,
          license: 'unknown-check-before-use',
          absorbMode: 'prompt-pattern-review',
          focusAreas: ['workflow'],
          lastObservedCommit: commits.second,
        },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--json',
    ], { encoding: 'utf8', timeout: 10000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.projects[0].status, 'current')
    assert.equal(parsed.projects[0].lastObservedCommit, commits.second)
    assert.equal(parsed.projects[0].lastReviewedCommit, '')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('reference project watch records latest tags and avoids deep triage when only unreleased HEAD changes', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-tags-'))
  try {
    const remote = path.join(root, 'remote')
    const registry = path.join(root, 'registry.json')
    run('mkdir', ['-p', remote], root)
    const commits = makeGitRepo(remote)
    run('git', ['tag', 'v1.0.0', commits.first], remote)
    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.1.0',
      policy: { primaryUpstream: 'worldwonderer/oh-story-claudecode' },
      projects: [
        {
          id: 'tagged',
          name: 'Tagged Project',
          repo: remote,
          branch: 'main',
          priority: 'reference-high',
          cadenceDays: 30,
          license: 'GPL-3.0',
          absorbMode: 'clean-room-design-only',
          focusAreas: ['workflow'],
          lastObservedCommit: commits.first,
          lastObservedTag: 'v1.0.0',
        },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--json',
    ], { encoding: 'utf8', timeout: 10000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.projects[0].status, 'changed')
    assert.equal(parsed.projects[0].headStatus, 'changed')
    assert.equal(parsed.projects[0].latestTag, 'v1.0.0')
    assert.equal(parsed.projects[0].tagStatus, 'current')
    assert.equal(parsed.projects[0].recommendedAction, 'light_commit_log_only_until_tag_changes')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('reference project watch escalates when latest tag changes', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-tag-change-'))
  try {
    const remote = path.join(root, 'remote')
    const registry = path.join(root, 'registry.json')
    run('mkdir', ['-p', remote], root)
    const commits = makeGitRepo(remote)
    run('git', ['tag', 'v1.0.0', commits.first], remote)
    run('git', ['tag', 'v1.1.0', commits.second], remote)
    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.1.0',
      policy: { primaryUpstream: 'worldwonderer/oh-story-claudecode' },
      projects: [
        {
          id: 'tagged-release',
          name: 'Tagged Release Project',
          repo: remote,
          branch: 'main',
          priority: 'reference-high',
          cadenceDays: 30,
          license: 'GPL-3.0',
          absorbMode: 'clean-room-design-only',
          focusAreas: ['workflow'],
          lastObservedCommit: commits.first,
          lastObservedTag: 'v1.0.0',
        },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--json',
    ], { encoding: 'utf8', timeout: 10000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.projects[0].status, 'changed')
    assert.equal(parsed.projects[0].headStatus, 'changed')
    assert.equal(parsed.projects[0].latestTag, 'v1.1.0')
    assert.equal(parsed.projects[0].tagStatus, 'changed')
    assert.equal(parsed.projects[0].recommendedAction, 'tag_changed_research_report_then_triage')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('reference project watch includes manual knowledge and data sources without git inspection', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-sources-'))
  try {
    const registry = path.join(root, 'registry.json')
    const reportDir = path.join(root, 'reports')
    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.1.0',
      policy: { primaryUpstream: 'worldwonderer/oh-story-claudecode' },
      projects: [],
      knowledgeSources: [
        {
          id: 'sillytavern-lorebook',
          name: 'SillyTavern World Info / Lorebook',
          type: 'conceptual',
          source: 'https://docs.sillytavern.app/',
          watchMode: 'manual',
          priority: 'reference-medium',
          focusAreas: ['dynamic_context', 'memory_activation'],
          notes: 'Design reference only.',
        },
      ],
      dataSources: [
        {
          id: 'wangwen-debut',
          name: '网文大数据 · 番茄首秀',
          type: 'market-data',
          source: 'https://www.wangwendashuju.com/fq/debut',
          watchMode: 'domain-script',
          priority: 'reference-high',
          focusAreas: ['ranking_metrics', 'book_id'],
        },
      ],
      excludedSources: [
        {
          id: 'private-shortform',
          name: 'Private shortform assets',
          reason: 'private-not-for-github-release',
        },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--report-dir',
      reportDir,
      '--write',
      '--json',
    ], { encoding: 'utf8', timeout: 10000 })

    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.summary.total, 0)
    assert.equal(parsed.sourceSummary.knowledgeSources, 1)
    assert.equal(parsed.sourceSummary.dataSources, 1)
    assert.equal(parsed.sourceSummary.excludedSources, 1)

    const report = readFileSync(parsed.reportPath, 'utf8')
    assert.match(report, /Manual Knowledge Sources/)
    assert.match(report, /SillyTavern World Info/)
    assert.match(report, /Data Sources/)
    assert.match(report, /网文大数据/)
    assert.match(report, /Excluded \/ Special Sources/)
    assert.match(report, /private-not-for-github-release/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('reference project watch checks distribution mirrors only when explicitly requested', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-skills-'))
  try {
    const registry = path.join(root, 'registry.json')
    const reportDir = path.join(root, 'reports')
    const versions = encodeURIComponent(JSON.stringify({
      versions: [
        { version: '1.0.0' },
        { version: '1.1.0' },
      ],
    }))
    const artifact = encodeURIComponent('---\nname: fixture-skill\nversion: "1.0.0"\n---\n# Fixture\n')
    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.2.0',
      policy: { primaryUpstream: 'worldwonderer/oh-story-claudecode' },
      projects: [],
      skillSources: [
        {
          id: 'fixture-skillhub',
          name: 'Fixture SkillHub distribution',
          slug: 'fixture-skill',
          canonicalName: '@fixture/fixture-skill',
          versionsApi: `data:application/json,${versions}`,
          skillFileApi: `data:text/plain,${artifact}`,
          sourceRepo: 'https://github.com/example/fixture',
          sourceRepoVerified: true,
          artifactRelation: 'release-mirror',
          lastObservedVersion: '1.0.0',
          lastObservedArtifactSha256: 'old-artifact',
          focusAreas: ['outline_adapter'],
        },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--report-dir',
      reportDir,
      '--write',
      '--json',
      '--include-distribution-mirrors',
    ], { encoding: 'utf8', timeout: 10000 })

    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.sourceSummary.skillSources, 1)
    assert.equal(parsed.sourceSummary.changedSkillSources, 1)
    assert.equal(parsed.sourceSummary.skillSourceErrors, 0)
    assert.equal(parsed.skillSources[0].latestVersion, '1.1.0')
    assert.equal(parsed.skillSources[0].declaredVersion, '1.0.0')
    assert.equal(parsed.skillSources[0].versionStatus, 'changed')
    assert.equal(parsed.skillSources[0].artifactStatus, 'changed')
    assert.match(parsed.skillSources[0].artifactSha256, /^[0-9a-f]{64}$/)
    assert.deepEqual(parsed.skillSources[0].warnings, ['catalog_version_differs_from_artifact'])
    assert.equal(parsed.skillSources[0].trustStatus, 'quarantined')
    assert.equal(parsed.skillSources[0].recommendedAction, 'quarantine_distribution_use_verified_source_repo_only')

    const report = readFileSync(parsed.reportPath, 'utf8')
    assert.match(report, /Secondary Distribution Mirror Diagnostics/)
    assert.match(report, /fixture-skill/)
    assert.match(report, /catalog_version_differs_from_artifact/)
    assert.match(report, /quarantined/)
    assert.match(report, /release-mirror/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('reference project watch quarantines mutable artifacts published under an unchanged mirror version', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'reference-project-watch-mutable-mirror-'))
  try {
    const registry = path.join(root, 'registry.json')
    const versions = encodeURIComponent(JSON.stringify({ versions: [{ version: '1.1.0' }] }))
    const artifact = encodeURIComponent('---\nname: fixture-skill\nversion: "1.1.0"\n---\n# Mutated\n')
    writeFileSync(registry, JSON.stringify({
      schemaVersion: '1.2.0',
      policy: { primaryUpstream: 'worldwonderer/oh-story-claudecode' },
      projects: [],
      skillSources: [{
        id: 'mutable-mirror',
        name: 'Mutable mirror',
        slug: 'fixture-skill',
        versionsApi: `data:application/json,${versions}`,
        skillFileApi: `data:text/plain,${artifact}`,
        sourceRepoVerified: true,
        lastObservedVersion: '1.1.0',
        lastObservedArtifactSha256: 'old-artifact',
      }],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--registry',
      registry,
      '--json',
      '--include-distribution-mirrors',
    ], { encoding: 'utf8', timeout: 10000 })

    assert.equal(result.status, 0, result.stderr || result.stdout)
    const mirror = JSON.parse(result.stdout).skillSources[0]
    assert.equal(mirror.versionStatus, 'current')
    assert.equal(mirror.artifactStatus, 'changed')
    assert.deepEqual(mirror.warnings, ['immutable_version_artifact_changed'])
    assert.equal(mirror.trustStatus, 'quarantined')
    assert.equal(mirror.recommendedAction, 'quarantine_distribution_use_verified_source_repo_only')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('review workflow sources keep low-frequency GitHub baselines and Spec Kit as a manual knowledge source', () => {
  const registry = JSON.parse(readFileSync(path.join(repo, 'docs/reference-projects.json'), 'utf8'))
  const expectedProjects = {
    'edwardathomson-novelwriter': ['scene_chapter_batch_review', 'quality_trend'],
    'make-ur-agent-writer': ['mock_first', 'fail_closed_review', 'cost_budget', 'detached_resume'],
    inkos: ['audit_dimensions', 'bounded_revision', 'snapshot_lock', 'structured_delta'],
    novelclaw: ['dynamic_memory', 'longform_continuity'],
  }

  for (const [id, focusAreas] of Object.entries(expectedProjects)) {
    const project = registry.projects.find((candidate) => candidate.id === id)
    assert.ok(project, `missing review workflow project: ${id}`)
    assert.match(project.priority, /^reference-/)
    assert.ok(project.license)
    assert.ok(project.absorbMode)
    assert.deepEqual(project.focusAreas, focusAreas)
    assert.match(project.lastObservedCommit, /^[0-9a-f]{40}$/)
  }

  assert.equal(registry.projects.some((project) => project.id === 'spec-kit-fiction'), false)
  const specKitFiction = registry.knowledgeSources.find((source) => source.id === 'spec-kit-fiction')
  assert.ok(specKitFiction, 'missing Spec Kit Fiction knowledge source')
  assert.equal(specKitFiction.type, 'conceptual')
  assert.equal(specKitFiction.watchMode, 'manual')
  assert.deepEqual(specKitFiction.focusAreas, ['pre_draft_analysis', 'post_draft_continuity', 'surgical_revision'])
})
