#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    ASSEMBLER="$REPO/scripts/context-assembler.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/memory" "$PROJECT/追踪/context-pack"
    cat > "$PROJECT/追踪/伏笔.md" <<'MD'
# 伏笔
- F025：绿珠被读心时出现空白，第008章前不得解释血脉来源。
MD
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_memory_authority() {
    local commit_id="$1"
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-memory" "$PROJECT/追踪/workflow/families/family-memory" "$PROJECT/追踪/story-system/commits"
    cat > "$PROJECT/追踪/workflow/tasks/wf-memory/task.json" <<'JSON'
{"workflow_id":"wf-memory","workflow_type":"long_write","task_family_id":"family-memory","branch_id":"wf-memory","task_dir":"追踪/workflow/tasks/wf-memory","state_version":5,"current_stage":"chapter_commit","stage_execution":{"stage_id":"chapter_commit","status":"running","stage_attempt_id":"sa-memory"},"lifecycle_context":{"node":"chapter_commit","book_id":"book-memory","volume_id":"第1卷","stage_id":"chapter_commit","chapter_id":"v01-c001","task_family_id":"family-memory","workflow_id":"wf-memory"}}
JSON
    cat > "$PROJECT/追踪/workflow/families/family-memory/family.json" <<'JSON'
{"task_family_id":"family-memory","head_workflow_id":"wf-memory","branches":[{"workflow_id":"wf-memory","status":"active","is_head":true}]}
JSON
    cat > "$PROJECT/追踪/story-system/commits/$commit_id.json" <<JSON
{"schemaVersion":"1.0.0","commit_id":"$commit_id","status":"accepted","acceptance_status":"accepted","workflow_id":"wf-memory","provenance":{"task_family_id":"family-memory","workflow_id":"wf-memory","branch_id":"wf-memory","stage_attempt_id":"sa-memory","acceptance_status":"accepted"},"facts":[]}
JSON
}

@test "canonical and user-confirmed projection block without durable authority" {
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const projection = require(process.argv[2]);
const root = process.argv[3];
for (const options of [
  { sourceKind: 'canonical', commitId: 'commit-forged', provenance: { workflow_id: 'wf-missing', acceptance_status: 'accepted' } },
  { sourceKind: 'user_confirmed', projectionId: 'confirmation-forged', provenance: { workflow_id: 'wf-missing', acceptance_status: 'accepted' } },
]) {
  let blocked = null;
  try { projection.projectSources(root, ['追踪/伏笔.md'], { ...options, write: true }); } catch (error) { blocked = error; }
  if (!blocked || blocked.status !== 'blocked_task_authority_missing') throw new Error(JSON.stringify({ options, blocked: blocked && blocked.status }));
}
NODE
}

@test "accepted fact projection blocks when commit provenance has no durable task" {
    mkdir -p "$PROJECT/追踪/story-system/commits"
    cat > "$PROJECT/追踪/story-system/commits/commit-forged-facts.json" <<'JSON'
{"commit_id":"commit-forged-facts","status":"accepted","acceptance_status":"accepted","workflow_id":"wf-missing","provenance":{"task_family_id":"family-missing","workflow_id":"wf-missing","branch_id":"wf-missing","stage_attempt_id":"sa-missing","acceptance_status":"accepted"},"facts":[{"subject":"绿珠","predicate":"身份","object":"圣女","evidence":[{"path":"追踪/伏笔.md"}]}]}
JSON

    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const projection = require(process.argv[2]);
const root = process.argv[3];
let blocked = null;
try { projection.projectAcceptedFacts(root, { status: 'accepted', commit_id: 'commit-forged-facts' }); } catch (error) { blocked = error; }
if (!blocked || blocked.status !== 'blocked_task_authority_missing') throw new Error(JSON.stringify(blocked && blocked.status));
NODE
}

@test "legacy projection rejects self-reported migration authority and requires the migration command" {
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const projection = require(process.argv[2]);
const root = process.argv[3];
for (const options of [
  { write: true },
  { write: true, sourceKind: 'legacy', migration: { source_kind: 'legacy' } },
]) {
  let blocked = null;
  try { projection.projectSources(root, ['追踪/伏笔.md'], options); } catch (error) { blocked = error; }
  const expected = options.sourceKind ? 'blocked_untrusted_legacy_migration' : 'blocked_memory_projection_authority_missing';
  if (!blocked || blocked.status !== expected) throw new Error(JSON.stringify({ expected, actual: blocked && blocked.status }));
}
NODE
    node "$REPO/scripts/memory-migrate.js" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json > "$TMP_DIR/migrate.json"
    grep -q '"status": "migrated"' "$TMP_DIR/migrate.json"
}

