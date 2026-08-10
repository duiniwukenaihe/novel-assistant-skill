#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SYNC="$REPO/scripts/sync-sanitized-release-tree.js"
    SANITIZE="$REPO/scripts/sanitize-github-public-tree.js"
    FIXTURE="$(mktemp -d)"
    SOURCE="$FIXTURE/source"
    TARGET="$FIXTURE/target"
    mkdir -p "$SOURCE/config" "$SOURCE/docs" "$TARGET"
    git -C "$TARGET" init -q
}

teardown() {
    rm -rf "$FIXTURE"
}

@test "release sync defaults to target index and explicit additions" {
    printf 'updated public\n' > "$SOURCE/README.md"
    printf 'must stay private\n' > "$SOURCE/unapproved-private.txt"
    printf 'approved addition\n' > "$SOURCE/docs/new-public.md"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["docs/new-public.md"]
}
JSON
    printf 'old public\n' > "$TARGET/README.md"
    git -C "$TARGET" add README.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    grep -q 'updated public' "$TARGET/README.md"
    grep -q 'approved addition' "$TARGET/docs/new-public.md"
    [ -f "$TARGET/config/github-public-release-files.json" ]
    [ ! -e "$TARGET/unapproved-private.txt" ]
    [[ "$output" == *"explicit_review_with_exact_candidate_manifest"* ]]
    [[ "$output" == *"unapproved-private.txt"* ]]
}

@test "release sync requires explicit review for new public runtime files" {
    mkdir -p "$SOURCE/scripts/lib" "$SOURCE/src/internal-skills/story-workflow" "$SOURCE/tests"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": []
}
JSON
    printf 'lib helper\n' > "$SOURCE/scripts/lib/brand-new-helper.js"
    printf 'public runner\n' > "$SOURCE/scripts/brand-new-runner.js"
    printf 'internal skill file\n' > "$SOURCE/src/internal-skills/story-workflow/brand-new.js"
    # V3 root test files
    printf 'bats test\n' > "$SOURCE/tests/test-brand-new.bats"
    printf 'mjs test\n' > "$SOURCE/tests/brand-new.test.mjs"
    printf 'js test\n' > "$SOURCE/tests/brand-new.test.js"
    printf 'baseline readme\n' > "$SOURCE/README.md"
    printf 'old readme\n' > "$TARGET/README.md"
    git -C "$TARGET" add README.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [ ! -e "$TARGET/scripts/lib/brand-new-helper.js" ]
    [ ! -e "$TARGET/scripts/brand-new-runner.js" ]
    [ ! -e "$TARGET/src/internal-skills/story-workflow/brand-new.js" ]
    [ ! -e "$TARGET/tests/test-brand-new.bats" ]
    [ ! -e "$TARGET/tests/brand-new.test.mjs" ]
    [ ! -e "$TARGET/tests/brand-new.test.js" ]
    [[ "$output" == *"scripts/lib/brand-new-helper.js"* ]]
    [[ "$output" == *"scripts/brand-new-runner.js"* ]]
    [[ "$output" == *"src/internal-skills/story-workflow/brand-new.js"* ]]
    [[ "$output" == *"tests/test-brand-new.bats"* ]]
    [[ "$output" == *"tests/brand-new.test.mjs"* ]]
    [[ "$output" == *"tests/brand-new.test.js"* ]]
}

@test "public policy carries the bundled install resolver required by self-update" {
    run node - "$REPO/config/github-public-release-files.json" <<'NODE'
const fs = require('fs');
const policy = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!Array.isArray(policy.additionalFiles)
    || !policy.additionalFiles.includes('skills/novel-assistant/scripts/lib/install-target-resolver.js')) {
  throw new Error('bundled install resolver is not explicitly approved');
}
NODE

    [ "$status" -eq 0 ]
}

