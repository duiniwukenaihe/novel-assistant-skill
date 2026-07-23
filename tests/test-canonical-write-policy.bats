#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/canonical-write-policy.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/正文/第1卷" "$BOOK/追踪/story-system"
    printf '# 第一章\n' > "$BOOK/正文/第1卷/第001章.md"
}

teardown() {
    rm -rf "$TMP_DIR"
}

enable_strict_policy() {
    cat > "$BOOK/追踪/story-system/write-policy.json" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "mode": "strict"
}
JSON
}

@test "strict mode rejects direct canonical write" {
    enable_strict_policy

    run node "$SCRIPT" check --project-root "$BOOK" --target "正文/第1卷/第001章.md" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_canonical_transaction_required'* ]]
}

@test "legacy mode permits a direct canonical write check" {
    run node "$SCRIPT" check --project-root "$BOOK" --target "正文/第1卷/第001章.md" --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "allowed_with_risk"'* ]]
    [[ "$output" == *'"mode": "legacy"'* ]]
    [[ "$output" == *'"warning": "legacy_canonical_write_unprotected"'* ]]
    [[ "$output" == *'"migrate_hint"'* ]]
}

@test "legacy mode permits noncanonical targets without a migration warning" {
    run node "$SCRIPT" check --project-root "$BOOK" --target "追踪/staging/正文.md" --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "allowed"'* ]]
    [[ "$output" != *'"migrate_hint"'* ]]
}

@test "strict mode covers every canonical story asset class" {
    enable_strict_policy

    run node "$SCRIPT" check --project-root "$BOOK" --target "追踪/staging/正文.md" --json
    [ "$status" -eq 0 ]

    local target
    for target in \
        "正文/第1卷/第001章.md" \
        "正文.md" \
        "设定.md" \
        "小节大纲.md" \
        "大纲/第1卷.md" \
        "追踪/伏笔.md" \
        "追踪/时间线.md" \
        "追踪/角色状态.md" \
        "追踪/上下文.md" \
        "追踪/memory/角色.md" \
        "追踪/交接包/第001章.md"; do
        run node "$SCRIPT" check --project-root "$BOOK" --target "$target" --json
        [ "$status" -eq 1 ]
        [[ "$output" == *'blocked_canonical_transaction_required'* ]]

    done
}

@test "strict mode verifies a prepared transaction and its target before allowing a write" {
    enable_strict_policy
    mkdir -p "$BOOK/追踪/staging"
    mkdir -p "$BOOK/追踪/workflow/tasks/policy-test" "$BOOK/追踪/workflow/families/policy-family"
    printf 'setting draft\n' > "$BOOK/追踪/staging/setting.md"
    printf '%s\n' '{"workflow_id":"policy-test","source_kind":"canonical","volume":"short","chapter":1,"gates":{"output_health":"pass","prose_quality":"pass","story_drift":"pass"},"artifacts":[{"role":"setting","staged":"追踪/staging/setting.md","target":"设定.md"}]}' > "$BOOK/追踪/staging/manifest.json"
    printf '%s\n' '{"workflow_id":"policy-test","workflow_type":"long_write","task_family_id":"policy-family","branch_id":"policy-test","task_dir":"追踪/workflow/tasks/policy-test","state_version":1,"current_stage":"chapter_commit","stage_execution":{"stage_id":"chapter_commit","status":"running","stage_attempt_id":"sa-policy"}}' > "$BOOK/追踪/workflow/tasks/policy-test/task.json"
    printf '%s\n' '{"task_family_id":"policy-family","head_workflow_id":"policy-test","branches":[{"workflow_id":"policy-test","status":"active","is_head":true}]}' > "$BOOK/追踪/workflow/families/policy-family/family.json"
    node "$REPO/scripts/chapter-commit.js" prepare --project-root "$BOOK" --manifest "$BOOK/追踪/staging/manifest.json" --json > "$TMP_DIR/prepare.json"
    tx="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.transaction_id)' "$TMP_DIR/prepare.json")"

    run node "$SCRIPT" check --project-root "$BOOK" --target "设定.md" --transaction-id tx-forged --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_canonical_transaction_invalid'* ]]

    mkdir -p "$BOOK/追踪/story-system/transactions/tx-schema-forged"
    printf '%s\n' "{\"schemaVersion\":\"1.0.0\",\"transaction_id\":\"tx-schema-forged\",\"status\":\"prepared\",\"project_root\":\"$BOOK\",\"artifacts\":[{\"target\":\"设定.md\",\"staged\":\"追踪/story-system/transactions/tx-schema-forged/staged/001-setting.md\",\"content_hash\":\"sha256:forged\"}]}" > "$BOOK/追踪/story-system/transactions/tx-schema-forged/transaction.json"
    run node "$SCRIPT" check --project-root "$BOOK" --target "设定.md" --transaction-id tx-schema-forged --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_canonical_transaction_invalid'* ]]

    run node "$SCRIPT" check --project-root "$BOOK" --target "正文.md" --transaction-id "$tx" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_canonical_transaction_target_mismatch'* ]]

    run node "$SCRIPT" check --project-root "$BOOK" --target "设定.md" --transaction-id "$tx" --json
    [ "$status" -eq 0 ]
}