@test "accepted projection is canonical and legacy auto refresh ignores it" {
    write_memory_authority commit-accepted-001
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const projection = require(process.argv[2]);
const root = process.argv[3];
const result = projection.projectSources(root, ['追踪/伏笔.md'], {
  write: true,
  commitId: 'commit-accepted-001',
  provenance: {
      workflow_id: 'wf-memory',
      task_family_id: 'family-memory',
      branch_id: 'wf-memory',
      stage_attempt_id: 'sa-memory',
    acceptance_status: 'accepted',
  },
});
if (result.status !== 'migrated') throw new Error(JSON.stringify(result));
const rows = fs.readFileSync(path.join(root, '追踪/memory/lorebook.jsonl'), 'utf8').trim().split(/\n/).map(JSON.parse);
const entry = rows.at(-1);
if (!/^canonical\.hook_ledger\.[a-f0-9]{12}$/.test(entry.id)) throw new Error(JSON.stringify(entry));
if (entry.memory_id !== entry.id || entry.source_kind !== 'canonical') throw new Error(JSON.stringify(entry));
if (entry.migrated === true || projection.canAutoRefreshEntry(entry)) throw new Error(JSON.stringify(entry));
if (entry.acceptedCommitId !== 'commit-accepted-001' || entry.valid_from !== 'commit-accepted-001' || entry.valid_to !== null) throw new Error(JSON.stringify(entry));
if (entry.provenance.task_family_id !== 'family-memory' || entry.provenance.workflow_id !== 'wf-memory') throw new Error(JSON.stringify(entry));
if (!entry.sourceRefs[0].hash.startsWith('sha256:')) throw new Error(JSON.stringify(entry.sourceRefs));
NODE
}

@test "migration projection remains legacy and source-refreshable" {
    node "$REPO/scripts/memory-migrate.js" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json >/dev/null
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const projection = require(process.argv[2]);
const root = process.argv[3];
const entry = fs.readFileSync(path.join(root, '追踪/memory/lorebook.jsonl'), 'utf8').trim().split(/\n/).map(JSON.parse).at(-1);
if (!/^legacy\.hook_ledger\.[a-f0-9]{12}$/.test(entry.id)) throw new Error(JSON.stringify(entry));
if (entry.memory_id !== entry.id || entry.source_kind !== 'legacy' || entry.migrated !== true) throw new Error(JSON.stringify(entry));
if (!projection.canAutoRefreshEntry(entry)) throw new Error(JSON.stringify(entry));
NODE
}

@test "canonical projection supersedes accepted legacy memory by stable source identity" {
    write_memory_authority commit-canonical-002
    node "$REPO/scripts/memory-migrate.js" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json >/dev/null
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const projection = require(process.argv[2]);
const root = process.argv[3];
const file = path.join(root, '追踪/memory/lorebook.jsonl');
const legacy = fs.readFileSync(file, 'utf8').trim().split(/\n/).map(JSON.parse).at(-1);
legacy.acceptedCommitId = 'commit-legacy-001';
legacy.valid_from = 'commit-legacy-001';
legacy.valid_to = null;
legacy.provenance = {
  workflow_id: 'wf-legacy',
  task_family_id: 'family-legacy',
  acceptance_status: 'accepted',
};
fs.writeFileSync(file, `${JSON.stringify(legacy)}\n`);

projection.projectSources(root, ['追踪/伏笔.md'], {
  write: true,
  commitId: 'commit-canonical-002',
  provenance: { workflow_id: 'wf-memory', task_family_id: 'family-memory', branch_id: 'wf-memory', stage_attempt_id: 'sa-memory', acceptance_status: 'accepted' },
});

const rows = fs.readFileSync(file, 'utf8').trim().split(/\n/).map(JSON.parse);
const legacyRows = rows.filter(row => row.id === legacy.id);
const canonicalRows = rows.filter(row => row.source_kind === 'canonical');
if (legacyRows.length !== 2 || canonicalRows.length !== 1) throw new Error(JSON.stringify(rows));
const historical = legacyRows[0];
const superseded = legacyRows[1];
const canonical = canonicalRows[0];
if (historical.status !== 'active' || historical.provenance.workflow_id !== 'wf-legacy') throw new Error(JSON.stringify(historical));
if (superseded.status !== 'superseded' || superseded.valid_to !== 'commit-canonical-002') throw new Error(JSON.stringify(superseded));
if (superseded.provenance.workflow_id !== 'wf-legacy') throw new Error(JSON.stringify(superseded.provenance));
if (canonical.status !== 'active' || canonical.valid_from !== 'commit-canonical-002' || canonical.valid_to !== null) throw new Error(JSON.stringify(canonical));
if (legacy.id === canonical.id || legacy.sourceRefs[0].path !== canonical.sourceRefs[0].path) throw new Error(JSON.stringify({ legacy, canonical }));
NODE
}

