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

setup_selection_fixture() {
    ALT_PATH='正文/第1卷/第001章_修订稿.md'
    printf '# 第一章\n修订稿正文仍须保持原样。\n' > "$BOOK/$ALT_PATH"
    mkdir -p "$BOOK/追踪/schema"
    printf '%s\n%s\n' \
      '{"volume":"第1卷", "volumeChapterNo":1, "draftPath":"正文/第1卷/第001章_旧章.md", "note":"schema-keep"}' \
      '{"volume":"第2卷","volumeChapterNo":9,"draftPath":"正文/第2卷/第009章_保留.md","note":"untouched-schema"}' \
      > "$BOOK/追踪/schema/chapters.jsonl"
    printf '%s\n%s\n' \
      '{"volume":"第1卷","volumeChapterNo":1,"draftPath":"正文/第1卷/第001章_修订稿.md","note":"asset-keep"}' \
      '{"volume":"第2卷","volumeChapterNo":9,"draftPath":"正文/第2卷/第009章_保留.md","note":"untouched-asset"}' \
      > "$BOOK/追踪/章节资产.jsonl"
    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/initial-selection-preview.json"
}

write_valid_selection_manifest() {
    local output_file="${1:-$TMP_DIR/selection.json}"
    SELECTED_PATH="$ALT_PATH" node - "$TMP_DIR/initial-selection-preview.json" "$output_file" <<'NODE'
const fs = require('fs');
const preview = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const conflict = preview.conflicts.find(item => item.code === 'duplicate_chapter_identity');
const selected = conflict && conflict.candidates.find(item => item.path === process.env.SELECTED_PATH);
if (!selected) throw new Error(JSON.stringify(preview));
fs.writeFileSync(process.argv[3], JSON.stringify({
  schemaVersion: '1.0.0',
  preview_id: preview.preview_id,
  source_fingerprint: preview.source_fingerprint,
  selections: [{
    volume: selected.volume,
    chapter: selected.chapter,
    path: selected.path,
    content_hash: selected.content_hash,
  }],
}, null, 2) + '\n');
NODE
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

@test "migration chapter discovery ignores symlinked files and directories even when they are unique" {
    outside_file="$TMP_DIR/第002章_项目外正文.md"
    printf '# 第二章\n项目外文件不能成为正文权威。\n' > "$outside_file"
    ln -s "$outside_file" "$BOOK/正文/第1卷/第002章_链接.md"
    outside_dir="$TMP_DIR/项目外卷"
    mkdir -p "$outside_dir"
    printf '# 第三章\n项目外目录不能被递归扫描。\n' > "$outside_dir/第003章_外部.md"
    ln -s "$outside_dir" "$BOOK/正文/第2卷"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/symlink-discovery.json"

    node - "$TMP_DIR/symlink-discovery.json" <<'NODE'
const fs=require('fs'),out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='legacy'||out.conflicts.length!==0) throw new Error(JSON.stringify(out));
if(out.chapter_identities.length!==1||out.chapter_identities[0].chapter!==1) throw new Error(JSON.stringify(out.chapter_identities));
if(out.chapter_identities.some((item)=>item.path.includes('链接')||item.path.includes('第2卷'))) throw new Error(JSON.stringify(out.chapter_identities));
NODE
}

@test "phase A legacy-flat-layout archive-only prose stays unchanged and leaves no active identity" {
    rm -f "$BOOK/正文/第1卷/第001章_旧章.md"
    mkdir -p "$BOOK/正文/legacy-flat-layout/第1卷"
    archived="$BOOK/正文/legacy-flat-layout/第1卷/第001章_归档.md"
    printf '# 第一章\n归档正文保持原样。\n' > "$archived"
    before="$(shasum -a 256 "$archived" | awk '{print $1}')"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/phase-a-archive.json"

    after="$(shasum -a 256 "$archived" | awk '{print $1}')"
    [ -f "$archived" ]
    [ "$before" = "$after" ]
    node - "$TMP_DIR/phase-a-archive.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'strict_blocked') throw new Error(JSON.stringify(out));
if (!out.conflicts.some(item => item.code === 'missing_active_chapter_identity')) throw new Error(JSON.stringify(out.conflicts));
if (out.chapter_identities.length !== 0) throw new Error(JSON.stringify(out.chapter_identities));
NODE
}

