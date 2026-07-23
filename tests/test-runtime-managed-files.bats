#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MANAGED="$REPO/scripts/lib/runtime-managed-files.js"
    TMP_DIR="$(mktemp -d)"
    TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
    PROJECT="$TMP_DIR/book"
    SOURCE="$TMP_DIR/source"
    mkdir -p "$PROJECT" "$SOURCE/.claude/hooks" "$SOURCE/.claude/rules" "$SOURCE/.claude/agents"
    printf 'managed hook v1\n' > "$SOURCE/.claude/hooks/managed.sh"
    printf 'managed rule v1\n' > "$SOURCE/.claude/rules/managed.md"
    printf 'managed agent v1\n' > "$SOURCE/.claude/agents/managed.md"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "managed sync preserves unrelated files in managed directories" {
    mkdir -p "$PROJECT/.claude/hooks" "$PROJECT/.claude/rules" "$PROJECT/.claude/agents"
    printf 'custom hook\n' > "$PROJECT/.claude/hooks/custom.sh"
    printf 'custom rule\n' > "$PROJECT/.claude/rules/custom.md"
    printf 'custom agent\n' > "$PROJECT/.claude/agents/custom.md"

    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const runtime = require(process.argv[2]);
const plan = runtime.planManagedSync({
  projectRoot: process.argv[3],
  sourceRoot: process.argv[4],
  previousManifest: null,
  bundleId: 'test-bundle',
});
const result = runtime.applyManagedSync(plan);
if (result.status !== 'synced') process.exit(1);
NODE

    [ "$(cat "$PROJECT/.claude/hooks/custom.sh")" = 'custom hook' ]
    [ "$(cat "$PROJECT/.claude/rules/custom.md")" = 'custom rule' ]
    [ "$(cat "$PROJECT/.claude/agents/custom.md")" = 'custom agent' ]
    [ "$(cat "$PROJECT/.claude/hooks/managed.sh")" = 'managed hook v1' ]
    node -e 'const m=require(process.argv[1]); if(!m.files.some(f=>f.path===".claude/hooks/managed.sh" && f.bundleId==="test-bundle")) process.exit(1)' "$PROJECT/.story-runtime-managed.json"
}

@test "managed sync requires confirmation before replacing an unmanaged same-name file" {
    mkdir -p "$PROJECT/.claude/hooks"
    printf 'user hook\n' > "$PROJECT/.claude/hooks/managed.sh"

    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const runtime = require(process.argv[2]);
const plan = runtime.planManagedSync({
  projectRoot: process.argv[3],
  sourceRoot: process.argv[4],
  previousManifest: null,
  bundleId: 'test-bundle',
});
if (plan.conflicts.length !== 1) process.exit(1);
const preview = runtime.applyManagedSync(plan);
if (preview.status !== 'confirmation_required') process.exit(2);
if (fs.readFileSync(`${process.argv[3]}/.claude/hooks/managed.sh`, 'utf8') !== 'user hook\n') process.exit(3);
if (fs.existsSync(`${process.argv[3]}/.story-runtime-managed.json`)) process.exit(4);
const applied = runtime.applyManagedSync(plan, { confirmConflicts: true });
if (applied.status !== 'synced') process.exit(5);
NODE

    [ "$(cat "$PROJECT/.claude/hooks/managed.sh")" = 'managed hook v1' ]
}

@test "managed sync never adopts an identical unmanaged file for a later overwrite" {
    mkdir -p "$PROJECT/.claude/hooks"
    cp "$SOURCE/.claude/hooks/managed.sh" "$PROJECT/.claude/hooks/managed.sh"

    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
const target = path.join(projectRoot, '.claude/hooks/managed.sh');
const manifestPath = path.join(projectRoot, '.story-runtime-managed.json');

let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
if (!plan.conflicts.some(conflict => conflict.path === '.claude/hooks/managed.sh' && conflict.reason === 'unmanaged_existing_file')) process.exit(1);
let result = runtime.applyManagedSync(plan);
if (result.status !== 'confirmation_required') process.exit(2);
if (fs.existsSync(manifestPath)) process.exit(3);

fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), 'managed hook v2\n');
plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle-v2' });
result = runtime.applyManagedSync(plan);
if (result.status !== 'confirmation_required') process.exit(4);
if (fs.readFileSync(target, 'utf8') !== 'managed hook v1\n') process.exit(5);
if (fs.existsSync(manifestPath)) process.exit(6);
NODE
}

@test "managed sync snapshots changed owned files and rollback restores them" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
const firstManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), 'managed hook v2\n');
plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: firstManifest, bundleId: 'test-bundle' });
const applied = runtime.applyManagedSync(plan);
if (!applied.snapshotId) process.exit(1);
if (!fs.existsSync(path.join(projectRoot, '追踪/runtime-snapshots', applied.snapshotId, 'manifest.json'))) process.exit(2);
const rollback = runtime.rollbackManagedSync({ projectRoot, snapshotId: applied.snapshotId });
if (rollback.status !== 'rolled_back') process.exit(3);
NODE

    [ "$(cat "$PROJECT/.claude/hooks/managed.sh")" = 'managed hook v1' ]
}