@test "superseded stale accepted legacy memory does not block its active canonical successor" {
    write_memory_authority commit-canonical-002
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const projection = require(process.argv[2]);
const root = process.argv[3];
const file = path.join(root, '追踪/memory/lorebook.jsonl');
const legacy = {
  id: 'legacy.hook_ledger.historical',
  memory_id: 'legacy.hook_ledger.historical',
  type: 'hook_ledger',
  title: '绿珠读心空白旧投影',
  aliases: ['F025'],
  triggers: ['绿珠', '读心空白'],
  scope: { book: 'current', volume: '第1卷', chapterRange: '第003章' },
  priority: 95,
  content: '旧接受投影。',
  constraints: [],
  sourceRefs: [{ path: '追踪/伏笔.md', hash: `sha256:${'0'.repeat(64)}` }],
  status: 'active',
  version: 1,
  migrated: true,
  acceptedCommitId: 'commit-legacy-001',
  valid_from: 'commit-legacy-001',
  valid_to: null,
};
fs.writeFileSync(file, `${JSON.stringify(legacy)}\n`);
projection.projectSources(root, ['追踪/伏笔.md'], {
  write: true,
  commitId: 'commit-canonical-002',
  provenance: { workflow_id: 'wf-memory', task_family_id: 'family-memory', branch_id: 'wf-memory', stage_attempt_id: 'sa-memory', acceptance_status: 'accepted' },
});
NODE

    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/canonical.json"
    node - "$TMP_DIR/canonical.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const rows = fs.readFileSync(process.argv[3], 'utf8').trim().split(/\n/).map(JSON.parse);
if (out.status !== 'ok') throw new Error(JSON.stringify(out));
if (out.stale.some(entry => entry.id === 'legacy.hook_ledger.historical')) throw new Error(JSON.stringify(out.stale));
if (!out.selectedEntries.some(entry => entry.id.startsWith('canonical.hook_ledger.'))) throw new Error(JSON.stringify(out.selectedEntries));
const latestLegacy = rows.filter(row => row.id === 'legacy.hook_ledger.historical').at(-1);
if (latestLegacy.status !== 'superseded' || latestLegacy.valid_to !== 'commit-canonical-002') throw new Error(JSON.stringify(latestLegacy));
NODE
}

@test "historical accepted legacy memory remains readable but cannot auto-refresh" {
    node - "$PROJECT" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const source = path.join(root, '追踪/伏笔.md');
const hash = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex')}`;
const entry = {
  id: 'legacy.hook_ledger.historical',
  memory_id: 'legacy.hook_ledger.historical',
  type: 'hook_ledger',
  title: '绿珠读心空白',
  aliases: ['F025'],
  triggers: ['绿珠', '读心空白'],
  scope: { book: 'current', volume: '第1卷', chapterRange: '第003章' },
  priority: 95,
  tokenBudget: 120,
  content: '绿珠被读心时出现空白，第008章前不得解释血脉来源。',
  constraints: ['第008章前不得解释血脉来源。'],
  sourceRefs: [{ path: '追踪/伏笔.md', hash, note: 'accepted historical projection' }],
  status: 'active',
  version: 1,
  migrated: true,
  acceptedCommitId: 'commit-historical-001',
  valid_from: 'commit-historical-001',
  valid_to: null,
};
fs.writeFileSync(path.join(root, '追踪/memory/lorebook.jsonl'), `${JSON.stringify(entry)}\n`);
NODE

    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/readable.json"
    node - "$TMP_DIR/readable.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'ok' || !out.selectedEntries.some(entry => entry.id === 'legacy.hook_ledger.historical')) throw new Error(JSON.stringify(out));
NODE

    printf '# 伏笔\n- F025：绿珠被读心时出现空白，新增内容不得自动写回接受记忆。\n' > "$PROJECT/追踪/伏笔.md"
    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/stale.json"
    node - "$TMP_DIR/stale.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const rows = fs.readFileSync(process.argv[3], 'utf8').trim().split(/\n/).map(JSON.parse);
if (out.status !== 'blocked_memory_stale') throw new Error(JSON.stringify(out));
if (!out.staleEntryIds.includes('legacy.hook_ledger.historical')) throw new Error(JSON.stringify(out));
if (!out.memoryRefresh || out.memoryRefresh.status !== 'not_needed') throw new Error(JSON.stringify(out.memoryRefresh));
if (rows.length !== 1) throw new Error(JSON.stringify(rows));
NODE
}