@test "phase A matching schema and asset authorities auto-resolve one duplicate identity" {
    current='正文/第1卷/第001章_当前稿.md'
    printf '# 第一章\n当前正文。\n' > "$BOOK/$current"
    mkdir -p "$BOOK/追踪/schema"
    printf '%s\n' "{\"volume\":\"第1卷\",\"volumeChapterNo\":1,\"draftPath\":\"$current\"}" > "$BOOK/追踪/schema/chapters.jsonl"
    printf '%s\n' "{\"volume\":\"第1卷\",\"volumeChapterNo\":1,\"draftPath\":\"$current\"}" > "$BOOK/追踪/章节资产.jsonl"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/phase-a-matching.json"

    CURRENT="$current" node - "$TMP_DIR/phase-a-matching.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'legacy' || out.conflicts.length !== 0) throw new Error(JSON.stringify(out));
if (out.chapter_identities.length !== 1 || out.chapter_identities[0].path !== process.env.CURRENT) throw new Error(JSON.stringify(out.chapter_identities));
if (JSON.stringify(out.chapter_identities[0].authority_sources) !== JSON.stringify(['asset', 'schema'])) throw new Error(JSON.stringify(out.chapter_identities[0]));
NODE
}

@test "phase A conflicting authorities emit one readable grouped duplicate conflict" {
    other='正文/第1卷/第001章_另一稿.md'
    printf '# 第一章\n另一份正文。\n' > "$BOOK/$other"
    mkdir -p "$BOOK/追踪/schema"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":1,"draftPath":"正文/第1卷/第001章_旧章.md"}' > "$BOOK/追踪/schema/chapters.jsonl"
    printf '%s\n' "{\"volume\":\"第1卷\",\"volumeChapterNo\":1,\"draftPath\":\"$other\"}" > "$BOOK/追踪/章节资产.jsonl"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/phase-a-conflicting.json"

    node - "$TMP_DIR/phase-a-conflicting.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const duplicates = out.conflicts.filter(item => item.code === 'duplicate_chapter_identity');
if (out.status !== 'strict_blocked' || duplicates.length !== 1) throw new Error(JSON.stringify(out));
const conflict = duplicates[0];
if (conflict.volume !== '第1卷' || conflict.chapter !== 1 || conflict.candidates.length !== 2) throw new Error(JSON.stringify(conflict));
if (!String(conflict.message || '').includes('系统不会替作者选择')) throw new Error(JSON.stringify(conflict));
for (const candidate of conflict.candidates) {
  if (!candidate.path || !/^sha256:[0-9a-f]{64}$/.test(candidate.content_hash)) throw new Error(JSON.stringify(candidate));
  if (!Number.isInteger(candidate.char_count) || candidate.char_count < 1) throw new Error(JSON.stringify(candidate));
  if (!candidate.mtime || !Array.isArray(candidate.authority_sources)) throw new Error(JSON.stringify(candidate));
}
const sources = conflict.candidates.flatMap(item => item.authority_sources).sort();
if (JSON.stringify(sources) !== JSON.stringify(['asset', 'schema'])) throw new Error(JSON.stringify(conflict.candidates));
NODE
}

@test "phase A asset-only authority cannot choose between duplicate live prose" {
    current='正文/第1卷/第001章_当前稿.md'
    printf '# 第一章\n当前正文。\n' > "$BOOK/$current"
    printf '%s\n' "{\"volume\":\"第1卷\",\"volumeChapterNo\":1,\"draftPath\":\"$current\"}" > "$BOOK/追踪/章节资产.jsonl"

    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/phase-a-asset-only.json"

    CURRENT="$current" node - "$TMP_DIR/phase-a-asset-only.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const duplicates = out.conflicts.filter(item => item.code === 'duplicate_chapter_identity');
if (out.status !== 'strict_blocked' || duplicates.length !== 1) throw new Error(JSON.stringify(out));
const chosen = duplicates[0].candidates.find(item => item.path === process.env.CURRENT);
if (!chosen || JSON.stringify(chosen.authority_sources) !== JSON.stringify(['asset'])) throw new Error(JSON.stringify(duplicates[0]));
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
    node -e 'const x=require(process.argv[1]); if(x.status!=="strict_blocked" || !x.conflicts.some(c=>c.code==="missing_active_chapter_identity")) process.exit(1)' "$TMP_DIR/preview.json"
    run node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/preview.json")" --confirm --json
    [ "$status" -ne 0 ]
    [ ! -e "$BOOK/追踪/story-system/write-policy.json" ]
}

