#!/usr/bin/env bats
# tests/test-production-smoke-matrix.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/production-smoke-matrix.js"
    README="$REPO/README.md"
    BUNDLE_NOVEL="$REPO/skills/novel-assistant"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "production smoke matrix passes all core router workflow cases" {
    node "$SCRIPT" --repo-root "$REPO" --json > "$TMP_DIR/matrix.json"

    grep -q '"status": "pass"' "$TMP_DIR/matrix.json"
    grep -q '"caseCount": 22' "$TMP_DIR/matrix.json"
    grep -q '"workflowTemplateCount": 14' "$TMP_DIR/matrix.json"
    grep -q '"workflowBundleTemplateCount": 14' "$TMP_DIR/matrix.json"
    grep -q '"workflowTemplateDrift": false' "$TMP_DIR/matrix.json"
    for id in short_write long_write review analyze deslop setup update_check story_memory_context long_scan short_scan short_analyze cover; do
        grep -q "\"id\": \"$id\"" "$TMP_DIR/matrix.json"
    done
    for id in longform_lifecycle_new_book longform_lifecycle_existing_book longform_volume_review longform_feedback_rollback longform_structure_expansion longform_cross_volume_handoff longform_lifecycle_migration; do
        grep -q "\"id\": \"$id\"" "$TMP_DIR/matrix.json"
    done
    grep -q '"id": "long_write_detail_outline_quality"' "$TMP_DIR/matrix.json"
    grep -q '"id": "short_writing_profile"' "$TMP_DIR/matrix.json"
    grep -q '"id": "host_discovery"' "$TMP_DIR/matrix.json"
    grep -q '"router"' "$TMP_DIR/matrix.json"
    grep -q '"workflow"' "$TMP_DIR/matrix.json"
    grep -q '"module"' "$TMP_DIR/matrix.json"
    grep -q '"bundle"' "$TMP_DIR/matrix.json"
    grep -q '"globalChecks"' "$TMP_DIR/matrix.json"
    grep -q '"id": "single_entry_ux"' "$TMP_DIR/matrix.json"
    grep -q '"id": "numbered_candidates_ux"' "$TMP_DIR/matrix.json"
    grep -q '"id": "host_select_ux"' "$TMP_DIR/matrix.json"
    grep -q '"id": "update_gate_ux"' "$TMP_DIR/matrix.json"
    grep -q '"id": "token_cost_governance"' "$TMP_DIR/matrix.json"
    grep -q '"id": "AI_native_absorption"' "$TMP_DIR/matrix.json"
}

@test "production smoke matrix executes adaptive detail outline quality gate" {
    node "$SCRIPT" --repo-root "$REPO" --json > "$TMP_DIR/matrix.json"

    node - "$TMP_DIR/matrix.json" <<'NODE'
const result = require(process.argv[2]);
const item = result.cases.find(candidate => candidate.id === 'long_write_detail_outline_quality');
if (!item) throw new Error('missing long_write_detail_outline_quality smoke case');
if (item.status !== 'pass') throw new Error(JSON.stringify(item.findings, null, 2));
if (!item.checks.some(check => check.layer === 'runtime')) {
  throw new Error('detail outline quality smoke did not execute the runtime gate');
}
if (!item.checks.some(check => check.layer === 'bundle')) {
  throw new Error('detail outline quality smoke did not verify the built bundle');
}
NODE
}

@test "production smoke matrix executes longform lifecycle production cases" {
    node "$SCRIPT" --repo-root "$REPO" --json > "$TMP_DIR/matrix.json"

    node - "$TMP_DIR/matrix.json" <<'NODE'
const result = require(process.argv[2]);
const expected = [
  'longform_lifecycle_new_book',
  'longform_lifecycle_existing_book',
  'longform_volume_review',
  'longform_feedback_rollback',
  'longform_structure_expansion',
  'longform_cross_volume_handoff',
  'longform_lifecycle_migration',
];
const cases = new Map(result.cases.map(item => [item.id, item]));
for (const id of expected) {
  const item = cases.get(id);
  if (!item) throw new Error(`missing production case: ${id}`);
  if (item.status !== 'pass') throw new Error(`production case failed: ${id}`);
  if (!item.checks.some(check => check.layer === 'bundle')) {
    throw new Error(`production case did not verify bundle: ${id}`);
  }
}
NODE
}