@test "managed rollback requires confirmation when a user deleted an updated file after the snapshot" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
const firstManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
const target = path.join(projectRoot, '.claude/hooks/managed.sh');
fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), 'managed hook v2\n');
plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: firstManifest, bundleId: 'test-bundle' });
const applied = runtime.applyManagedSync(plan);
fs.rmSync(target);
const preview = runtime.rollbackManagedSync({ projectRoot, snapshotId: applied.snapshotId });
if (preview.status !== 'confirmation_required') process.exit(1);
if (!preview.conflicts.some(conflict => conflict.path === '.claude/hooks/managed.sh')) process.exit(2);
if (fs.existsSync(target)) process.exit(3);
const confirmed = runtime.rollbackManagedSync({ projectRoot, snapshotId: applied.snapshotId, confirmConflicts: true });
if (confirmed.status !== 'rolled_back') process.exit(4);
if (fs.readFileSync(target, 'utf8') !== 'managed hook v1\n') process.exit(5);
NODE
}

@test "managed sync cannot escape when a target parent becomes a symlink after revalidation" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" "$TMP_DIR" <<'NODE'
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');
const managedModule = process.argv[2];
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
const outsideRoot = process.argv[5];
const target = path.join(projectRoot, '.claude/hooks/managed.sh');
const targetParent = path.dirname(target);
const displacedParent = path.join(projectRoot, '.claude/hooks-before-race');
const outsideParent = path.join(outsideRoot, 'outside-hooks');
const outsideTarget = path.join(outsideParent, 'managed.sh');
fs.mkdirSync(targetParent, { recursive: true });
fs.mkdirSync(outsideParent, { recursive: true });
fs.writeFileSync(outsideTarget, 'outside remains\n');

let armed = false;
let attacked = false;
function replaceParentWithSymlink() {
  if (!armed || attacked) return;
  attacked = true;
  fs.renameSync(targetParent, displacedParent);
  fs.symlinkSync(outsideParent, targetParent);
}

const originalSpawnSync = childProcess.spawnSync;
childProcess.spawnSync = function(command, args, options) {
  if (Array.isArray(args) && args[0] === 'external-copy' && args[2] === '.claude/hooks/managed.sh') {
    replaceParentWithSymlink();
  }
  return originalSpawnSync.call(this, command, args, options);
};

const runtime = require(managedModule);
const plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
armed = true;
let rejected = false;
try {
  runtime.applyManagedSync(plan);
} catch (error) {
  rejected = /symlink|safe filesystem|target changed/i.test(error.message);
}
if (!attacked) process.exit(1);
if (!rejected) process.exit(2);
if (fs.readFileSync(outsideTarget, 'utf8') !== 'outside remains\n') process.exit(3);
NODE
}

@test "managed sync is idempotent when sources and owned files are unchanged" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
const manifestPath = path.join(projectRoot, '.story-runtime-managed.json');
const before = fs.readFileSync(manifestPath, 'utf8');
const previousManifest = JSON.parse(before);
plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest, bundleId: 'test-bundle' });
if (plan.operations.some(operation => operation.action !== 'noop')) process.exit(1);
const applied = runtime.applyManagedSync(plan);
if (applied.status !== 'synced' || applied.changed !== 0 || applied.snapshotId) process.exit(2);
if (fs.readFileSync(manifestPath, 'utf8') !== before) process.exit(3);
NODE
}

@test "managed sync rejects a symlinked managed target without touching the outside file" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" "$TMP_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
const outsideRoot = process.argv[5];
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
const previousManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
const target = path.join(projectRoot, '.claude/hooks/managed.sh');
const outside = path.join(outsideRoot, 'outside-target.sh');
fs.writeFileSync(outside, 'managed hook v1\n');
fs.rmSync(target);
fs.symlinkSync(outside, target);
fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), 'managed hook v2\n');
let rejected = false;
try {
  runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest, bundleId: 'test-bundle' });
} catch (error) {
  rejected = /symlink/.test(error.message);
}
if (!rejected) process.exit(1);
if (fs.readFileSync(outside, 'utf8') !== 'managed hook v1\n') process.exit(2);
if (!fs.lstatSync(target).isSymbolicLink()) process.exit(3);
NODE
}

@test "managed sync rejects a symlinked managed parent without touching the outside directory" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" "$TMP_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
const outsideRoot = process.argv[5];
const outsideClaude = path.join(outsideRoot, 'outside-claude');
fs.mkdirSync(path.join(outsideClaude, 'hooks'), { recursive: true });
const outsideTarget = path.join(outsideClaude, 'hooks/managed.sh');
fs.writeFileSync(outsideTarget, 'outside managed hook\n');
fs.symlinkSync(outsideClaude, path.join(projectRoot, '.claude'));
let rejected = false;
try {
  runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
} catch (error) {
  rejected = /symlink/.test(error.message);
}
if (!rejected) process.exit(1);
if (fs.readFileSync(outsideTarget, 'utf8') !== 'outside managed hook\n') process.exit(2);
NODE
}