@test "blocked migration with resume intent never recommends confirmation" {
    printf '# 第一章冲突稿\n重复章节身份。\n' > "$BOOK/正文/第1卷/第001章_冲突稿.md"
    before="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "继续当前长篇修订" --json > "$TMP_DIR/blocked-resume.json"

    after="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
    [ ! -e "$BOOK/追踪/story-system/write-policy.json" ]
    node - "$TMP_DIR/blocked-resume.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='strict_blocked') throw new Error(JSON.stringify(out));
if(!out.conflicts.some(item=>item.code==='duplicate_chapter_identity')) throw new Error(JSON.stringify(out.conflicts));
const visible=out.visible_response;
if(!visible || visible.status!=='strict_blocked') throw new Error(JSON.stringify(visible));
if(!Array.isArray(visible.options) || visible.options.length!==3) throw new Error(JSON.stringify(visible));
if(visible.options.filter(item=>item.recommended).length!==1) throw new Error(JSON.stringify(visible.options));
const serialized=JSON.stringify(visible);
if(/confirm_write_policy_migration|book-write-policy-migrate\.js confirm|book-write-policy-migrate\.js apply|推荐确认/.test(serialized)) {
  throw new Error(serialized);
}
if(visible.options.some(item=>item.execution_command)) throw new Error(serialized);
NODE
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
    node "$REPO/scripts/workflow-state-machine.js" create --workflow-type long_write --project-root "$BOOK" --scope "第1卷/第002章" --user-goal "写第002章" --json > "$TMP_DIR/create-long-write.json"
    workflow_id="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.task.workflow_id)' "$TMP_DIR/create-long-write.json")"
    [ -n "$workflow_id" ]
    node "$REPO/scripts/workflow-state-machine.js" resolve-action --project-root "$BOOK" --input 1 --bind-current --json > "$TMP_DIR/start-long-write.json"
    mkdir -p "$BOOK/追踪/staging"
    printf '# 第二章\n门外脚步停在窗前。\n' > "$BOOK/追踪/staging/正文.md"
    printf '# 当前上下文\n- 第三章追查脚步来源。\n' > "$BOOK/追踪/staging/上下文.md"
    cat > "$BOOK/追踪/staging/manifest.json" <<JSON
{"workflow_id":"$workflow_id","volume":"第1卷","chapter":2,"artifacts":[{"role":"chapter_prose","staged":"追踪/staging/正文.md","target":"正文/第1卷/第002章_新章.md","required":true},{"role":"story_context","staged":"追踪/staging/上下文.md","target":"追踪/上下文.md","required":true}],"gates":{"output_health":"pass","prose_quality":"pass","story_drift":"pass"}}
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

@test "resume-intent preview surfaces a four-option continuation contract and apply emits the entry-guard continuation" {
    INTENT='continue the current longform revision'

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/resume-preview.json"

    INTENT="$INTENT" node -e '
const fs=require("fs");
const intent=process.env.INTENT;
const out=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(out.status!=="write_policy_migration_preview") throw new Error(JSON.stringify(out));
if(!out.visible_response || out.visible_response.selection_contract!=="execute_command_or_route_intent") throw new Error(JSON.stringify(out.visible_response));
const primary=out.visible_response.options[0];
if(!primary || primary.interaction_mode!=="execute_command") throw new Error(JSON.stringify(primary));
if(!primary.execution_command || !primary.execution_command.includes("book-write-policy-migrate.js confirm")) throw new Error(JSON.stringify(primary));
if(!primary.execution_command.includes("--resume-intent")) throw new Error(JSON.stringify(primary));
if(!primary.execution_command.includes(intent)) throw new Error(JSON.stringify(primary));
' "$TMP_DIR/resume-preview.json"

    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/resume-preview.json")" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/resume-confirm.json"

    snapshot_id="$(snapshot_id "$TMP_DIR/resume-confirm.json")"
    [ -f "$BOOK/追踪/story-system/write-policy-migrations/${snapshot_id}.json" ]
    INTENT="$INTENT" node -e '
const fs=require("fs");
const snap=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(snap.resume_intent!==process.env.INTENT) throw new Error(JSON.stringify(snap));
' "$BOOK/追踪/story-system/write-policy-migrations/${snapshot_id}.json"

    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$snapshot_id" --resume-intent "$INTENT" --json > "$TMP_DIR/resume-apply.json"

    INTENT="$INTENT" node -e '
const fs=require("fs");
const out=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(out.status!=="strict_current") throw new Error(JSON.stringify(out));
if(out.changed!==true) throw new Error(JSON.stringify(out));
if(out.continuation_required!==true) throw new Error(JSON.stringify(out));
if(typeof out.continuation_command!=="string" || !out.continuation_command.includes("workflow-entry-guard.js")) throw new Error(JSON.stringify(out));
if(!out.continuation_command.includes("--user-intent")) throw new Error(JSON.stringify(out));
if(!out.continuation_command.includes("--write --compact --json")) throw new Error(JSON.stringify(out));
if(!out.continuation_command.includes(process.env.INTENT)) throw new Error(JSON.stringify(out));
' "$TMP_DIR/resume-apply.json"
}

@test "preview visible_response renders four numbered options and option 1 label matches confirm-only execution" {
    INTENT='continue the current longform revision'

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/defect12-preview.json"

    INTENT="$INTENT" node -e '
const fs=require("fs");
const intent=process.env.INTENT;
const out=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(out.status!=="write_policy_migration_preview") throw new Error(JSON.stringify(out));
const vr=out.visible_response;
if(!vr) throw new Error("missing visible_response");
if(!Array.isArray(vr.options) || vr.options.length!==4) throw new Error("expected four numbered options: " + JSON.stringify(vr.options));
for(let i=0;i<4;i+=1){
  if(vr.options[i].number!==i+1) throw new Error("option " + i + " not numbered " + (i+1));
}
if(typeof vr.text!=="string" || !vr.text.includes("1.") || !vr.text.includes("2.") || !vr.text.includes("3.") || !vr.text.includes("4.")) throw new Error("visible_response.text missing numbered options: " + JSON.stringify(vr.text));
const opt1=vr.options[0];
if(opt1.interaction_mode!=="execute_command") throw new Error(JSON.stringify(opt1));
if(typeof opt1.label!=="string") throw new Error("option 1 missing label");
if(/应用|apply/i.test(opt1.label)) throw new Error("option 1 label must say confirm only, not confirm-and-apply: " + opt1.label);
if(!opt1.execution_command.includes("book-write-policy-migrate.js confirm")) throw new Error(JSON.stringify(opt1));
if(opt1.execution_command.includes("book-write-policy-migrate.js apply")) throw new Error("option 1 must not invoke apply directly: " + opt1.execution_command);
if(!opt1.execution_command.includes("--resume-intent") || !opt1.execution_command.includes(intent)) throw new Error("option 1 must preserve resume intent: " + opt1.execution_command);
' "$TMP_DIR/defect12-preview.json"
}

@test "confirm returns a visible_response whose primary execute_command applies the exact snapshot" {
    INTENT='continue the current longform revision'

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/defect3-preview.json"
    pid="$(preview_id "$TMP_DIR/defect3-preview.json")"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/defect3-confirm.json"

    INTENT="$INTENT" node -e '
const fs=require("fs");
const intent=process.env.INTENT;
const out=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(out.status!=="confirmed") throw new Error(JSON.stringify(out));
if(out.changed!==true) throw new Error(JSON.stringify(out));
if(!out.visible_response) throw new Error("confirm missing visible_response");
const primary=out.visible_response.options[0];
if(!primary || primary.interaction_mode!=="execute_command") throw new Error(JSON.stringify(primary));
if(typeof primary.execution_command!=="string") throw new Error("missing execution_command");
if(!primary.execution_command.includes("book-write-policy-migrate.js apply")) throw new Error("primary command must invoke apply: " + primary.execution_command);
const sid=out.snapshot_id;
const snapshotMatch=primary.execution_command.match(/--snapshot (["'"'"']?)([^"'"'"'\s]+)\1/);
if(!snapshotMatch || snapshotMatch[2]!==sid) throw new Error("primary command must carry the exact snapshot id " + sid + ": " + primary.execution_command);
if(!primary.execution_command.includes("--resume-intent")) throw new Error("primary command must include --resume-intent: " + primary.execution_command);
if(!primary.execution_command.includes(intent)) throw new Error("primary command must preserve resume intent: " + primary.execution_command);
' "$TMP_DIR/defect3-confirm.json"
}

@test "existing confirmed snapshot retains or safely reconciles a newly supplied resume intent" {
    INTENT='continue the current longform revision'

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/defect4-preview.json"
    pid="$(preview_id "$TMP_DIR/defect4-preview.json")"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/defect4-confirm1.json"
    sid="$(snapshot_id "$TMP_DIR/defect4-confirm1.json")"

    NEW_INTENT='revise chapter two for plot consistency'
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$NEW_INTENT" --confirm --json > "$TMP_DIR/defect4-confirm2.json"

    NEW_INTENT="$NEW_INTENT" node -e '
const fs=require("fs");
const expected=process.env.NEW_INTENT;
const snap=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(snap.resume_intent!==expected) throw new Error("snapshot resume_intent must reconcile to supplied intent, got: " + JSON.stringify(snap.resume_intent));
' "$BOOK/追踪/story-system/write-policy-migrations/${sid}.json"

    node -e '
const out=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
if(out.changed!==false && out.changed!==true) throw new Error("confirm on existing snapshot must report changed flag: " + JSON.stringify(out));
if(out.status!=="confirmed" && out.status!=="strict_current") throw new Error(JSON.stringify(out));
' "$TMP_DIR/defect4-confirm2.json"
}

@test "repeated apply after the snapshot is already applied still returns continuation_required with the same entry-guard command" {
    INTENT='continue the current longform revision'

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/defect5-preview.json"
    pid="$(preview_id "$TMP_DIR/defect5-preview.json")"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/defect5-confirm.json"
    sid="$(snapshot_id "$TMP_DIR/defect5-confirm.json")"
    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$sid" --resume-intent "$INTENT" --json > "$TMP_DIR/defect5-apply1.json"

    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$sid" --resume-intent "$INTENT" --json > "$TMP_DIR/defect5-apply2.json"

    INTENT="$INTENT" node -e '
const fs=require("fs");
const intent=process.env.INTENT;
const first=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const second=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
if(first.status!=="strict_current") throw new Error(JSON.stringify(first));
if(first.continuation_required!==true) throw new Error("first apply must set continuation_required: " + JSON.stringify(first));
if(typeof first.continuation_command!=="string" || !first.continuation_command.includes("workflow-entry-guard.js") || !first.continuation_command.includes(intent)) throw new Error("first apply missing continuation_command: " + JSON.stringify(first));
if(second.status!=="strict_current") throw new Error("repeated apply must stay strict_current: " + JSON.stringify(second));
if(second.continuation_required!==true) throw new Error("repeated apply must still set continuation_required: " + JSON.stringify(second));
if(typeof second.continuation_command!=="string") throw new Error("repeated apply missing continuation_command: " + JSON.stringify(second));
if(second.continuation_command!==first.continuation_command) throw new Error("continuation_command must match the entry-guard command emitted on the first apply:\nfirst=" + first.continuation_command + "\nsecond=" + second.continuation_command);
if(!second.continuation_command.includes("workflow-entry-guard.js")) throw new Error(second.continuation_command);
if(!second.continuation_command.includes("--user-intent") || !second.continuation_command.includes(intent)) throw new Error(second.continuation_command);
' "$TMP_DIR/defect5-apply1.json" "$TMP_DIR/defect5-apply2.json"
}

@test "strict-current preview with resume intent returns the entry-guard continuation instead of a migration menu" {
    INTENT='continue the current longform revision'

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/strict-route-preview.json"
    pid="$(preview_id "$TMP_DIR/strict-route-preview.json")"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/strict-route-confirm.json"
    sid="$(snapshot_id "$TMP_DIR/strict-route-confirm.json")"
    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$sid" --resume-intent "$INTENT" --json > "$TMP_DIR/strict-route-apply.json"

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/strict-route-retry.json"

    INTENT="$INTENT" node - "$TMP_DIR/strict-route-retry.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const intent = process.env.INTENT;
if (out.status !== 'strict_current' || out.changed !== false) throw new Error(JSON.stringify(out));
if (out.continuation_required !== true) throw new Error(JSON.stringify(out));
if (typeof out.continuation_command !== 'string' || !out.continuation_command.includes('workflow-entry-guard.js')) throw new Error(JSON.stringify(out));
if (!out.continuation_command.includes('--user-intent') || !out.continuation_command.includes(intent)) throw new Error(out.continuation_command);
if (out.visible_response) throw new Error('strict-current preview must not show another migration menu: ' + JSON.stringify(out.visible_response));
NODE
}

@test "retrying the old confirm command after migration returns the preserved entry-guard continuation" {
    INTENT='continue the current longform revision'

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/confirm-retry-preview.json"
    pid="$(preview_id "$TMP_DIR/confirm-retry-preview.json")"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/confirm-retry-confirm.json"
    sid="$(snapshot_id "$TMP_DIR/confirm-retry-confirm.json")"
    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$sid" --resume-intent "$INTENT" --json > "$TMP_DIR/confirm-retry-apply.json"

    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/confirm-retry-result.json"

    INTENT="$INTENT" node - "$TMP_DIR/confirm-retry-result.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const intent = process.env.INTENT;
if (out.status !== 'strict_current' || out.changed !== false) throw new Error(JSON.stringify(out));
if (out.continuation_required !== true) throw new Error(JSON.stringify(out));
if (typeof out.continuation_command !== 'string' || !out.continuation_command.includes('workflow-entry-guard.js')) throw new Error(JSON.stringify(out));
if (!out.continuation_command.includes('--user-intent') || !out.continuation_command.includes(intent)) throw new Error(out.continuation_command);
if (out.visible_response) throw new Error('strict-current confirm retry must not show another apply menu: ' + JSON.stringify(out.visible_response));
NODE
}

@test "visible descriptions show raw resume intent while executable commands keep shell quoting" {
    INTENT="revise the hero's arc"

    node "$MIGRATE" preview --project-root "$BOOK" --resume-intent "$INTENT" --json > "$TMP_DIR/raw-intent-preview.json"
    pid="$(preview_id "$TMP_DIR/raw-intent-preview.json")"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$pid" --resume-intent "$INTENT" --confirm --json > "$TMP_DIR/raw-intent-confirm.json"

    INTENT="$INTENT" node - "$TMP_DIR/raw-intent-preview.json" "$TMP_DIR/raw-intent-confirm.json" <<'NODE'
const fs = require('fs');
const intent = process.env.INTENT;
const preview = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const confirm = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const shellArtifact = `'"'"'`;
for (const [stage, out] of [['preview', preview], ['confirm', confirm]]) {
  const primary = out.visible_response && out.visible_response.options[0];
  if (!primary) throw new Error(`${stage} missing primary option`);
  if (!primary.description.includes(`原意图 ${intent} `)) throw new Error(`${stage} description must contain the raw intent: ${primary.description}`);
  if (primary.description.includes(shellArtifact)) throw new Error(`${stage} description leaked shell quoting: ${primary.description}`);
  if (!primary.execution_command.includes('--resume-intent') || !primary.execution_command.includes(shellArtifact)) throw new Error(`${stage} command must retain shell quoting: ${primary.execution_command}`);
}
NODE
}

@test "phase B selection manifest previews confirms and applies one canonical identity without rewriting prose" {
    setup_selection_fixture
    write_valid_selection_manifest
    old_before="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    alt_before="$(shasum -a 256 "$BOOK/$ALT_PATH" | awk '{print $1}')"

    node "$MIGRATE" preview --project-root "$BOOK" --selection-file "$TMP_DIR/selection.json" --json > "$TMP_DIR/selected-preview.json"

    node - "$TMP_DIR/initial-selection-preview.json" "$TMP_DIR/selected-preview.json" <<'NODE'
const fs = require('fs');
const initial = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const selected = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (!/^sha256:[0-9a-f]{64}$/.test(initial.source_fingerprint || '')) throw new Error(JSON.stringify(initial));
if (initial.preview_id !== `write-policy-${initial.source_fingerprint.slice(7, 23)}`) throw new Error(JSON.stringify(initial));
if (selected.status !== 'legacy' || selected.selection_applied !== true) throw new Error(JSON.stringify(selected));
if (selected.source_fingerprint !== initial.source_fingerprint || selected.preview_id === initial.preview_id) throw new Error(JSON.stringify({initial, selected}));
if (selected.chapter_identities.length !== 1) throw new Error(JSON.stringify(selected.chapter_identities));
const identity = selected.chapter_identities[0];
if (identity.path !== '正文/第1卷/第001章_修订稿.md') throw new Error(JSON.stringify(identity));
if (!Array.isArray(identity.excluded_candidates) || identity.excluded_candidates.length !== 1) throw new Error(JSON.stringify(identity));
if (identity.excluded_candidates[0].path !== '正文/第1卷/第001章_旧章.md' || identity.excluded_candidates[0].reason !== 'explicit_selection') throw new Error(JSON.stringify(identity));
NODE

    run node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/selected-preview.json")" --confirm --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_selection_required'* ]]

    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/selected-preview.json")" --selection-file "$TMP_DIR/selection.json" --confirm --json > "$TMP_DIR/selected-confirm.json"
    sid="$(snapshot_id "$TMP_DIR/selected-confirm.json")"
    node - "$BOOK/追踪/story-system/write-policy-migrations/$sid.json" <<'NODE'
const fs = require('fs');
const snapshot = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!snapshot.source_fingerprint || !Array.isArray(snapshot.selections) || snapshot.selections.length !== 1) throw new Error(JSON.stringify(snapshot));
if (!Array.isArray(snapshot.all_candidates) || snapshot.all_candidates.length !== 2) throw new Error(JSON.stringify(snapshot));
for (const file of ['追踪/schema/chapters.jsonl', '追踪/章节资产.jsonl']) {
  const item = snapshot.metadata_before.find(entry => entry.path === file);
  if (!item || !item.exists || !item.content_base64) throw new Error(JSON.stringify(snapshot.metadata_before));
}
NODE

    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$sid" --json > "$TMP_DIR/selected-apply.json"
    [ "$old_before" = "$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')" ]
    [ "$alt_before" = "$(shasum -a 256 "$BOOK/$ALT_PATH" | awk '{print $1}')" ]
    node - "$BOOK/追踪/story-system/chapter-identities.json" "$BOOK/追踪/schema/chapters.jsonl" "$BOOK/追踪/章节资产.jsonl" <<'NODE'
const fs = require('fs');
const registry = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const schemaText = fs.readFileSync(process.argv[3], 'utf8');
const assetText = fs.readFileSync(process.argv[4], 'utf8');
if (registry.chapters.length !== 1 || registry.chapters[0].path !== '正文/第1卷/第001章_修订稿.md') throw new Error(JSON.stringify(registry));
if (registry.chapters[0].excluded_candidates[0].reason !== 'explicit_selection') throw new Error(JSON.stringify(registry));
if (!schemaText.includes('"note":"schema-keep"') || !assetText.includes('"note":"asset-keep"')) throw new Error(JSON.stringify({schemaText, assetText}));
for (const text of [schemaText, assetText]) {
  const lines = text.trimEnd().split(/\r?\n/);
  if (lines.length !== 2 || !lines[1].includes('"draftPath":"正文/第2卷/第009章_保留.md"') || !lines[1].includes('"note":"untouched-')) throw new Error(text);
  const row = JSON.parse(lines[0]);
  if (row.draftPath !== '正文/第1卷/第001章_修订稿.md') throw new Error(text);
}
NODE
}

