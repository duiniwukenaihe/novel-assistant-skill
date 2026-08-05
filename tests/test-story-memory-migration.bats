#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MIGRATE="$REPO/scripts/memory-migrate.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/交接包" "$PROJECT/设定/作者风格"
    cat > "$PROJECT/追踪/角色状态.md" <<'MD'
# 角色状态
- 林昭：第一人称主角，已经拒绝母亲安排的相亲。
- 吴淑芬：好面子、刻薄，但不能突然慈爱。
MD
    cat > "$PROJECT/追踪/伏笔.md" <<'MD'
# 伏笔
- F001：小黑板上的电话来自吴淑芬，第二节必须解释转接渠道。
MD
    cat > "$PROJECT/追踪/上下文.md" <<'MD'
# 当前上下文
- 已采用第一节，下一步生成第二节 Brief。
MD
    cat > "$PROJECT/追踪/交接包/第001节_to_第002节.md" <<'MD'
# 交接
- 林昭离开相亲角，电话来源尚未解释。
MD
    cat > "$PROJECT/设定/作者风格/禁用表达.md" <<'MD'
# 禁用表达
- 避免高频“不是 X，是 Y”。
MD
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "memory migration previews legacy assets without writing" {
    node "$MIGRATE" --project-root "$PROJECT" --json > "$TMP_DIR/out.json"
    grep -q '"status": "migration_preview"' "$TMP_DIR/out.json"
    grep -q '追踪/角色状态.md' "$TMP_DIR/out.json"
    grep -q '追踪/伏笔.md' "$TMP_DIR/out.json"
    [ ! -f "$PROJECT/追踪/memory/lorebook.jsonl" ]
}

@test "memory migration writes source hashed entries and is idempotent" {
    node "$MIGRATE" --project-root "$PROJECT" --write --json > "$TMP_DIR/first.json"
    node "$MIGRATE" --project-root "$PROJECT" --write --json > "$TMP_DIR/second.json"

    node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const first=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const second=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const lines=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
if(first.status!=='migrated' || first.created < 4) throw new Error(JSON.stringify(first));
if(second.status!=='current' || second.created!==0) throw new Error(JSON.stringify(second));
if(new Set(lines.map(x=>x.id)).size!==lines.length) throw new Error('duplicate ids');
if(!lines.every(x=>x.sourceRefs[0].hash.startsWith('sha256:'))) throw new Error('missing source hash');
if(!lines.some(x=>x.type==='hook_ledger')) throw new Error('missing hook memory');
if(!lines.some(x=>x.type==='character_state')) throw new Error('missing character memory');
NODE
}

@test "memory migration refreshes one changed source as a new active version" {
    node "$MIGRATE" --project-root "$PROJECT" --write --json > "$TMP_DIR/first.json"
    printf '# 伏笔\n- F001：电话由吴淑芬主动转接，第二节已解释。\n' > "$PROJECT/追踪/伏笔.md"

    node "$MIGRATE" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json > "$TMP_DIR/refresh.json"
    node "$MIGRATE" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json > "$TMP_DIR/again.json"

    node - "$TMP_DIR/refresh.json" "$TMP_DIR/again.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const refresh=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const again=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const rows=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
const hooks=rows.filter(x=>x.type==='hook_ledger');
if(refresh.status!=='migrated' || refresh.created!==1 || refresh.superseded!==1) throw new Error(JSON.stringify(refresh));
if(again.status!=='current' || again.created!==0) throw new Error(JSON.stringify(again));
if(hooks.length!==3) throw new Error(`expected original, superseded event, active v2; got ${hooks.length}`);
if(hooks.at(-2).status!=='superseded') throw new Error(JSON.stringify(hooks));
if(hooks.at(-1).status!=='active' || hooks.at(-1).version!==2) throw new Error(JSON.stringify(hooks));
if(!hooks.at(-1).content.includes('主动转接')) throw new Error(hooks.at(-1).content);
NODE
}

@test "memory migration respects the book write lease" {
    lock="$PROJECT/追踪/story-system/.write.lock"
    mkdir -p "$lock"
    printf '{"owner":"another-session","token":"held","acquired_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/owner.json"

    run node "$MIGRATE" --project-root "$PROJECT" --write --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_book_write_locked'* ]]
    [ ! -f "$PROJECT/追踪/memory/lorebook.jsonl" ]
}

