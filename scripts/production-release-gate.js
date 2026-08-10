#!/usr/bin/env node
'use strict';

// scripts/production-release-gate.js
//
// Combined production release gate. Aggregates six required gates and only
// marks a release as ready when every gate is in the pass state. A candidate
// bundle that looks content-ready still gets blocked if any of the six
// required gates is missing or failed.
//
// Required gates (in declaration order):
//   1. deterministic_core   — focused deterministic test pass
//   2. behavior_eval        — current bundle's behavior eval evidence pass
//   3. bundle_current       — bundle manifest content identity matches the
//                              current source tree
//   4. public_tree_audit    — sanitized public tree passes public-release-audit
//   5. public_behavior_eval — public bundle's behavior eval evidence pass
//                              (subset/contract checks against sanitized worktree)
//   6. install_consistency  — required install hosts (Claude/Codex/ZCode) see
//                              a manifest consistent with the candidate bundle
//
// CLI:
//   node scripts/production-release-gate.js [--repo-root PATH] [--json]
//                                            [--profile local-private|public]
//
// Exit codes:
//   0 — every required gate is pass
//   1 — at least one required gate is blocked
//   2 — invocation error / missing dependency
//
// Backwards compatibility:
//   release-status.js, publish-github-public-branch.sh and the GitHub workflow
//   all use this single gate so a "candidate ready" verdict cannot leak past
//   a blocked behavior, public tree, or install consistency check.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const crypto = require('crypto');

const SCHEMA_VERSION = '1.0.0';

const REQUIRED_GATES = Object.freeze([
  'deterministic_core',
  'behavior_eval',
  'bundle_current',
  'public_tree_audit',
  'public_behavior_eval',
  'install_consistency',
]);

const REQUIRED_PUBLIC_BEHAVIOR_SCENARIOS = Object.freeze([
  'route-single-entry',
  'write-only-section-6',
  'review-1-200',
  'deconstruction-health-stop',
  'review-repair-staged-gate',
  'chapter-commit-conflict',
]);
const PUBLIC_CANDIDATE_MANIFEST = 'config/github-public-release-candidate-manifest.json';
const PRODUCTION_RELEASE_RECEIPT = 'reports/private/production-repair/latest/production-release-gate.json';

function parseArgs(argv) {
  const args = {
    repoRoot: process.cwd(),
    profile: 'local-private',
    evidenceRoot: '',
    publicEvidenceRoot: '',
    publicRoot: '',
    installRoot: '',
    json: false,
    receiptOut: '',
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--repo-root') args.repoRoot = path.resolve(argv[++i] || '');
    else if (arg === '--profile') args.profile = String(argv[++i] || 'local-private');
    else if (arg === '--evidence-root') {
      const value = argv[++i];
      if (!value) throw new Error('--evidence-root requires a value');
      args.evidenceRoot = path.resolve(value);
    } else if (arg === '--install-root') {
      const value = argv[++i];
      if (!value) throw new Error('--install-root requires a value');
      args.installRoot = path.resolve(value);
    } else if (arg === '--public-root') {
      const value = argv[++i];
      if (!value) throw new Error('--public-root requires a value');
      args.publicRoot = path.resolve(value);
    } else if (arg === '--public-evidence-root') {
      const value = argv[++i];
      if (!value) throw new Error('--public-evidence-root requires a value');
      args.publicEvidenceRoot = path.resolve(value);
    }
    else if (arg === '--json') args.json = true;
    else if (arg === '--receipt-out') {
      const value = argv[++i];
      if (!value) throw new Error('--receipt-out requires a value');
      args.receiptOut = path.resolve(value);
    }
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!['local-private', 'public'].includes(args.profile)) {
    throw new Error(`unknown profile: ${args.profile}`);
  }
  return args;
}

function readProductionReleaseReceipt(repoRoot) {
  const receiptPath = path.join(repoRoot, PRODUCTION_RELEASE_RECEIPT);
  const receipt = readJsonSafe(receiptPath);
  if (!receipt) {
    return {
      status: 'blocked',
      release_ready: false,
      reason: 'missing_production_release_receipt',
      receipt: PRODUCTION_RELEASE_RECEIPT,
    };
  }
  const validation = validateProductionReleaseReceipt(receipt);
  if (!validation.ok) {
    return {
      status: 'blocked',
      release_ready: false,
      reason: 'invalid_production_release_receipt',
      receipt: PRODUCTION_RELEASE_RECEIPT,
      findings: validation.findings,
    };
  }
  return { ...receipt, receipt: PRODUCTION_RELEASE_RECEIPT };
}