@test "phase B rejects wrong archive missing hash incomplete extra and duplicate selections" {
    setup_selection_fixture
    mkdir -p "$BOOK/正文/legacy-flat-layout/第1卷"
    printf '# 第一章\n归档稿。\n' > "$BOOK/正文/legacy-flat-layout/第1卷/第001章_归档稿.md"
    printf '# 第二章\n非重复章节。\n' > "$BOOK/正文/第1卷/第002章_单稿.md"
    ln -s "第001章_旧章.md" "$BOOK/正文/第1卷/第001章_链接稿.md"
    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/invalid-initial.json"

    node - "$TMP_DIR/invalid-initial.json" "$TMP_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const preview = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const dir = process.argv[3];
const duplicate = preview.conflicts.find(item => item.code === 'duplicate_chapter_identity');
const valid = duplicate.candidates.find(item => item.path.includes('修订稿'));
const base = { schemaVersion: '1.0.0', preview_id: preview.preview_id, source_fingerprint: preview.source_fingerprint };
const write = (name, selections) => fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify({...base, selections}) + '\n');
write('wrong', [{...valid, volume:'第9卷'}]);
write('archive', [{...valid, path:'正文/legacy-flat-layout/第1卷/第001章_归档稿.md'}]);
write('missing', [{...valid, path:'正文/第1卷/第001章_不存在.md'}]);
write('hash', [{...valid, content_hash:'sha256:' + '0'.repeat(64)}]);
write('incomplete', []);
write('extra', [valid, {volume:'第1卷',chapter:2,path:'正文/第1卷/第002章_单稿.md',content_hash:'sha256:' + '1'.repeat(64)}]);
write('duplicate', [valid, valid]);
write('symlink', [{...valid, path:'正文/第1卷/第001章_链接稿.md'}]);
write('traversal', [{...valid, path:'正文/第1卷/../第1卷/第001章_修订稿.md'}]);
fs.writeFileSync(path.join(dir, 'schema.json'), JSON.stringify({...base, schemaVersion:'2.0.0', selections:[valid]}) + '\n');
NODE

    for case_name in wrong archive missing hash incomplete extra duplicate symlink traversal schema; do
        run node "$MIGRATE" preview --project-root "$BOOK" --selection-file "$TMP_DIR/$case_name.json" --json
        [ "$status" -ne 0 ]
        [[ "$output" == *'blocked_selection_'* ]]
    done
}