@test "legacy facts migrate as stable lorebook compatibility entries without a final newline" {
    FACT_PROJECT="$TMP_DIR/fact-book"
    mkdir -p "$FACT_PROJECT/追踪"
    printf '%s\n%s' \
      '{"type":"character_state","entity":"角色甲","state":"已经确认入口。","chapter":"第001章"}' \
      '{"type":"story_state","entity":"线索乙","state":"仍待后续核验。","chapter":"第002章"}' \
      > "$FACT_PROJECT/追踪/facts.jsonl"

    node "$MIGRATE" --project-root "$FACT_PROJECT" --json > "$TMP_DIR/preview.json"
    [ ! -e "$FACT_PROJECT/追踪/memory" ]

    node "$MIGRATE" --project-root "$FACT_PROJECT" --write --json > "$TMP_DIR/first.json"
    cp "$FACT_PROJECT/追踪/memory/lorebook.jsonl" "$TMP_DIR/first-lorebook.jsonl"
    node "$MIGRATE" --project-root "$FACT_PROJECT" --write --json > "$TMP_DIR/second.json"
    printf '%s\n%s' \
      '{"type":"story_state","entity":"线索乙","state":"仍待后续核验。","chapter":"第002章"}' \
      '{"type":"character_state","entity":"角色甲","state":"已经确认入口。","chapter":"第001章"}' \
      > "$FACT_PROJECT/追踪/facts.jsonl"
    node "$MIGRATE" --project-root "$FACT_PROJECT" --write --json > "$TMP_DIR/reordered.json"

    node - "$TMP_DIR/preview.json" "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$TMP_DIR/reordered.json" "$TMP_DIR/first-lorebook.jsonl" "$FACT_PROJECT/追踪/memory/lorebook.jsonl" "$FACT_PROJECT/追踪/memory/facts.jsonl" "$FACT_PROJECT/追踪/facts.jsonl" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const [previewFile, firstFile, secondFile, reorderedFile, firstLorebook, lorebook, canonicalFacts, legacyFacts] = process.argv.slice(2);
const preview = JSON.parse(fs.readFileSync(previewFile, 'utf8'));
const first = JSON.parse(fs.readFileSync(firstFile, 'utf8'));
const second = JSON.parse(fs.readFileSync(secondFile, 'utf8'));
const reordered = JSON.parse(fs.readFileSync(reorderedFile, 'utf8'));
const readRows = file => fs.readFileSync(file, 'utf8').trim().split(/\r?\n/).map(JSON.parse);
const before = readRows(firstLorebook);
const after = readRows(lorebook);
if (preview.status !== 'migration_preview' || preview.created !== 2 || !preview.sources.includes('追踪/facts.jsonl')) throw new Error(JSON.stringify(preview));
if (first.status !== 'migrated' || first.created !== 2) throw new Error(JSON.stringify(first));
if (second.status !== 'current' || second.created !== 0) throw new Error(JSON.stringify(second));
if (reordered.status !== 'migrated' || reordered.created !== 2 || reordered.superseded !== 2) throw new Error(JSON.stringify(reordered));
const latest = new Map();
for (const row of after) latest.set(row.id, row);
const active = Array.from(latest.values()).filter(row => row.status === 'active');
if (before.length !== 2 || after.length !== 6 || active.length !== 2) throw new Error(JSON.stringify({ before, after }));
if (before.map(row => row.id).sort().join('\n') !== active.map(row => row.id).sort().join('\n')) throw new Error('ids depend on row order');
if (!active.every(row => /^legacy\.fact_compatibility\.[a-f0-9]{12}$/.test(row.id))) throw new Error(JSON.stringify(active));
if (!active.every(row => row.memory_id === row.id && row.source_kind === 'legacy' && row.migrated === true && row.compatibility_schema === 'legacy_fact_v1')) throw new Error(JSON.stringify(active));
if (active.some(row => row.fact_id || row.acceptedCommitId || row.acceptance_status || (row.provenance || {}).acceptance_status === 'accepted')) throw new Error('legacy compatibility entry impersonated an accepted fact');
const sourceHash = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(legacyFacts)).digest('hex')}`;
if (!active.every(row => row.sourceRefs[0].hash === sourceHash)) throw new Error('compatibility evidence is stale immediately after migration');
if (fs.existsSync(canonicalFacts)) throw new Error('legacy facts were written to the canonical fact journal');
NODE
}

@test "legacy facts migration atomically blocks malformed JSON" {
    printf '%s\n%s' \
      '{"type":"story_state","entity":"条目甲","state":"有效。","chapter":"第001章"}' \
      '{"type":"story_state","entity":"条目乙"' \
      > "$PROJECT/追踪/facts.jsonl"

    run node "$MIGRATE" --project-root "$PROJECT" --write --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_invalid_legacy_facts'* ]]
    [ ! -e "$PROJECT/追踪/memory" ]
}

@test "legacy facts migration atomically blocks rows with missing fields" {
    printf '%s\n%s' \
      '{"type":"story_state","entity":"条目甲","state":"有效。","chapter":"第001章"}' \
      '{"type":"story_state","entity":"条目乙","state":"缺少章节。"}' \
      > "$PROJECT/追踪/facts.jsonl"

    run node "$MIGRATE" --project-root "$PROJECT" --write --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_invalid_legacy_facts'* ]]
    [ ! -e "$PROJECT/追踪/memory" ]
}

@test "memory pollution detection ignores repeated Markdown structure lines" {
    cat > "$PROJECT/追踪/上下文.md" <<'MD'
# 状态
| 字段 | 内容 |
| --- | --- |
| 编号 | 一 |
# 状态
| 字段 | 内容 |
| --- | --- |
| 编号 | 二 |
# 状态
| 字段 | 内容 |
| --- | --- |
| 编号 | 三 |
# 状态
| 字段 | 内容 |
| --- | --- |
| 编号 | 四 |
MD

    run node "$MIGRATE" --project-root "$PROJECT" --source '追踪/上下文.md' --write --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "migrated"'* ]]
}

@test "memory pollution detection ignores repeated Markdown list field labels" {
    cat > "$PROJECT/追踪/上下文.md" <<'MD'
# 状态
- **关联说明**：
  - 第一项需要核验。
- **当前状态**：
  - 第一项尚未完成。
- **关联说明**：
  - 第二项需要核验。
- **当前状态**：
  - 第二项尚未完成。
- **关联说明**：
  - 第三项需要核验。
- **当前状态**：
  - 第三项尚未完成。
- **关联说明**：
  - 第四项需要核验。
- **当前状态**：
  - 第四项尚未完成。
MD

    run node "$MIGRATE" --project-root "$PROJECT" --source '追踪/上下文.md' --write --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "migrated"'* ]]
}

@test "memory pollution detection ignores repeated Markdown field rows with enum values" {
    cat > "$PROJECT/追踪/上下文.md" <<'MD'
# 状态
- **当前状态**：🔴 待后续核验
- **当前状态**：🔴 待后续核验
- **当前状态**：🔴 待后续核验
- **当前状态**：🔴 待后续核验
1. **处理阶段**：待复核
2. **处理阶段**：待复核
3. **处理阶段**：待复核
4. **处理阶段**：待复核
MD

    run node "$MIGRATE" --project-root "$PROJECT" --source '追踪/上下文.md' --write --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "migrated"'* ]]
}

@test "memory pollution detection ignores semantic rows repeated only across distant snapshots" {
    {
      printf '# 历史快照\n'
      for snapshot in 1 2 3 4; do
        printf '%s\n' '- 工作流说明保持不变。'
        for index in $(seq 1 40); do
          printf -- '- 快照 %s 的独立记录 %s。\n' "$snapshot" "$index"
        done
      done
    } > "$PROJECT/追踪/上下文.md"

    run node "$MIGRATE" --project-root "$PROJECT" --source '追踪/上下文.md' --write --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "migrated"'* ]]
}

@test "memory pollution detection still blocks ordinary prose repeated four times" {
    cat > "$PROJECT/追踪/上下文.md" <<'MD'
# 状态
该提醒仍需后续核验。
该提醒仍需后续核验。
该提醒仍需后续核验。
该提醒仍需后续核验。
MD

    run node "$MIGRATE" --project-root "$PROJECT" --source '追踪/上下文.md' --write --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_output_pollution'* ]]
    [ ! -e "$PROJECT/追踪/memory" ]
}

@test "memory pollution detection still blocks a semantic line repeated four times" {
    cat > "$PROJECT/追踪/上下文.md" <<'MD'
# 状态
- 该提醒仍需后续核验。
- 该提醒仍需后续核验。
- 该提醒仍需后续核验。
- 该提醒仍需后续核验。
MD

    run node "$MIGRATE" --project-root "$PROJECT" --source '追踪/上下文.md' --write --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_output_pollution'* ]]
    [ ! -e "$PROJECT/追踪/memory" ]
}