function validateProductionReleaseReceipt(receipt) {
  const findings = [];
  if (!receipt || typeof receipt !== 'object') findings.push({ id: 'receipt_not_object' });
  if (receipt && receipt.schemaVersion !== SCHEMA_VERSION) findings.push({ id: 'receipt_schema_mismatch' });
  if (receipt && !['local-private', 'public'].includes(receipt.profile)) findings.push({ id: 'receipt_profile_invalid' });
  if (receipt && typeof receipt.repoRoot !== 'string') findings.push({ id: 'receipt_repo_root_missing' });
  const required = receipt && Array.isArray(receipt.required) ? receipt.required : [];
  if (JSON.stringify(required) !== JSON.stringify(REQUIRED_GATES)) findings.push({ id: 'receipt_required_gates_mismatch' });
  const gates = receipt && Array.isArray(receipt.gates) ? receipt.gates : [];
  const ids = gates.map((gate) => String((gate || {}).id || ''));
  if (ids.length !== REQUIRED_GATES.length || new Set(ids).size !== ids.length || REQUIRED_GATES.some((id) => !ids.includes(id))) {
    findings.push({ id: 'receipt_gate_set_invalid' });
  }
  if (receipt && typeof receipt.release_ready !== 'boolean') findings.push({ id: 'receipt_release_ready_invalid' });
  const bundle = receipt && receipt.bundle;
  if (!bundle || !['bundleId', 'sourceTreeId', 'sourceInputDigest'].every((key) => String(bundle[key] || '').trim())) {
    findings.push({ id: 'receipt_bundle_identity_missing' });
  }
  if (receipt && receipt.status === 'pass') {
    if (receipt.release_ready !== true) findings.push({ id: 'receipt_pass_not_ready' });
    if (gates.some((gate) => gate.status !== 'pass')) findings.push({ id: 'receipt_pass_has_nonpassing_gate' });
  } else if (receipt && receipt.release_ready === true) {
    findings.push({ id: 'receipt_nonpass_marked_ready' });
  }
  return { ok: findings.length === 0, findings };
}