@test "phase B help documents the selection file option" {
    run node "$MIGRATE" preview --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'--selection-file <json>'* ]]
}

@test "phase B ordinary preview drift remains a stale preview instead of requesting a selection file" {
    node "$MIGRATE" preview --project-root "$BOOK" --json > "$TMP_DIR/ordinary-preview.json"
    printf '\n普通正文发生变化。\n' >> "$BOOK/正文/第1卷/第001章_旧章.md"

    run node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/ordinary-preview.json")" --confirm --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_migration_preview_stale'* ]]
    [[ "$output" != *'blocked_selection_required'* ]]
}

@test "phase B resume menu preserves the exact selection file in its confirm command" {
    setup_selection_fixture
    selection_file="$TMP_DIR/author's-selection.json"
    write_valid_selection_manifest "$selection_file"

    node "$MIGRATE" preview --project-root "$BOOK" --selection-file "$selection_file" --resume-intent '继续当前迁移' --json > "$TMP_DIR/selection-resume-preview.json"

    SELECTION_FILE="$selection_file" node - "$TMP_DIR/selection-resume-preview.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const command = out.visible_response && out.visible_response.options && out.visible_response.options[0] && out.visible_response.options[0].execution_command;
const quote = value => `'${String(value).replace(/'/g, `'"'"'`)}'`;
const expected = `--selection-file ${quote(process.env.SELECTION_FILE)}`;
if (out.status !== 'write_policy_migration_preview' || !out.selection_applied) throw new Error(JSON.stringify(out));
if (typeof command !== 'string' || !command.includes(expected)) throw new Error(JSON.stringify({command, expected}));
NODE
}