@test "Windows absolute path strings normalize only when they remain under the Windows project root" {
    run node -e 'const p=require(process.argv[1]); if(!p.normalizeWindowsTarget || p.normalizeWindowsTarget("C:\\\\book", "C:\\\\book\\\\正文\\\\第1卷\\\\第001章.md") !== "正文/第1卷/第001章.md") process.exit(1)' "$REPO/scripts/lib/canonical-write-policy.js"
    [ "$status" -eq 0 ]

    run node -e 'const p=require(process.argv[1]); try { p.normalizeWindowsTarget("C:\\\\book", "D:\\\\other\\\\正文.md"); process.exit(1); } catch (e) { process.exit(e.code === "blocked_unsafe_target" ? 0 : 1); }' "$REPO/scripts/lib/canonical-write-policy.js"
    [ "$status" -eq 0 ]
}

@test "canonical targets normalize in-root absolute paths and reject escapes" {
    enable_strict_policy

    run node "$SCRIPT" check --project-root "$BOOK" --target "$BOOK/正文/第1卷/第001章.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'"正文/第1卷/第001章.md"'* ]]
    [[ "$output" != *"$BOOK/正文"* ]]

    run node "$SCRIPT" check --project-root "$BOOK" --target "正文/../../outside.md" --transaction-id tx-001 --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_unsafe_target'* ]]

    run node "$SCRIPT" check --project-root "$BOOK" --target "$TMP_DIR/outside.md" --transaction-id tx-001 --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_unsafe_target'* ]]
}

@test "second writer cannot acquire same chapter lease" {
    node "$SCRIPT" lease --project-root "$BOOK" --volume 1 --chapter 1 --owner first --json > "$TMP_DIR/first.json"

    run node "$SCRIPT" lease --project-root "$BOOK" --volume 1 --chapter 1 --owner second --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_chapter_lease_conflict'* ]]
}

@test "expired chapter lease can be taken over and an old token cannot release it" {
    node "$SCRIPT" lease --project-root "$BOOK" --volume 1 --chapter 1 --owner first --json > "$TMP_DIR/first.json"
    first_token="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.lease.token)' "$TMP_DIR/first.json")"
    node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const file = path.join(process.argv[2], '追踪', 'story-system', 'leases', '1-1.json');
const lease = JSON.parse(fs.readFileSync(file, 'utf8'));
lease.expiresAt = '2000-01-01T00:00:00.000Z';
fs.writeFileSync(file, `${JSON.stringify(lease)}\n`);
NODE

    node "$SCRIPT" lease --project-root "$BOOK" --volume 1 --chapter 1 --owner second --json > "$TMP_DIR/second.json"
    second_token="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.lease.token)' "$TMP_DIR/second.json")"

    run node "$SCRIPT" release --project-root "$BOOK" --volume 1 --chapter 1 --token "$first_token" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_chapter_lease_ownership'* ]]

    node "$SCRIPT" release --project-root "$BOOK" --volume 1 --chapter 1 --token "$second_token" --json
    [ ! -e "$BOOK/追踪/story-system/leases/1-1.json" ]
}

