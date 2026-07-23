#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MIGRATE="$REPO/scripts/book-write-policy-migrate.js"
    COMMIT="$REPO/scripts/chapter-commit.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/legacy-book"
    mkdir -p "$BOOK/正文/第1卷" "$BOOK/追踪"
    printf '# 第一章\n旧书正文必须保持原样。\n' > "$BOOK/正文/第1卷/第001章_旧章.md"
    printf '# 当前上下文\n- 第二章需要回应门外脚步。\n' > "$BOOK/追踪/上下文.md"
}

teardown() {
    rm -rf "$TMP_DIR"
}

preview_id() {
    node -e 'const x=require(process.argv[1]); process.stdout.write(x.preview_id)' "$1"
}

confirm_migration() {
    local preview_file="$1"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$preview_file")" --confirm --json > "$TMP_DIR/confirm.json"
}

snapshot_id() {
    node -e 'const x=require(process.argv[1]); process.stdout.write(x.snapshot_id)' "$1"
}

apply_migration() {
    local confirmation_file="$1"
    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$(snapshot_id "$confirmation_file")" --json > "$TMP_DIR/apply.json"
}

@test "legacy preview is read-only and exposes a rollback snapshot plan" {
    before="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/preview.json"

    after="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
    [ ! -e "$BOOK/追踪/story-system/write-policy.json" ]
    node - "$TMP_DIR/preview.json" <<'NODE'
const fs=require('fs');
const preview=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(preview.status!=='legacy' || !preview.preview_id) throw new Error(JSON.stringify(preview));
if(preview.conflicts.length!==0 || !preview.rollback_snapshot || !preview.rollback_snapshot.snapshot_id) throw new Error(JSON.stringify(preview));
if(!preview.chapter_identities.some(item=>item.volume==='第1卷' && item.chapter===1)) throw new Error(JSON.stringify(preview.chapter_identities));
NODE
}

@test "migration ignores archived chapter copies when building canonical identities" {
    printf '# 第一章原稿\n旧版本。\n' > "$BOOK/正文/第1卷/第001章_原稿_20260622.md"
    mkdir -p "$BOOK/正文/第1卷/.deslop_backup_20260711"
    printf '# 第一章备份\n旧版本。\n' > "$BOOK/正文/第1卷/.deslop_backup_20260711/第001章_旧稿.md"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/preview.json"

    node - "$TMP_DIR/preview.json" <<'NODE'
const fs=require('fs');
const preview=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(preview.status!=='legacy') throw new Error(JSON.stringify(preview.conflicts));
if(preview.chapter_identities.length!==1 || preview.chapter_identities[0].path.includes('原稿') || preview.chapter_identities[0].path.includes('.deslop_backup')) throw new Error(JSON.stringify(preview.chapter_identities));
NODE
}

@test "confirmed apply creates strict transaction ledgers without rewriting legacy prose and is idempotent" {
    before="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/preview.json"
    confirm_migration "$TMP_DIR/preview.json"
    [ ! -e "$BOOK/追踪/story-system/write-policy.json" ]

    apply_migration "$TMP_DIR/confirm.json"
    after="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
    [ -d "$BOOK/追踪/story-system/transactions" ]
    [ -d "$BOOK/追踪/story-system/commits" ]
    [ -f "$BOOK/追踪/story-system/projection-log.jsonl" ]
    [ -f "$BOOK/追踪/story-system/chapter-identities.json" ]
    node - "$TMP_DIR/apply.json" "$BOOK/追踪/story-system/write-policy.json" <<'NODE'
const fs=require('fs');
const applied=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const policy=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(applied.status!=='strict_current' || policy.mode!=='strict') throw new Error(JSON.stringify({applied,policy}));
NODE

    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$(snapshot_id "$TMP_DIR/confirm.json")" --json > "$TMP_DIR/repeat.json"
    node -e 'const x=require(process.argv[1]); if(x.status!=="strict_current" || x.changed!==false) process.exit(1)' "$TMP_DIR/repeat.json"
}

@test "dirty tracking metadata and a concurrent writer block strict migration" {
    mkdir -p "$BOOK/追踪/story-system/transactions/tx-dirty"
    printf '{"status":"prepared"}\n' > "$BOOK/追踪/story-system/transactions/tx-dirty/transaction.json"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/dirty.json"
    node -e 'const x=require(process.argv[1]); if(x.status!=="strict_blocked" || !x.conflicts.some(c=>c.code==="dirty_transaction_metadata")) process.exit(1)' "$TMP_DIR/dirty.json"

    rm -rf "$BOOK/追踪/story-system/transactions"
    mkdir -p "$BOOK/追踪/story-system/.write.lock"
    printf '{"owner":"another-writer","acquired_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BOOK/追踪/story-system/.write.lock/owner.json"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/locked.json"
    node -e 'const x=require(process.argv[1]); if(x.status!=="strict_blocked" || !x.conflicts.some(c=>c.code==="book_write_lease_active")) process.exit(1)' "$TMP_DIR/locked.json"
    run node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/locked.json")" --confirm --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_book_write_locked'* ]]
}