@test "managed sync rejects a symlinked runtime snapshot root before updating" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" "$TMP_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
const outsideRoot = process.argv[5];
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
const previousManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), 'managed hook v2\n');
fs.mkdirSync(path.join(outsideRoot, 'outside-snapshots'), { recursive: true });
fs.writeFileSync(path.join(outsideRoot, 'outside-snapshots/marker'), 'outside remains\n');
fs.mkdirSync(path.join(projectRoot, '追踪'), { recursive: true });
fs.symlinkSync(path.join(outsideRoot, 'outside-snapshots'), path.join(projectRoot, '追踪/runtime-snapshots'));
plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest, bundleId: 'test-bundle' });
let rejected = false;
try {
  runtime.applyManagedSync(plan);
} catch (error) {
  rejected = /symlink/.test(error.message);
}
if (!rejected) process.exit(1);
if (fs.readFileSync(path.join(projectRoot, '.claude/hooks/managed.sh'), 'utf8') !== 'managed hook v1\n') process.exit(2);
if (fs.readFileSync(path.join(outsideRoot, 'outside-snapshots/marker'), 'utf8') !== 'outside remains\n') process.exit(3);
NODE
}

@test "managed sync revalidates a user edit made after planning before applying" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
const previousManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), 'managed hook v2\n');
plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest, bundleId: 'test-bundle' });
const target = path.join(projectRoot, '.claude/hooks/managed.sh');
fs.writeFileSync(target, 'user edit after planning\n');
const result = runtime.applyManagedSync(plan);
if (result.status !== 'confirmation_required') process.exit(1);
if (!result.conflicts.some(conflict => conflict.path === '.claude/hooks/managed.sh')) process.exit(2);
if (fs.readFileSync(target, 'utf8') !== 'user edit after planning\n') process.exit(3);
if (fs.existsSync(path.join(projectRoot, '追踪/runtime-snapshots'))) process.exit(4);
NODE
}

@test "managed sync retains only the bounded snapshot set and supports rollback from a retained snapshot" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
const retainedCount = runtime.RETAINED_SNAPSHOT_COUNT || 2;
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
let previousManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
const snapshotIds = [];
for (let version = 2; version <= retainedCount + 2; version += 1) {
  fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), `managed hook v${version}\n`);
  plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest, bundleId: 'test-bundle' });
  const applied = runtime.applyManagedSync(plan);
  if (applied.status !== 'synced' || !applied.snapshotId) process.exit(1);
  snapshotIds.push(applied.snapshotId);
  previousManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
}
const snapshotRoot = path.join(projectRoot, '追踪/runtime-snapshots');
const retained = fs.readdirSync(snapshotRoot).filter(name => fs.lstatSync(path.join(snapshotRoot, name)).isDirectory()).sort();
if (retained.length !== retainedCount) process.exit(2);
if (fs.existsSync(path.join(snapshotRoot, snapshotIds[0]))) process.exit(3);
const newest = snapshotIds.at(-1);
if (!fs.existsSync(path.join(snapshotRoot, newest, 'manifest.json'))) process.exit(4);
const rollback = runtime.rollbackManagedSync({ projectRoot, snapshotId: newest });
if (rollback.status !== 'rolled_back') process.exit(5);
if (fs.readFileSync(path.join(projectRoot, '.claude/hooks/managed.sh'), 'utf8') !== `managed hook v${retainedCount + 1}\n`) process.exit(6);
NODE
}

@test "managed sync blocks an update before a new snapshot would exceed the byte cap" {
    node - "$MANAGED" "$PROJECT" "$SOURCE" <<'NODE'
const fs = require('fs');
const path = require('path');
const runtime = require(process.argv[2]);
const projectRoot = process.argv[3];
const sourceRoot = process.argv[4];
const byteCap = runtime.SNAPSHOT_TOTAL_BYTE_CAP || 1024;
const initial = Buffer.alloc(byteCap + 1, 'a');
fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), initial);
let plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest: null, bundleId: 'test-bundle' });
runtime.applyManagedSync(plan);
const previousManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, '.story-runtime-managed.json'), 'utf8'));
fs.writeFileSync(path.join(sourceRoot, '.claude/hooks/managed.sh'), 'managed hook v2\n');
plan = runtime.planManagedSync({ projectRoot, sourceRoot, previousManifest, bundleId: 'test-bundle' });
let rejected = false;
try {
  runtime.applyManagedSync(plan);
} catch (error) {
  rejected = /snapshot.*byte cap/i.test(error.message);
}
if (!rejected) process.exit(1);
if (!fs.readFileSync(path.join(projectRoot, '.claude/hooks/managed.sh')).equals(initial)) process.exit(2);
if (fs.existsSync(path.join(projectRoot, '追踪/runtime-snapshots'))) process.exit(3);
NODE
}