@test "a concurrent old release cannot delete a replacement lease" {
    node "$SCRIPT" lease --project-root "$BOOK" --volume 1 --chapter 1 --owner first --json > "$TMP_DIR/first.json"
    first_token="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.lease.token)' "$TMP_DIR/first.json")"
    node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const file = path.join(process.argv[2], '追踪', 'story-system', 'leases', '1-1.json');
const lease = JSON.parse(fs.readFileSync(file, 'utf8'));
lease.expiresAt = '2000-01-01T00:00:00.000Z';
fs.writeFileSync(file, `${JSON.stringify(lease)}\n`);
NODE

    node - "$SCRIPT" "$REPO/scripts/lib/workflow-state-store.js" "$BOOK" "$first_token" <<'NODE'
const { spawn } = require('child_process');
const [script, storeFile, book, oldToken] = process.argv.slice(2);
function run(args) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [script, ...args]);
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.on('close', status => resolve({ status, output }));
  });
}
(async () => {
  const worker = spawn(process.execPath, ['-e', `
    const store = require(process.argv[1]);
    const release = store.acquireChapterWriteLease(process.argv[2], { volume: '1', chapter: 1 }, 'second');
    process.stdout.write(JSON.stringify(release.lease) + '\\n');
    process.stdin.once('end', () => process.exit(0));
  `, storeFile, book], { stdio: ['pipe', 'pipe', 'inherit'] });
  let output = '';
  await new Promise((resolve, reject) => {
    worker.stdout.on('data', chunk => {
      output += chunk;
      if (output.includes('\n')) resolve();
    });
    worker.on('error', reject);
    worker.on('exit', status => { if (status !== 0 && !output) reject(new Error(`takeover worker exited ${status}`)); });
  });
  const replacement = JSON.parse(output);
  const release = await run(['release', '--project-root', book, '--volume', '1', '--chapter', '1', '--token', oldToken, '--json']);
  if (release.status === 0) throw new Error(`old release unexpectedly succeeded: ${release.output}`);
  const current = require('fs').readFileSync(replacementFile(book), 'utf8');
  if (JSON.parse(current).token !== replacement.token) throw new Error('replacement lease was removed or replaced');
  worker.stdin.end();
  await new Promise(resolve => worker.on('close', resolve));
})().catch(error => { console.error(error.stack || error); process.exit(1); });
function replacementFile(root) { return require('path').join(root, '追踪', 'story-system', 'leases', '1-1.json'); }
NODE
}

@test "two concurrent stale takeovers allow exactly one writer" {
    node "$SCRIPT" lease --project-root "$BOOK" --volume 1 --chapter 1 --owner first --json > "$TMP_DIR/first.json"
    node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const file = path.join(process.argv[2], '追踪', 'story-system', 'leases', '1-1.json');
const lease = JSON.parse(fs.readFileSync(file, 'utf8'));
lease.expiresAt = '2000-01-01T00:00:00.000Z';
fs.writeFileSync(file, `${JSON.stringify(lease)}\n`);
NODE

    node - "$SCRIPT" "$BOOK" <<'NODE'
const { spawn } = require('child_process');
const [script, book] = process.argv.slice(2);
function run(owner) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [script, 'lease', '--project-root', book, '--volume', '1', '--chapter', '1', '--owner', owner, '--json']);
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.on('close', status => resolve({ status, output }));
  });
}
(async () => {
  const results = await Promise.all([run('takeover-a'), run('takeover-b')]);
  const winners = results.filter(result => result.status === 0);
  const blocked = results.filter(result => result.status !== 0 && result.output.includes('blocked_chapter_lease_conflict'));
  if (winners.length !== 1 || blocked.length !== 1) throw new Error(JSON.stringify(results));
  const current = JSON.parse(require('fs').readFileSync(require('path').join(book, '追踪', 'story-system', 'leases', '1-1.json'), 'utf8'));
  if (current.token !== JSON.parse(winners[0].output).lease.token) throw new Error('winner token is not current lease');
})().catch(error => { console.error(error.stack || error); process.exit(1); });
NODE
}

@test "a stale per-lease guard is recovered before lease acquisition" {
    guard="$BOOK/追踪/story-system/leases/1-1.json.guard"
    mkdir -p "$guard"
    cat > "$guard/owner.json" <<'JSON'
{"token":"dead","acquiredAt":"2000-01-01T00:00:00.000Z"}
JSON

    node "$SCRIPT" lease --project-root "$BOOK" --volume 1 --chapter 1 --owner recovered --json > "$TMP_DIR/recovered.json"

    [ ! -e "$guard" ]
    node -e 'const x=require(process.argv[1]); if(x.lease.owner!=="recovered") process.exit(1)' "$TMP_DIR/recovered.json"
}