function writeProductionReleaseReceipt(file, result) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(result, null, 2)}\n`);
}

function receiptOutForArgs(args) {
  const candidate = args.receiptOut
    || (args.evidenceRoot ? path.join(args.evidenceRoot, PRODUCTION_RELEASE_RECEIPT) : '')
    || (args.profile === 'public' ? '' : path.join(args.repoRoot, PRODUCTION_RELEASE_RECEIPT));
  if (!candidate) return '';
  const roots = resolveReleaseRoots(args.repoRoot, args.profile, args);
  const publicRoot = args.profile === 'public'
    ? canonicalPath(args.repoRoot)
    : (roots.ok ? roots.publicRoot : '');
  if (publicRoot && pathIsInside(candidate, publicRoot)) return '';
  return candidate;
}

function runChild(command, cmdArgs, options = {}) {
  const result = spawnSync(command, cmdArgs, {
    cwd: options.cwd,
    encoding: 'utf8',
    shell: false,
    env: options.env || process.env,
  });
  return {
    status: result.status,
    stdout: (result.stdout || '').trim(),
    stderr: (result.stderr || '').trim(),
  };
}

function readJsonSafe(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_error) {
    return null;
  }
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function loadBundleManifest(repoRoot) {
  const manifestPath = path.join(repoRoot, 'skills', 'novel-assistant', 'novel-assistant-manifest.json');
  if (!fs.existsSync(manifestPath)) {
    return { status: 'missing', manifestPath, bundleId: '', sourceTreeId: '', sourceInputDigest: '' };
  }
  const data = readJsonSafe(manifestPath) || {};
  return {
    status: 'present',
    manifestPath,
    bundleId: String(data.bundleId || ''),
    sourceTreeId: String(data.sourceTreeId || ''),
    sourceInputDigest: String(data.sourceInputDigest || ''),
    sourceState: String(data.sourceState || ''),
    updateSourceBranch: String(data.updateSourceBranch || ''),
    updateSourceUrl: String(data.updateSourceUrl || ''),
    raw: data,
  };
}

function deterministicReceiptFiles(repoRoot, options = {}) {
  const reportsRoot = options.evidenceRoot ? path.resolve(options.evidenceRoot) : path.join(repoRoot, 'reports');
  const root = path.join(reportsRoot, 'private', 'production-repair');
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) return [];
  return fs.readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(root, entry.name, 'deterministic', 'summary.json'))
    .filter((file) => fs.existsSync(file) && fs.statSync(file).isFile())
    .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs);
}

function gateDeterministicCore(repoRoot, options = {}) {
  const manifest = loadBundleManifest(repoRoot);
  const receipts = deterministicReceiptFiles(repoRoot, options);
  if (!receipts.length) {
    return {
      id: 'deterministic_core',
      status: 'blocked',
      summary: 'no current deterministic test receipt found',
      findings: [{ id: 'missing_deterministic_receipt' }],
    };
  }
  const receiptPath = receipts[0];
  const receipt = readJsonSafe(receiptPath);
  const findings = [];
  if (!receipt || receipt.status !== 'pass') findings.push({ id: 'deterministic_receipt_not_pass' });
  if (!receipt || Number(receipt.exitCode) !== 0) findings.push({ id: 'deterministic_receipt_exit_nonzero' });
  if (!receipt || !Array.isArray(receipt.testGroups) || receipt.testGroups.length === 0) {
    findings.push({ id: 'deterministic_receipt_missing_test_groups' });
  }
  if (!receipt || String(receipt.bundleId || '') !== manifest.bundleId) {
    findings.push({ id: 'deterministic_receipt_bundle_mismatch' });
  }
  if (!receipt || String(receipt.sourceCommit || '') !== String(manifest.raw?.sourceCommit || '')) {
    findings.push({ id: 'deterministic_receipt_commit_mismatch' });
  }
  if (findings.length) {
    return {
      id: 'deterministic_core',
      status: 'blocked',
      summary: 'latest deterministic test receipt is not current',
      receipt: path.relative(options.evidenceRoot || repoRoot, receiptPath),
      findings,
    };
  }
  return {
    id: 'deterministic_core',
    status: 'pass',
    summary: `receipt=${path.relative(options.evidenceRoot || repoRoot, receiptPath)}, groups=${receipt.testGroups.length}`,
    receipt: path.relative(options.evidenceRoot || repoRoot, receiptPath),
    findings: [],
  };
}

function gateBehaviorEval(repoRoot, profile, options = {}) {
  const script = path.join(repoRoot, 'scripts', 'behavior-eval-release-gate.js');
  if (!fs.existsSync(script)) {
    return {
      id: 'behavior_eval',
      status: 'blocked',
      summary: 'behavior-eval-release-gate.js missing',
      findings: [{ id: 'missing_behavior_eval_gate', target: script }],
    };
  }
  const args = [script, '--repo-root', repoRoot, '--json'];
  const reportsRoot = profile === 'public' && options.publicEvidenceRoot
    ? options.publicEvidenceRoot
    : options.evidenceRoot;
  if (reportsRoot) args.push('--reports-root', reportsRoot);
  const result = runChild('node', args);
  let parsed = null;
  try { parsed = JSON.parse(result.stdout); } catch (_error) { /* ignore */ }
  if (!parsed) {
    return {
      id: 'behavior_eval',
      status: 'blocked',
      summary: `behavior-eval-release-gate returned invalid json (exit ${result.status})`,
      findings: [{ id: 'behavior_eval_invalid_json' }],
    };
  }
  if (parsed.status !== 'pass') {
    return {
      id: 'behavior_eval',
      status: 'blocked',
      summary: 'behavior eval gate is not pass',
      profile,
      findings: extractFindings(JSON.stringify(parsed), 'behavior_eval'),
    };
  }
  return {
    id: 'behavior_eval',
    status: 'pass',
    summary: `scenarios=${(parsed.required || {}).scenarios ? parsed.required.scenarios.length : 0}, hosts=${(parsed.required || {}).hosts ? parsed.required.hosts.length : 0}`,
    findings: [],
  };
}

function gateBundleCurrent(repoRoot, profile) {
  const bundle = require('./lib/bundle-version');
  const manifestPath = path.join(repoRoot, 'skills', 'novel-assistant', 'novel-assistant-manifest.json');
  const manifest = readJsonSafe(manifestPath);
  if (!manifest) {
    return {
      id: 'bundle_current',
      status: 'blocked',
      summary: 'bundle manifest missing',
      profile,
      findings: [{ id: 'missing_bundle_manifest', target: manifestPath }],
    };
  }
  const sourceCommit = bundle.sourceCommit(repoRoot);
  const computedBundleId = bundle.computeBundleId(path.dirname(manifestPath));
  const layout = manifest.sourceLayout;
  const computedSourceTreeId = layout
    ? bundle.computeManifestSourceTreeId(repoRoot, manifest.bundleName || 'novel-assistant', layout)
    : null;
  const computedSourceInputDigest = layout
    ? bundle.computeManifestSourceInputDigest(repoRoot, manifest.bundleName || 'novel-assistant', layout)
    : null;
  const treeCurrent = computedSourceTreeId && manifest.sourceTreeId
    ? manifest.sourceTreeId === computedSourceTreeId
    : false;
  const inputCurrent = computedSourceInputDigest && manifest.sourceInputDigest
    ? manifest.sourceInputDigest === computedSourceInputDigest
    : false;
  const bundleIdCurrent = manifest.bundleId === computedBundleId;
  const releaseSource = bundle.releaseSourceState(
    repoRoot,
    manifest.bundleName || 'novel-assistant',
    layout || (profile === 'public' ? false : true),
  );
  const findings = [];
  if (!bundleIdCurrent) findings.push({ id: 'bundle_id_mismatch', actual: manifest.bundleId, computed: computedBundleId });
  if (!treeCurrent) findings.push({ id: 'source_tree_id_mismatch', actual: manifest.sourceTreeId, computed: computedSourceTreeId });
  if (!inputCurrent) findings.push({ id: 'source_input_digest_mismatch', actual: manifest.sourceInputDigest, computed: computedSourceInputDigest });
  if (releaseSource === 'dirty' && profile !== 'public') findings.push({ id: 'source_state_dirty' });
  if (findings.length) {
    return {
      id: 'bundle_current',
      status: 'blocked',
      summary: 'bundle manifest does not match current source inputs',
      profile,
      bundle: { bundleId: manifest.bundleId, sourceTreeId: manifest.sourceTreeId, sourceInputDigest: manifest.sourceInputDigest },
      computed: { bundleId: computedBundleId, sourceTreeId: computedSourceTreeId, sourceInputDigest: computedSourceInputDigest, sourceState: releaseSource, sourceCommit },
      findings,
    };
  }
  return {
    id: 'bundle_current',
    status: 'pass',
    summary: `bundle=${manifest.bundleId}, tree=${manifest.sourceTreeId}, state=${releaseSource}`,
    profile,
    findings: [],
  };
}

function gatePublicTreeAudit(publicRoot) {
  const auditScript = path.join(publicRoot, 'scripts', 'public-release-audit.js');
  if (!fs.existsSync(auditScript)) {
    return {
      id: 'public_tree_audit',
      status: 'blocked',
      summary: 'public-release-audit.js missing',
      findings: [{ id: 'missing_public_audit', target: auditScript }],
    };
  }
  const result = runChild('node', [auditScript, '--repo-root', publicRoot, '--json']);
  let parsed = null;
  try { parsed = JSON.parse(result.stdout); } catch (_error) { /* ignore */ }
  if (!parsed) {
    return {
      id: 'public_tree_audit',
      status: 'blocked',
      summary: `public-release-audit returned invalid json (exit ${result.status})`,
      findings: [{ id: 'public_audit_invalid_json' }],
    };
  }
  if (parsed.status !== 'pass') {
    const findings = Array.isArray(parsed.findings) ? parsed.findings.map(toFinding) : [{ id: 'public_audit_not_pass' }];
    return {
      id: 'public_tree_audit',
      status: 'blocked',
      summary: `public-release-audit found ${findings.length} finding(s)`,
      findings,
    };
  }
  const candidate = validatePublicCandidateManifest(publicRoot);
  if (candidate.findings.length) {
    return {
      id: 'public_tree_audit',
      status: 'blocked',
      summary: 'public candidate manifest is missing or no longer matches the public tree',
      findings: candidate.findings,
    };
  }
  return {
    id: 'public_tree_audit',
    status: 'pass',
    summary: `checked=${parsed.checkedFiles || 0}`,
    findings: [],
  };
}

function validatePublicCandidateManifest(repoRoot) {
  const manifestPath = path.join(repoRoot, PUBLIC_CANDIDATE_MANIFEST);
  const manifest = readJsonSafe(manifestPath);
  if (!manifest || manifest.schemaVersion !== '1.0.0' || !manifest.files || typeof manifest.files !== 'object') {
    return { findings: [{ id: 'missing_public_candidate_manifest', target: PUBLIC_CANDIDATE_MANIFEST }] };
  }
  const expected = Object.keys(manifest.files).sort();
  const candidateFiles = inspectPublicCandidateFiles(repoRoot);
  const actual = candidateFiles.files.filter((relative) => relative !== PUBLIC_CANDIDATE_MANIFEST);
  const findings = [...candidateFiles.findings];
  const actualSet = new Set(actual);
  for (const relative of expected) {
    if (!safePublicRelative(relative)) {
      findings.push({ id: 'unsafe_public_candidate_path', target: relative });
      continue;
    }
    const target = path.join(repoRoot, relative);
    if (!actualSet.has(relative)) {
      findings.push({ id: 'public_candidate_file_missing', target: relative });
      continue;
    }
    if (String(manifest.files[relative]) !== sha256(target)) {
      findings.push({ id: 'public_candidate_digest_mismatch', target: relative });
    }
  }
  const expectedSet = new Set(expected);
  for (const relative of actual) {
    if (!expectedSet.has(relative)) findings.push({ id: 'public_candidate_unlisted_file', target: relative });
  }
  return { findings };
}

function inspectPublicCandidateFiles(repoRoot, base = '') {
  const directory = path.join(repoRoot, base);
  if (!fs.existsSync(directory)) return { files: [], findings: [] };
  const files = [];
  const findings = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (!base && entry.name === '.git') continue;
    const relative = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isSymbolicLink()) {
      findings.push({ id: 'public_candidate_symlink', target: relative });
    } else if (entry.isDirectory()) {
      const nested = inspectPublicCandidateFiles(repoRoot, relative);
      files.push(...nested.files);
      findings.push(...nested.findings);
    } else if (entry.isFile()) {
      files.push(relative);
    } else {
      findings.push({ id: 'public_candidate_unsupported_entry', target: relative });
    }
  }
  return { files: files.sort(), findings };
}

function safePublicRelative(relative) {
  return typeof relative === 'string' && relative.length > 0 && !relative.includes('\\')
    && !path.posix.isAbsolute(relative) && !path.win32.isAbsolute(relative)
    && !relative.split('/').some((segment) => !segment || segment === '.' || segment === '..');
}

function gatePublicBehaviorEval(publicRoot, options = {}) {
  const reportsRoot = String(options.publicEvidenceRoot || '').trim();
  if (!reportsRoot) {
    return {
      id: 'public_behavior_eval',
      status: 'blocked',
      summary: 'no external public behavior evidence root was supplied',
      findings: [{ id: 'missing_public_behavior_evidence_root' }],
    };
  }
  const script = path.join(publicRoot, 'scripts', 'behavior-eval-release-gate.js');
  if (!fs.existsSync(script)) {
    return {
      id: 'public_behavior_eval',
      status: 'blocked',
      summary: 'public behavior-eval-release-gate.js missing',
      findings: [{ id: 'missing_public_behavior_eval_gate', target: script }],
    };
  }
  const result = runChild('node', [script, '--repo-root', publicRoot, '--reports-root', reportsRoot, '--json']);
  let parsed = null;
  try { parsed = JSON.parse(result.stdout); } catch (_error) { /* handled below */ }
  if (!parsed) {
    return {
      id: 'public_behavior_eval',
      status: 'blocked',
      summary: `public behavior gate returned invalid json (exit ${result.status})`,
      findings: [{ id: 'public_behavior_eval_invalid_json' }],
    };
  }
  if (parsed.status !== 'pass') {
    return {
      id: 'public_behavior_eval',
      status: 'blocked',
      summary: 'public behavior eval gate is not pass',
      findings: extractFindings(JSON.stringify(parsed), 'public_behavior_eval'),
    };
  }
  return {
    id: 'public_behavior_eval',
    status: 'pass',
    summary: `scenarios=${(parsed.required || {}).scenarios ? parsed.required.scenarios.length : 0}, hosts=${(parsed.required || {}).hosts ? parsed.required.hosts.length : 0}`,
    findings: [],
  };
}

function gateInstallConsistency(repoRoot, profile, options = {}) {
  if (profile && typeof profile === 'object') {
    options = profile;
    profile = 'local-private';
  }
  const resolver = require('./lib/install-target-resolver');
  const manifest = loadBundleManifest(repoRoot);
  const sourceBundle = path.join(repoRoot, 'skills', 'novel-assistant');
  const targets = resolver.resolveInstallTargets({ home: options.installRoot || process.env.NOVEL_ASSISTANT_INSTALL_ROOT || '' });
  if (!targets.length) {
    return {
      id: 'install_consistency',
      status: 'blocked',
      summary: 'no install targets produced by resolver',
      findings: [{ id: 'no_install_targets' }],
    };
  }
  const findings = [];
  const targetReports = [];
  for (const target of targets) {
    const host = resolver.targetHost(target);
    if (!host) {
      findings.push({ id: 'unknown_install_host', target });
      continue;
    }
    if (!resolver.REQUIRED_HOSTS.includes(host)) {
      findings.push({ id: 'install_host_not_required', target, host });
      continue;
    }
    const installed = resolver.loadManifest(target);
    const verification = resolver.verifyBundleTarget(sourceBundle, target);
    const runtime = resolver.verifyRuntimeTarget(target, profile === 'public' ? 'public' : 'private');
    const installedBundle = String((installed || {}).bundleId || '');
    const installedSourceTree = String((installed || {}).sourceTreeId || '');
    const targetStatus = verification.ok && runtime.ok ? 'consistent' : 'stale';
    targetReports.push({
      host,
      target,
      status: targetStatus,
      installedBundleId: installedBundle,
      candidateBundleId: manifest.bundleId,
      installedSourceTreeId: installedSourceTree,
      candidateSourceTreeId: manifest.sourceTreeId,
    });
    if (targetStatus !== 'consistent') {
      findings.push({
        id: 'install_target_inconsistent',
        host,
        target,
        installedBundleId: installedBundle,
        candidateBundleId: manifest.bundleId,
        details: verification.findings,
        runtime: runtime.findings,
      });
    }
  }
  for (const host of resolver.requiredHosts()) {
    if (!targetReports.some((item) => item.host === host)) {
      findings.push({ id: 'missing_required_install_host', host });
    }
  }
  if (findings.length) {
    return {
      id: 'install_consistency',
      status: 'blocked',
      summary: 'one or more required install hosts are stale or missing',
      targets: targetReports,
      findings,
    };
  }
  return {
    id: 'install_consistency',
    status: 'pass',
    summary: `targets=${targetReports.length}`,
    targets: targetReports,
    findings: [],
  };
}

function toFinding(item) {
  if (!item || typeof item !== 'object') return { id: 'unknown_finding' };
  return {
    id: item.id || 'unknown_finding',
    caseId: item.caseId,
    layer: item.layer,
    target: item.target,
    anchor: item.anchor,
    message: item.message,
  };
}

function extractFindings(jsonText, gateId) {
  try {
    const parsed = JSON.parse(jsonText || '{}');
    const findings = Array.isArray(parsed.findings) ? parsed.findings : [];
    if (findings.length) {
      return findings.map((finding) => {
        if (finding && typeof finding === 'object' && finding.scenario && Array.isArray(finding.findings)) {
          return {
            id: `${gateId}_scenario_failed`,
            scenario: String(finding.scenario),
            reasons: finding.findings.map(String),
            target: finding.file || '',
          };
        }
        return toFinding(finding);
      });
    }
  } catch (_error) { /* fall through */ }
  return [{ id: `${gateId}_no_findings_parsed` }];
}

function relativize(repoRoot) {
  return (p) => path.relative(repoRoot, p);
}

function pathIsInside(candidate, root) {
  const relative = path.relative(canonicalPath(root), canonicalPath(candidate));
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function canonicalPath(value) {
  let current = path.resolve(value);
  const suffix = [];
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) break;
    suffix.unshift(path.basename(current));
    current = parent;
  }
  const base = fs.existsSync(current) ? fs.realpathSync(current) : current;
  return path.join(base, ...suffix);
}

function resolveReleaseRoots(repoRoot, profile, options = {}) {
  const privateRoot = canonicalPath(repoRoot);
  if (profile === 'public') {
    if (options.publicRoot && canonicalPath(options.publicRoot) !== privateRoot) {
      return { ok: false, reason: 'public_profile_root_mismatch', privateRoot, publicRoot: '' };
    }
    return { ok: true, privateRoot, publicRoot: privateRoot };
  }
  if (!options.publicRoot) {
    return { ok: false, reason: 'missing_public_candidate_root', privateRoot, publicRoot: '' };
  }
  const publicRoot = canonicalPath(options.publicRoot);
  if (publicRoot === privateRoot) {
    return { ok: false, reason: 'public_candidate_root_must_differ_from_private_source', privateRoot, publicRoot };
  }
  if (!fs.existsSync(publicRoot) || !fs.statSync(publicRoot).isDirectory()) {
    return { ok: false, reason: 'public_candidate_root_missing', privateRoot, publicRoot };
  }
  return { ok: true, privateRoot, publicRoot };
}

function validateReleasePaths(repoRoot, profile, options = {}) {
  const roots = resolveReleaseRoots(repoRoot, profile, options);
  const findings = [];
  if (!roots.ok && profile !== 'public') return { ok: true, findings };
  if (!roots.ok) findings.push({ id: roots.reason, target: path.resolve(repoRoot) });
  const publicRoot = profile === 'public' ? canonicalPath(repoRoot) : roots.publicRoot;
  if (profile === 'public' && !options.evidenceRoot) findings.push({ id: 'missing_evidence_root_for_public_release' });
  if (profile === 'public' && !options.publicEvidenceRoot) findings.push({ id: 'missing_public_evidence_root_for_public_release' });
  if (options.evidenceRoot && pathIsInside(options.evidenceRoot, publicRoot)) {
    findings.push({ id: 'evidence_root_inside_public_candidate', target: options.evidenceRoot });
  }
  if (options.publicEvidenceRoot && pathIsInside(options.publicEvidenceRoot, publicRoot)) {
    findings.push({ id: 'public_evidence_root_inside_candidate', target: options.publicEvidenceRoot });
  }
  if (options.receiptOut && pathIsInside(options.receiptOut, publicRoot)) {
    findings.push({ id: 'receipt_out_inside_public_candidate', target: options.receiptOut });
  }
  return { ok: findings.length === 0, findings };
}

function aggregateGateResults(gates, options = {}) {
  const normalized = Array.isArray(gates) ? gates : [];
  const byId = new Map(normalized.map((gate) => [gate.id, gate]));
  const ids = normalized.map((gate) => String((gate || {}).id || ''));
  const duplicates = [...new Set(ids.filter((id, index) => id && ids.indexOf(id) !== index))];
  const missing = REQUIRED_GATES.filter((id) => !byId.has(id));
  const blockers = [...new Set([
    ...REQUIRED_GATES.filter((id) => byId.get(id)?.status !== 'pass'),
    ...duplicates,
  ])];
  return {
    status: missing.length === 0 && blockers.length === 0 && duplicates.length === 0 ? 'pass' : 'blocked',
    release_ready: missing.length === 0 && blockers.length === 0 && duplicates.length === 0,
    profile: options.profile || 'local-private',
    required: [...REQUIRED_GATES],
    gates: normalized,
    blockers,
    missing,
    duplicates,
  };
}

function evaluateGate(repoRoot, profile, options = {}) {
  const resolvedProfile = profile || 'local-private';
  const roots = resolveReleaseRoots(repoRoot, resolvedProfile, options);
  const privateRoot = roots.privateRoot || path.resolve(repoRoot);
  const bundle = loadBundleManifest(privateRoot);
  if (!roots.ok) {
    const publicFinding = { id: roots.reason, privateRoot, publicRoot: roots.publicRoot || '' };
    const gates = [
      gateDeterministicCore(privateRoot, options),
      gateBehaviorEval(privateRoot, resolvedProfile, options),
      gateBundleCurrent(privateRoot, resolvedProfile),
      { id: 'public_tree_audit', status: 'blocked', summary: 'sanitized public candidate root is required', findings: [publicFinding] },
      { id: 'public_behavior_eval', status: 'blocked', summary: 'sanitized public candidate root is required', findings: [publicFinding] },
      gateInstallConsistency(privateRoot, resolvedProfile, options),
    ];
    const aggregate = aggregateGateResults(gates, { profile: resolvedProfile });
    return {
      schemaVersion: SCHEMA_VERSION,
      ...aggregate,
      repoRoot: privateRoot,
      publicRoot: roots.publicRoot || '',
      bundle: {
        bundleId: bundle.bundleId,
        sourceTreeId: bundle.sourceTreeId,
        sourceInputDigest: bundle.sourceInputDigest,
        manifestPath: bundle.manifestPath,
        status: bundle.status,
      },
      findings: gates.filter((g) => g.status !== 'pass').flatMap((g) => (g.findings || []).map((f) => ({ gate: g.id, ...f }))),
    };
  }
  const gates = [];
  gates.push(gateDeterministicCore(privateRoot, options));
  gates.push(gateBehaviorEval(privateRoot, resolvedProfile, options));
  gates.push(gateBundleCurrent(privateRoot, resolvedProfile));
  gates.push(gatePublicTreeAudit(roots.publicRoot));
  gates.push(gatePublicBehaviorEval(roots.publicRoot, options));
  gates.push(gateInstallConsistency(privateRoot, resolvedProfile, options));

  const aggregate = aggregateGateResults(gates, { profile: resolvedProfile });

  return {
    schemaVersion: SCHEMA_VERSION,
    ...aggregate,
    repoRoot: privateRoot,
    publicRoot: roots.publicRoot,
    bundle: {
      bundleId: bundle.bundleId,
      sourceTreeId: bundle.sourceTreeId,
      sourceInputDigest: bundle.sourceInputDigest,
      manifestPath: bundle.manifestPath,
      status: bundle.status,
    },
    findings: gates.filter((g) => g.status !== 'pass').flatMap((g) => (g.findings || []).map((f) => ({ gate: g.id, ...f }))),
  };
}

function printText(result) {
  console.log(`production release gate: ${result.status} (release_ready=${result.release_ready})`);
  console.log(`profile: ${result.profile}`);
  console.log(`bundle: ${result.bundle.bundleId || 'unknown'} (${result.bundle.status})`);
  for (const gate of result.gates) {
    console.log(`- ${gate.id}: ${gate.status} ${gate.summary || ''}`);
  }
  if (result.findings.length) {
    console.log('findings:');
    for (const finding of result.findings) {
      console.log(`  - ${finding.gate}: ${finding.id}${finding.message ? ' ' + finding.message : ''}`);
    }
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(`Usage: node scripts/production-release-gate.js [--repo-root PATH] [--profile local-private|public] [--public-root PATH] [--evidence-root PATH] [--public-evidence-root PATH] [--install-root PATH] [--receipt-out PATH] [--json]\n`);
    return 0;
  }
  try {
    const pathValidation = validateReleasePaths(args.repoRoot, args.profile, args);
    if (!pathValidation.ok) {
      const error = new Error(pathValidation.findings.map((finding) => finding.id).join(', '));
      error.findings = pathValidation.findings;
      throw error;
    }
    const result = evaluateGate(args.repoRoot, args.profile, args);
    const receiptOut = receiptOutForArgs(args);
    if (receiptOut) writeProductionReleaseReceipt(receiptOut, result);
    if (args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    else printText(result);
    return result.status === 'pass' ? 0 : 1;
  } catch (error) {
    const result = {
      schemaVersion: SCHEMA_VERSION,
      status: 'error',
      release_ready: false,
      profile: args.profile,
      repoRoot: path.resolve(args.repoRoot),
      error: error.message,
      findings: Array.isArray(error.findings) ? error.findings : [],
    };
    const receiptOut = receiptOutForArgs(args);
    if (receiptOut) writeProductionReleaseReceipt(receiptOut, result);
    if (args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    else console.error(`production release gate error: ${error.message}`);
    return 2;
  }
}

if (require.main === module) {
  process.exit(main());
}

module.exports = {
  REQUIRED_GATES,
  REQUIRED_PUBLIC_BEHAVIOR_SCENARIOS,
  PUBLIC_CANDIDATE_MANIFEST,
  PRODUCTION_RELEASE_RECEIPT,
  aggregateGateResults,
  validateProductionReleaseReceipt,
  readProductionReleaseReceipt,
  writeProductionReleaseReceipt,
  evaluateGate,
  loadBundleManifest,
  gateDeterministicCore,
  gateBehaviorEval,
  gateBundleCurrent,
  gatePublicTreeAudit,
  validatePublicCandidateManifest,
  gatePublicBehaviorEval,
  gateInstallConsistency,
  resolveReleaseRoots,
  validateReleasePaths,
};