@test "release sync fails closed when a public bundle source input is unapproved" {
    mkdir -p "$SOURCE/config" "$SOURCE/scripts" "$SOURCE/skills/novel-assistant" "$TARGET/config" "$TARGET/skills/novel-assistant"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": []
}
JSON
    cat > "$SOURCE/config/novel-assistant-bundle-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "bundleName": "novel-assistant",
  "internalSkills": [],
  "scriptFiles": ["public-helper.js"],
  "scriptDirectories": []
}
JSON
    printf '# public skill\n' > "$SOURCE/skills/novel-assistant/SKILL.md"
    printf 'module.exports = {};\n' > "$SOURCE/scripts/public-helper.js"
    cp "$SOURCE/config/novel-assistant-bundle-files.json" "$TARGET/config/novel-assistant-bundle-files.json"
    cp "$SOURCE/skills/novel-assistant/SKILL.md" "$TARGET/skills/novel-assistant/SKILL.md"
    git -C "$TARGET" add config/novel-assistant-bundle-files.json skills/novel-assistant/SKILL.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"public bundle source input missing from release policy"* ]]
    [[ "$output" == *"scripts/public-helper.js"* ]]
}

@test "release sync fails closed when a public bundled file is unapproved" {
    mkdir -p "$SOURCE/skills/novel-assistant/scripts" "$TARGET/skills/novel-assistant"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": []
}
JSON
    printf '# public skill\n' > "$SOURCE/skills/novel-assistant/SKILL.md"
    printf 'module.exports = {};\n' > "$SOURCE/skills/novel-assistant/scripts/public-helper.js"
    cp "$SOURCE/skills/novel-assistant/SKILL.md" "$TARGET/skills/novel-assistant/SKILL.md"
    git -C "$TARGET" add skills/novel-assistant/SKILL.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"public bundled file missing from release policy"* ]]
    [[ "$output" == *"skills/novel-assistant/scripts/public-helper.js"* ]]
}

@test "release sync fails closed when a public V3 runtime dependency is unapproved" {
    mkdir -p "$SOURCE/scripts/lib" "$TARGET/scripts"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": []
}
JSON
    cat > "$SOURCE/scripts/workflow-v3.js" <<'NODE'
require('./lib/runtime-helper');
NODE
    printf 'module.exports = {};\n' > "$SOURCE/scripts/lib/runtime-helper.js"
    printf 'old runner\n' > "$TARGET/scripts/workflow-v3.js"
    git -C "$TARGET" add scripts/workflow-v3.js

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"public runtime dependency missing from release policy"* ]]
    [[ "$output" == *"scripts/lib/runtime-helper.js"* ]]
    [ ! -e "$TARGET/scripts/lib/runtime-helper.js" ]
}

@test "release sync resolves a single-quoted runtime dependency without crossing later source text" {
    mkdir -p "$SOURCE/scripts/lib" "$TARGET/scripts"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["scripts/lib/runtime-helper.js", "scripts/lib/runtime-other.js"]
}
JSON
    cat > "$SOURCE/scripts/workflow-v3.js" <<'NODE'
require('./lib/runtime-helper');
const other = require('./lib/runtime-other');
NODE
    printf 'module.exports = {};\n' > "$SOURCE/scripts/lib/runtime-helper.js"
    printf 'module.exports = {};\n' > "$SOURCE/scripts/lib/runtime-other.js"
    printf 'old runner\n' > "$TARGET/scripts/workflow-v3.js"
    git -C "$TARGET" add scripts/workflow-v3.js

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"runtimeDependencyCount": 3'* ]]
    [ -f "$TARGET/scripts/lib/runtime-helper.js" ]
    [ -f "$TARGET/scripts/lib/runtime-other.js" ]
}