@test "production smoke matrix detects lifecycle migration runtime regressions" {
    cp -R "$REPO" "$TMP_DIR/repo"
    for script in scripts/workflow-legacy-migrate.js skills/novel-assistant/scripts/workflow-legacy-migrate.js; do
        perl -0pi -e "s/status: 'migration_preview'/status: 'migration_preview_broken'/g" "$TMP_DIR/repo/$script"
    done

    status=0
    node "$TMP_DIR/repo/scripts/production-smoke-matrix.js" --repo-root "$TMP_DIR/repo" --json > "$TMP_DIR/migration-runtime-fail.json" || status=$?

    [ "$status" -eq 2 ]
    node - "$TMP_DIR/migration-runtime-fail.json" <<'NODE'
const result = require(process.argv[2]);
const finding = result.findings.find((item) => item.caseId === 'longform_lifecycle_migration'
  && item.layer === 'runtime'
  && /preview status/.test(item.message));
if (!finding) throw new Error(JSON.stringify(result.findings, null, 2));
NODE
}

@test "production smoke matrix executes unknown-source write blocking in the bundled migrator" {
    cp -R "$REPO" "$TMP_DIR/repo"
    perl -0pi -e "s/blocked_lifecycle_migration_source_unknown/blocked_lifecycle_migration_source_unknown_broken/g" "$TMP_DIR/repo/skills/novel-assistant/scripts/workflow-legacy-migrate.js"

    status=0
    node "$TMP_DIR/repo/scripts/production-smoke-matrix.js" --repo-root "$TMP_DIR/repo" --json > "$TMP_DIR/bundle-unknown-source-fail.json" || status=$?

    [ "$status" -eq 2 ]
    node - "$TMP_DIR/bundle-unknown-source-fail.json" <<'NODE'
const result = require(process.argv[2]);
const finding = result.findings.find((item) => item.caseId === 'longform_lifecycle_migration'
  && item.layer === 'runtime'
  && /bundle unknown source was not blocked/.test(item.message));
if (!finding) throw new Error(JSON.stringify(result.findings, null, 2));
NODE
}

@test "production smoke matrix detects bundled workflow state machine semantic drift" {
    cp -R "$REPO" "$TMP_DIR/repo"
    perl -0pi -e 's/交接已验证的封面产物与路径/交接发生漂移的封面产物与路径/' "$TMP_DIR/repo/skills/novel-assistant/scripts/lib/workflow-template-registry.js"

    status=0
    node "$TMP_DIR/repo/scripts/production-smoke-matrix.js" --repo-root "$TMP_DIR/repo" --json > "$TMP_DIR/drift.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "fail"' "$TMP_DIR/drift.json"
    grep -q 'bundled workflow templates drift from source' "$TMP_DIR/drift.json"
}

@test "production smoke matrix fails when a required router rule is missing" {
    cp -R "$REPO" "$TMP_DIR/repo"
    perl -0pi -e 's/短篇写作路由补充/短篇写作路由缺失/g' "$TMP_DIR/repo/src/internal-skills/story/SKILL.md"

    status=0
    node "$TMP_DIR/repo/scripts/production-smoke-matrix.js" --repo-root "$TMP_DIR/repo" --json > "$TMP_DIR/fail.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "fail"' "$TMP_DIR/fail.json"
    grep -q '"caseId": "short_write"' "$TMP_DIR/fail.json"
    grep -q '"target": "src/internal-skills/story/SKILL.md"' "$TMP_DIR/fail.json"
}

@test "production smoke matrix validates progressive workflow references" {
    cp -R "$REPO" "$TMP_DIR/repo"
    perl -0pi -e 's/短篇不套长篇 Chapter Contract/短篇规则缺失/g' "$TMP_DIR/repo/src/internal-skills/story-workflow/references/canonical-write-protocol.md"

    status=0
    node "$TMP_DIR/repo/scripts/production-smoke-matrix.js" --repo-root "$TMP_DIR/repo" --json > "$TMP_DIR/reference-fail.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "fail"' "$TMP_DIR/reference-fail.json"
    grep -q 'canonical-write-protocol.md' "$TMP_DIR/reference-fail.json"
    grep -q '短篇不套长篇 Chapter Contract' "$TMP_DIR/reference-fail.json"
}

@test "production smoke matrix is documented and bundled" {
    grep -q "生产验收矩阵" "$README"
    grep -q "production-smoke-matrix.js" "$README"
    grep -q "短篇、长篇、审阅、拆文、去 AI、setup、更新检查" "$README"
    test -x "$SCRIPT"
    test -x "$BUNDLE_NOVEL/scripts/production-smoke-matrix.js"
    test -x "$BUNDLE_NOVEL/scripts/token-cost-ledger.js"
}