@test "missing legacy chapter identity blocks confirmation before metadata changes" {
    rm -rf "$BOOK/正文"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/preview.json"
    node -e 'const x=require(process.argv[1]); if(x.status!=="strict_blocked" || !x.conflicts.some(c=>c.code==="missing_chapter_identity")) process.exit(1)' "$TMP_DIR/preview.json"
    run node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/preview.json")" --confirm --json
    [ "$status" -ne 0 ]
    [ ! -e "$BOOK/追踪/story-system/write-policy.json" ]
}

@test "rollback restores legacy metadata and never rewrites prose" {
    before="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/preview.json"
    confirm_migration "$TMP_DIR/preview.json"
    apply_migration "$TMP_DIR/confirm.json"

    node "$MIGRATE" rollback --project-root "$BOOK" --snapshot "$(snapshot_id "$TMP_DIR/confirm.json")" --confirm --json > "$TMP_DIR/rollback.json"

    after="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
    [ ! -e "$BOOK/追踪/story-system/write-policy.json" ]
    [ ! -e "$BOOK/追踪/story-system/chapter-identities.json" ]
    node -e 'const x=require(process.argv[1]); if(x.status!=="rolled_back") process.exit(1)' "$TMP_DIR/rollback.json"
}

@test "a newly accepted chapter on a migrated book records immutable commit and current memory hashes" {
    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/preview.json"
    confirm_migration "$TMP_DIR/preview.json"
    apply_migration "$TMP_DIR/confirm.json"
    mkdir -p "$BOOK/追踪/staging"
    printf '# 第二章\n门外脚步停在窗前。\n' > "$BOOK/追踪/staging/正文.md"
    printf '# 当前上下文\n- 第三章追查脚步来源。\n' > "$BOOK/追踪/staging/上下文.md"
    cat > "$BOOK/追踪/staging/manifest.json" <<'JSON'
{"workflow_id":"wf-migrated-book","volume":"第1卷","chapter":2,"artifacts":[{"role":"chapter_prose","staged":"追踪/staging/正文.md","target":"正文/第1卷/第002章_新章.md","required":true},{"role":"story_context","staged":"追踪/staging/上下文.md","target":"追踪/上下文.md","required":true}],"gates":{"output_health":"pass","prose_quality":"pass","story_drift":"pass"}}
JSON

    node "$COMMIT" prepare --project-root "$BOOK" --manifest "$BOOK/追踪/staging/manifest.json" --json > "$TMP_DIR/prepare.json"
    tx="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.transaction_id)' "$TMP_DIR/prepare.json")"
    node "$COMMIT" accept --project-root "$BOOK" --transaction "$tx" --json > "$TMP_DIR/accept.json"
    commit="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.commit_id)' "$TMP_DIR/accept.json")"

    node - "$TMP_DIR/accept.json" "$BOOK/追踪/story-system/projection-log.jsonl" "$BOOK/追踪/memory/migration-state.json" "$BOOK/追踪/story-system/commits/$commit.json" <<'NODE'
const fs=require('fs');
const accepted=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const projection=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse).at(-1);
const memory=JSON.parse(fs.readFileSync(process.argv[4],'utf8'));
const commit=JSON.parse(fs.readFileSync(process.argv[5],'utf8'));
if(accepted.status!=='accepted' || projection.status!=='projection_current') throw new Error(JSON.stringify({accepted,projection}));
if(commit.status!=='accepted' || !commit.commit_id || commit.chapter!==2) throw new Error(JSON.stringify(commit));
if(memory.status!=='current' || memory.last_commit_id!==commit.commit_id || !memory.sources.some(item=>item.path==='追踪/上下文.md' && item.hash.startsWith('sha256:'))) throw new Error(JSON.stringify(memory));
NODE
    node "$COMMIT" inspect --project-root "$BOOK" --volume 第1卷 --chapter 2 --json > "$TMP_DIR/inspect.json"
    node -e 'const x=require(process.argv[1]); if(x.commit_count!==1 || x.latest_commit.status!=="accepted") process.exit(1)' "$TMP_DIR/inspect.json"
    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/strict-preview.json"
    node -e 'const x=require(process.argv[1]); if(x.status!=="strict_current" || x.conflicts.length!==0) process.exit(1)' "$TMP_DIR/strict-preview.json"
}
