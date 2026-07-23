#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MANIFEST="$REPO/config/novel-assistant-bundle-files.json"
    VERSION="$REPO/scripts/lib/bundle-version.js"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    SYNC="$REPO/scripts/novel-assistant-sync-runtime.js"
}

@test "bundle file manifest is the shared build, identity, and runtime input" {
    [ -f "$MANIFEST" ]

    node - "$REPO" "$MANIFEST" "$VERSION" <<'NODE'
const fs = require('fs');
const path = require('path');
const repo = process.argv[2];
const manifestPath = process.argv[3];
const version = require(process.argv[4]);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const loaded = version.loadBundleFileManifest(repo);
if (JSON.stringify(loaded) !== JSON.stringify(manifest)) throw new Error('version helper did not load the shared manifest');
if (!Array.isArray(manifest.internalSkills) || !Array.isArray(manifest.scriptFiles)) throw new Error('manifest lists are missing');
const entries = version.sourceEntries(repo, manifest.bundleName, version.buildSourceLayout(repo));
if (!entries.some((entry) => entry.destination === 'config/novel-assistant-bundle-files.json')) {
  throw new Error('build manifest is not part of source identity');
}
for (const name of manifest.scriptFiles) {
  if (!entries.some((entry) => entry.destination === `scripts/${name}`)) throw new Error(`missing source entry: ${name}`);
}
const lifecycleRuntime = [
  'scripts/longform-lifecycle-status.js',
  'scripts/workflow-state-machine.js',
  'scripts/context-assembler.js',
  'scripts/workflow-task-inbox.js',
  'scripts/workflow-legacy-migrate.js',
  'scripts/lib/longform-lifecycle.js',
  'scripts/lib/review-target-policy.js',
  'scripts/lib/lifecycle-impact.js',
  'scripts/lib/memory-projection.js',
  'scripts/lib/workflow-legacy-migration.js',
];
for (const destination of lifecycleRuntime) {
  if (!entries.some((entry) => entry.destination === destination)) {
    throw new Error(`missing lifecycle runtime source entry: ${destination}`);
  }
}
NODE

    grep -q 'novel-assistant-bundle-files.json' "$BUILD"
    grep -q 'loadBundleFileManifest' "$SYNC"
}

@test "checked-in bundle mirrors every source internal skill" {
    diff -qr "$REPO/src/internal-skills" "$REPO/skills/novel-assistant/references/internal-skills"
}

@test "changing a bundle manifest input changes sourceTreeId" {
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT
    cp -R "$REPO/." "$fixture"

    before="$(node - "$VERSION" "$fixture" <<'NODE'
const version = require(process.argv[2]);
process.stdout.write(version.computeSourceTreeId(process.argv[3], 'novel-assistant'));
NODE
)"
    printf '\n' >> "$fixture/config/novel-assistant-bundle-files.json"
    after="$(node - "$VERSION" "$fixture" <<'NODE'
const version = require(process.argv[2]);
process.stdout.write(version.computeSourceTreeId(process.argv[3], 'novel-assistant'));
NODE
)"

    [ "$before" != "$after" ]
}

@test "generated bundle preserves the manifest and public builds exclude private modules" {
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT
    cp -R "$REPO/." "$fixture"
    bash "$fixture/scripts/build-oh-story-bundle.sh" >/dev/null

    cmp "$fixture/config/novel-assistant-bundle-files.json" "$fixture/skills/novel-assistant/config/novel-assistant-bundle-files.json"
    node - "$fixture" "$fixture/config/novel-assistant-bundle-files.json" <<'NODE'
const fs = require('fs');
const path = require('path');
const repo = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const version = require(path.join(repo, 'scripts', 'lib', 'bundle-version.js'));
const bundle = path.join(repo, 'skills', manifest.bundleName);
const generated = JSON.parse(fs.readFileSync(path.join(bundle, 'novel-assistant-manifest.json'), 'utf8'));
if (generated.internalSkillCount !== manifest.internalSkills.length) throw new Error('internal count drift');
if (generated.scriptCount !== manifest.scriptFiles.length) throw new Error('script count drift');
const layout = version.buildSourceLayout(repo, { includePrivate: true });
const expectedDigest = version.computeSourceInputDigest(repo, manifest.bundleName, layout);
if (generated.sourceInputDigest !== expectedDigest) throw new Error(`source input digest drift: ${generated.sourceInputDigest} != ${expectedDigest}`);
if (generated.sourceTreeId !== `tree-${expectedDigest.slice('sha256:'.length, 'sha256:'.length + 12)}`) {
  throw new Error('source tree identity does not derive from source input digest');
}
if (generated.bundleId !== `bundle-${expectedDigest.slice('sha256:'.length, 'sha256:'.length + 12)}`) {
  throw new Error('bundle identity does not match the mirrored source input digest');
}
if (!generated.sourceCommit || generated.sourceCommitRole !== 'build_start_git_baseline') {
  throw new Error('source commit baseline metadata is missing');
}
for (const entry of version.sourceEntries(repo, manifest.bundleName, layout)) {
  const bundled = path.join(bundle, entry.destination);
  if (!fs.existsSync(bundled)) throw new Error(`missing bundle mirror: ${entry.destination}`);
  if (!fs.readFileSync(entry.source).equals(fs.readFileSync(bundled))) {
    throw new Error(`bundle mirror content drift: ${entry.destination}`);
  }
}
for (const name of manifest.internalSkills) {
  if (!fs.existsSync(path.join(bundle, 'references', 'internal-skills', name, 'SKILL.md'))) throw new Error(`missing internal skill: ${name}`);
}
    for (const name of manifest.scriptFiles) {
      if (!fs.existsSync(path.join(bundle, 'scripts', name))) throw new Error(`missing script: ${name}`);
    }
NODE

    diff -qr "$fixture/src/internal-skills" "$fixture/skills/novel-assistant/references/internal-skills"

    public_root="$(mktemp -d)"
    trap 'rm -rf "$fixture" "$public_root"' EXIT
    cp -R "$REPO/." "$public_root"
    NOVEL_ASSISTANT_INCLUDE_PRIVATE=0 bash "$public_root/scripts/build-oh-story-bundle.sh" >/dev/null
    [ ! -e "$public_root/skills/novel-assistant/references/private-internal-skills" ]
    private_count="$(node -e "process.stdout.write(String(require('$public_root/skills/novel-assistant/novel-assistant-manifest.json').privateInternalSkillCount))")"
    [ "$private_count" = "0" ]
}