@test "release sync emits an exact candidate manifest for explicitly reviewed files" {
    mkdir -p "$SOURCE/scripts/lib/workflow-v3/sub" "$SOURCE/tests"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": [
    "scripts/lib/workflow-v3/runner.js",
    "scripts/lib/workflow-v3/sub/inner.js",
    "scripts/brand-v3-runner.js",
    "tests/test-workflow-v3-runner.bats",
    "tests/workflow-v3.test.mjs",
    "tests/workflow-v3.test.js"
  ]
}
JSON
    printf 'v3 runner\n' > "$SOURCE/scripts/lib/workflow-v3/runner.js"
    printf 'v3 sub\n' > "$SOURCE/scripts/lib/workflow-v3/sub/inner.js"
    printf 'public runner\n' > "$SOURCE/scripts/brand-v3-runner.js"
    # V3 root test
    printf 'bats v3 test\n' > "$SOURCE/tests/test-workflow-v3-runner.bats"
    printf 'v3 mjs test\n' > "$SOURCE/tests/workflow-v3.test.mjs"
    printf 'v3 js test\n' > "$SOURCE/tests/workflow-v3.test.js"

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [ -f "$TARGET/scripts/lib/workflow-v3/runner.js" ]
    [ -f "$TARGET/scripts/lib/workflow-v3/sub/inner.js" ]
    [ -f "$TARGET/scripts/brand-v3-runner.js" ]
    [ -f "$TARGET/tests/test-workflow-v3-runner.bats" ]
    [ -f "$TARGET/tests/workflow-v3.test.mjs" ]
    [ -f "$TARGET/tests/workflow-v3.test.js" ]
    candidate="$TARGET/config/github-public-release-candidate-manifest.json"
    [ -f "$candidate" ]
    node - "$candidate" "$TARGET" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [candidate, root] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(candidate, 'utf8'));
for (const relative of [
  'scripts/lib/workflow-v3/runner.js',
  'scripts/lib/workflow-v3/sub/inner.js',
  'scripts/brand-v3-runner.js',
]) {
  const expected = data.files?.[relative];
  const actual = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, relative))).digest('hex');
  if (expected !== actual) throw new Error(`missing or stale candidate digest: ${relative}`);
}
NODE
}

@test "release sync does NOT auto-approve private or fixture content" {
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": []
}
JSON
    mkdir -p "$SOURCE/tests/fixtures/local" "$SOURCE/src/private-internal-skills/private-addon"
    mkdir -p "$SOURCE/docs/reports" "$SOURCE/reports/private"
    mkdir -p "$SOURCE/skills/novel-assistant/references/private-internal-skills/private-addon-bundled"
    printf 'fixture\n' > "$SOURCE/tests/fixtures/local/secret.md"
    printf 'private addon\n' > "$SOURCE/src/private-internal-skills/private-addon/SKILL.md"
    printf 'bundled private\n' > "$SOURCE/skills/novel-assistant/references/private-internal-skills/private-addon-bundled/SKILL.md"
    printf 'private report\n' > "$SOURCE/docs/reports/leak.md"
    printf 'private local\n' > "$SOURCE/reports/private/leak.md"
    # Root-level unknowns that default-deny
    printf 'private root\n' > "$SOURCE/private-root-note.txt"
    printf 'baseline readme\n' > "$SOURCE/README.md"
    printf 'old readme\n' > "$TARGET/README.md"
    git -C "$TARGET" add README.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [ ! -e "$TARGET/tests/fixtures/local/secret.md" ]
    [ ! -e "$TARGET/src/private-internal-skills" ]
    [ ! -e "$TARGET/skills/novel-assistant/references/private-internal-skills" ]
    [ ! -e "$TARGET/docs/reports" ]
    [ ! -e "$TARGET/reports/private" ]
    [ ! -e "$TARGET/private-root-note.txt" ]
    [[ "$output" == *"tests/fixtures/local/secret.md"* ]]
    [[ "$output" == *"src/private-internal-skills/private-addon/SKILL.md"* ]]
    [[ "$output" == *"skills/novel-assistant/references/private-internal-skills/private-addon-bundled/SKILL.md"* ]]
    [[ "$output" == *"docs/reports/leak.md"* ]]
    [[ "$output" == *"reports/private/leak.md"* ]]
    [[ "$output" == *"private-root-note.txt"* ]]
    # The sync must report both hard-denied and unreviewed source files.
    [[ "$output" == *"skills/novel-assistant/references/private-internal-skills/"* ]]
    [[ "$output" == *"src/private-internal-skills/"* ]]
    [[ "$output" == *"tests/fixtures/"* ]]
}

@test "release sync permits an explicitly reviewed neutral fixture" {
    mkdir -p "$SOURCE/tests/fixtures/neutral"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["tests/fixtures/neutral/contract.json"]
}
JSON
    printf '{"kind":"neutral-contract"}\n' > "$SOURCE/tests/fixtures/neutral/contract.json"

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    grep -q 'neutral-contract' "$TARGET/tests/fixtures/neutral/contract.json"
}