@test "phase B candidate and authority drift make selected previews stale" {
    setup_selection_fixture
    write_valid_selection_manifest
    node "$MIGRATE" preview --project-root "$BOOK" --selection-file "$TMP_DIR/selection.json" --json > "$TMP_DIR/drift-preview.json"
    selected_pid="$(preview_id "$TMP_DIR/drift-preview.json")"

    printf '\n候选正文发生变化。\n' >> "$BOOK/$ALT_PATH"
    run node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$selected_pid" --selection-file "$TMP_DIR/selection.json" --confirm --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_migration_preview_stale'* ]]

    setup_selection_fixture
    write_valid_selection_manifest
    node "$MIGRATE" preview --project-root "$BOOK" --selection-file "$TMP_DIR/selection.json" --json > "$TMP_DIR/authority-drift-preview.json"
    selected_pid="$(preview_id "$TMP_DIR/authority-drift-preview.json")"
    printf '\n' >> "$BOOK/追踪/schema/chapters.jsonl"
    run node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$selected_pid" --selection-file "$TMP_DIR/selection.json" --confirm --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_migration_preview_stale'* ]]
}

@test "phase B apply revalidates snapshot selection and rollback restores authority bytes exactly" {
    setup_selection_fixture
    write_valid_selection_manifest
    schema_before="$(shasum -a 256 "$BOOK/追踪/schema/chapters.jsonl" | awk '{print $1}')"
    asset_before="$(shasum -a 256 "$BOOK/追踪/章节资产.jsonl" | awk '{print $1}')"
    old_before="$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')"
    alt_before="$(shasum -a 256 "$BOOK/$ALT_PATH" | awk '{print $1}')"
    node "$MIGRATE" preview --project-root "$BOOK" --selection-file "$TMP_DIR/selection.json" --json > "$TMP_DIR/rollback-selection-preview.json"
    node "$MIGRATE" confirm --project-root "$BOOK" --preview-id "$(preview_id "$TMP_DIR/rollback-selection-preview.json")" --selection-file "$TMP_DIR/selection.json" --confirm --json > "$TMP_DIR/rollback-selection-confirm.json"
    sid="$(snapshot_id "$TMP_DIR/rollback-selection-confirm.json")"

    cp "$BOOK/追踪/schema/chapters.jsonl" "$TMP_DIR/schema-authority-original"
    printf '\n' >> "$BOOK/追踪/schema/chapters.jsonl"
    run node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$sid" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_migration_preview_stale'* ]]
    cp "$TMP_DIR/schema-authority-original" "$BOOK/追踪/schema/chapters.jsonl"

    node "$MIGRATE" apply --project-root "$BOOK" --snapshot "$sid" --json > "$TMP_DIR/rollback-selection-apply.json"
    node "$MIGRATE" rollback --project-root "$BOOK" --snapshot "$sid" --confirm --json > "$TMP_DIR/rollback-selection.json"

    [ "$schema_before" = "$(shasum -a 256 "$BOOK/追踪/schema/chapters.jsonl" | awk '{print $1}')" ]
    [ "$asset_before" = "$(shasum -a 256 "$BOOK/追踪/章节资产.jsonl" | awk '{print $1}')" ]
    [ "$old_before" = "$(shasum -a 256 "$BOOK/正文/第1卷/第001章_旧章.md" | awk '{print $1}')" ]
    [ "$alt_before" = "$(shasum -a 256 "$BOOK/$ALT_PATH" | awk '{print $1}')" ]
    node -e 'const x=require(process.argv[1]); if(x.status!=="rolled_back") process.exit(1)' "$TMP_DIR/rollback-selection.json"
}