@test "release sync hard deny overrides an explicitly reviewed bundled private path" {
    mkdir -p "$SOURCE/skills/novel-assistant/references/internal-skills/story-workflow"
    mkdir -p "$SOURCE/skills/novel-assistant/references/private-internal-skills/bundled-private"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": [
    "skills/novel-assistant/references/internal-skills/story-workflow/SKILL.md",
    "skills/novel-assistant/references/private-internal-skills/bundled-private/SKILL.md"
  ]
}
JSON
    printf 'public story-workflow\n' > "$SOURCE/skills/novel-assistant/references/internal-skills/story-workflow/SKILL.md"
    printf 'private bundled\n' > "$SOURCE/skills/novel-assistant/references/private-internal-skills/bundled-private/SKILL.md"

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [ -f "$TARGET/skills/novel-assistant/references/internal-skills/story-workflow/SKILL.md" ]
    [ ! -e "$TARGET/skills/novel-assistant/references/private-internal-skills" ]
    [[ "$output" == *"skills/novel-assistant/references/private-internal-skills/bundled-private/SKILL.md"* ]]
}

@test "release sync removedFiles overrides explicitly reviewed runtime files" {
    mkdir -p "$SOURCE/scripts/lib"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["scripts/lib/kept-helper.js"],
  "removedFiles": ["scripts/lib/revoked-helper.js"]
}
JSON
    printf 'revoked\n' > "$SOURCE/scripts/lib/revoked-helper.js"
    printf 'kept\n' > "$SOURCE/scripts/lib/kept-helper.js"
    printf 'baseline readme\n' > "$SOURCE/README.md"
    printf 'old readme\n' > "$TARGET/README.md"
    git -C "$TARGET" add README.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [ ! -e "$TARGET/scripts/lib/revoked-helper.js" ]
    [ -f "$TARGET/scripts/lib/kept-helper.js" ]
    [ -f "$SOURCE/scripts/lib/revoked-helper.js" ]
    [[ "$output" == *'"removedFiles": ['* ]]
    [[ "$output" == *"revoked-helper.js"* ]]
}

@test "release sync rejects unsafe explicit additions" {
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["../outside.txt"]
}
JSON

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"unsafe public release file"* ]]
}

@test "release sync rejects missing explicit additions" {
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["docs/missing-public.md"]
}
JSON

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"missing explicit public release file"* ]]
}

@test "release sync fails closed when its source tree contains a symbolic link" {
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": []
}
JSON
    printf 'baseline public\n' > "$SOURCE/README.md"
    ln -s /tmp "$SOURCE/unreviewed-link"
    printf 'old public\n' > "$TARGET/README.md"
    git -C "$TARGET" add README.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"symbolic link is not allowed in release source"* ]]
    [ ! -e "$TARGET/unreviewed-link" ]
}

@test "release sync can revoke a baseline file while keeping it in source" {
    printf 'updated public\n' > "$SOURCE/README.md"
    printf 'still private on main\n' > "$SOURCE/revoked-public.txt"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": [],
  "removedFiles": ["revoked-public.txt"]
}
JSON
    printf 'old public\n' > "$TARGET/README.md"
    printf 'old public copy\n' > "$TARGET/revoked-public.txt"
    git -C "$TARGET" add README.md revoked-public.txt

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [ -f "$SOURCE/revoked-public.txt" ]
    [ ! -e "$TARGET/revoked-public.txt" ]
    [[ "$output" == *'"removedFiles": ['* ]]
    [[ "$output" == *"revoked-public.txt"* ]]
}

@test "public sanitizer removes generic local user paths" {
    printf '%s\n' \
        'documented placeholder: <local-user-path>/project' \
        'linux example: <local-user-path>/project' > "$SOURCE/README.md"

    run node "$SANITIZE" --repo-root "$SOURCE" --write --json

    [ "$status" -eq 0 ]
    readme="$(<"$SOURCE/README.md")"
    [[ "$readme" == *"<local-user-path>/project"* ]]
    [[ "$readme" != *"<local-user-path>"* ]]
    [[ "$readme" != *"<local-user-path>"* ]]
}
