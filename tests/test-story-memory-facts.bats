#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    ASSEMBLER="$REPO/scripts/context-assembler.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/memory" "$PROJECT/追踪/context-pack" "$PROJECT/追踪/章节契约/第1卷"
    printf '# 伏笔\n绿珠身份存在未解谜团。\n' > "$PROJECT/追踪/伏笔.md"
    cat > "$PROJECT/追踪/章节契约/第1卷/第003章.md" <<'MD'
# 第003章契约
- 圣女身份因血脉觉醒显现。
MD
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_fact_authority() {
    local workflow_id="$1"
    local family_id="family-$workflow_id"
    local attempt_id="sa-$workflow_id"
    mkdir -p "$PROJECT/追踪/workflow/tasks/$workflow_id" "$PROJECT/追踪/workflow/families/$family_id"
    cat > "$PROJECT/追踪/workflow/tasks/$workflow_id/task.json" <<JSON
{"workflow_id":"$workflow_id","workflow_type":"long_write","task_family_id":"$family_id","branch_id":"$workflow_id","task_dir":"追踪/workflow/tasks/$workflow_id","state_version":2,"current_stage":"chapter_commit","stage_execution":{"stage_id":"chapter_commit","status":"running","stage_attempt_id":"$attempt_id"}}
JSON
    cat > "$PROJECT/追踪/workflow/families/$family_id/family.json" <<JSON
{"task_family_id":"$family_id","head_workflow_id":"$workflow_id","branches":[{"workflow_id":"$workflow_id","status":"active","is_head":true}]}
JSON
}

@test "accepted facts are append-only and contradictory history is excluded from active context" {
    write_fact_authority wf-001
    write_fact_authority wf-002
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const { projectAcceptedFacts } = require(process.argv[2]);
const root = process.argv[3];
const common = {
  subject: '绿珠', predicate: '身份', aliases: ['绿珠'], dependencies: [],
  scope: { book: 'current' }, evidence: [{ path: '追踪/伏笔.md', note: 'accepted packet' }], confidence: 1,
};
fs.mkdirSync(path.join(root, '追踪/story-system/commits'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-accepted-001.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-accepted-001',
  workflow_id: 'wf-001',
  acceptance_status: 'accepted',
  provenance: { task_family_id: 'family-wf-001', workflow_id: 'wf-001', branch_id: 'wf-001', stage_attempt_id: 'sa-wf-001', acceptance_status: 'accepted' },
  facts: [{ ...common, object: '魔女' }],
}));
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-accepted-002.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-accepted-002',
  workflow_id: 'wf-002',
  acceptance_status: 'accepted',
  provenance: { task_family_id: 'family-wf-002', workflow_id: 'wf-002', branch_id: 'wf-002', stage_attempt_id: 'sa-wf-002', acceptance_status: 'accepted' },
  facts: [{ ...common, object: '圣女', aliases: ['绿珠', '圣女'], dependencies: ['血脉觉醒'] }],
}));
projectAcceptedFacts(root, {
  status: 'accepted', commit_id: 'commit-accepted-001', workflow_id: 'wf-001',
  facts: [{ ...common, object: '魔女' }],
});
const result = projectAcceptedFacts(root, {
  status: 'accepted', commit_id: 'commit-accepted-002', workflow_id: 'wf-002',
  facts: [{ ...common, object: '圣女', aliases: ['绿珠', '圣女'], dependencies: ['血脉觉醒'] }],
});
if (result.factIds.length !== 1 || !result.eventFile.endsWith('追踪/memory/facts.jsonl')) throw new Error(JSON.stringify(result));
NODE

    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"
    node - "$PROJECT/追踪/memory/facts.jsonl" "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split(/\n/).map(JSON.parse);
const out = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (rows.length !== 3) throw new Error(JSON.stringify(rows));
const oldRows = rows.filter(row => row.object === '魔女');
if (oldRows.length !== 2 || oldRows[0].status !== 'active' || oldRows[1].status !== 'superseded') throw new Error(JSON.stringify(oldRows));
if (oldRows[1].valid_to !== 'commit-accepted-002') throw new Error(JSON.stringify(oldRows[1]));
if (out.status !== 'ok') throw new Error(JSON.stringify(out));
const packet = JSON.parse(fs.readFileSync(out.packetJson, 'utf8'));
const activeFact = packet.relevant_lore.find(entry => entry.type === 'accepted_fact');
if (!activeFact || !activeFact.content.includes('圣女') || activeFact.content.includes('魔女')) throw new Error(JSON.stringify(packet.relevant_lore));
if (!activeFact.evidence || !activeFact.evidence.some(item => item.path === '追踪/伏笔.md')) throw new Error(JSON.stringify(activeFact));
const evidence = activeFact.evidence.find(item => item.path === '追踪/伏笔.md');
if (!/^sha256:[a-f0-9]{64}$/.test(evidence.hash || '')) throw new Error(JSON.stringify(evidence));
if (evidence.source_commit_id !== 'commit-accepted-002' || evidence.workflow_id !== 'wf-002' || evidence.task_family_id !== 'family-wf-002') throw new Error(JSON.stringify(evidence));
NODE
}

@test "a new accepted revision supersedes facts omitted from the same canonical source" {
    write_fact_authority wf-revision
    mkdir -p "$PROJECT/正文" "$PROJECT/追踪/story-system/commits"
    printf '第一版正文。\n' > "$PROJECT/正文/第001节.md"
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const { projectAcceptedFacts } = require(process.argv[2]);
const root = process.argv[3];
const commitDir = path.join(root, '追踪/story-system/commits');
const evidence = [{ path: '正文/第001节.md' }];
const provenance = { task_family_id: 'family-wf-revision', workflow_id: 'wf-revision', branch_id: 'wf-revision', stage_attempt_id: 'sa-wf-revision', acceptance_status: 'accepted' };
fs.writeFileSync(path.join(commitDir, 'commit-section-v1.json'), JSON.stringify({
  status: 'accepted', commit_id: 'commit-section-v1', workflow_id: 'wf-revision', acceptance_status: 'accepted', provenance,
  facts: [
    { subject: '主角', predicate: '状态', object: '仍在犹豫', scope: { section: 1 }, evidence },
    { subject: '旧钩子', predicate: '状态', object: '等待回收', scope: { section: 1 }, evidence },
  ],
}));
projectAcceptedFacts(root, { status: 'accepted', commit_id: 'commit-section-v1' });
fs.writeFileSync(path.join(root, '正文/第001节.md'), '第二版正文。\n');
fs.writeFileSync(path.join(commitDir, 'commit-section-v2.json'), JSON.stringify({
  status: 'accepted', commit_id: 'commit-section-v2', workflow_id: 'wf-revision', acceptance_status: 'accepted', provenance,
  facts: [{ subject: '主角', predicate: '状态', object: '仍在犹豫', scope: { section: 1 }, evidence }],
}));
projectAcceptedFacts(root, { status: 'accepted', commit_id: 'commit-section-v2' });
const rows = fs.readFileSync(path.join(root, '追踪/memory/facts.jsonl'), 'utf8').trim().split(/\n/).map(JSON.parse);
const latest = new Map(); for (const row of rows) latest.set(row.fact_id, row);
const active = [...latest.values()].filter(row => row.status === 'active' && !row.valid_to);
if (active.length !== 1 || active[0].subject !== '主角') throw new Error(JSON.stringify(active));
if (active[0].evidence[0].source_commit_id !== 'commit-section-v2') throw new Error(JSON.stringify(active[0]));
const removed = rows.filter(row => row.subject === '旧钩子');
if (removed.at(-1).status !== 'superseded' || removed.at(-1).valid_to !== 'commit-section-v2') throw new Error(JSON.stringify(removed));
NODE
}

@test "fact store accepts only explicit facts and never infers canon from prose" {
    printf '正文声称绿珠其实是妖王，但该信息没有进入 accepted facts。\n' > "$PROJECT/追踪/上下文.md"
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const { projectAcceptedFacts } = require(process.argv[2]);
const root = process.argv[3];
fs.mkdirSync(path.join(root, '追踪/story-system/commits'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-empty.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-empty',
  workflow_id: 'wf-empty',
  facts: [],
}));
const result = projectAcceptedFacts(root, { status: 'accepted', commit_id: 'commit-empty', workflow_id: 'wf-empty', facts: [] });
if (result.factIds.length !== 0) throw new Error(JSON.stringify(result));
if (fs.existsSync(path.join(root, '追踪/memory/facts.jsonl'))) throw new Error('prose was projected without explicit accepted facts');
NODE
}

@test "fact projection accepts facts only from an explicitly accepted packet" {
    write_fact_authority wf-accepted
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const { projectAcceptedFacts } = require(process.argv[2]);
const root = process.argv[3];
const fact = {
  subject: '绿珠', predicate: '身份', object: '圣女', aliases: ['圣女'], dependencies: [],
  scope: { book: 'current' }, evidence: [{ path: '追踪/伏笔.md' }], confidence: 1,
};
let blocked = false;
try {
  projectAcceptedFacts(root, { status: 'draft', commit_id: 'commit-draft', facts: [fact] });
} catch (error) {
  blocked = error.status === 'blocked_unaccepted_projection';
}
if (!blocked) throw new Error('draft packet projected canonical facts');
blocked = false;
try {
  projectAcceptedFacts(root, { status: 'accepted', commit_id: 'commit-forged', workflow_id: 'wf-forged', facts: [fact] });
} catch (error) {
  blocked = error.status === 'blocked_commit_missing';
}
if (!blocked) throw new Error('forged accepted packet projected canonical facts');
fs.mkdirSync(path.join(root, '追踪/story-system/commits'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-prose-only.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-prose-only',
  workflow_id: 'wf-accepted',
  acceptance_status: 'accepted',
  facts: [],
}));
const empty = projectAcceptedFacts(root, {
  status: 'accepted', commit_id: 'commit-prose-only', content: '绿珠其实是妖王。', facts: [],
});
if (empty.factIds.length !== 0 || fs.existsSync(path.join(root, '追踪/memory/facts.jsonl'))) throw new Error(JSON.stringify(empty));
  fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-accepted.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-accepted',
  workflow_id: 'wf-accepted',
  acceptance_status: 'accepted',
  provenance: { task_family_id: 'family-wf-accepted', workflow_id: 'wf-accepted', branch_id: 'wf-accepted', stage_attempt_id: 'sa-wf-accepted', acceptance_status: 'accepted' },
  facts: [fact],
}));
const accepted = projectAcceptedFacts(root, {
  status: 'accepted', commit_id: 'commit-accepted', workflow_id: 'wf-accepted', facts: [fact],
});
if (accepted.factIds.length !== 1) throw new Error(JSON.stringify(accepted));
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-empty-real.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-empty-real',
  workflow_id: 'wf-empty-real',
  facts: [],
}));
const forged = projectAcceptedFacts(root, {
  status: 'accepted',
  commit_id: 'commit-empty-real',
  workflow_id: 'wf-empty-real',
  facts: [fact],
});
if (forged.factIds.length !== 0) throw new Error('packet facts overrode verified commit facts');
const forgedOption = projectAcceptedFacts(root, {
  status: 'accepted',
  commit_id: 'commit-empty-real',
  workflow_id: 'wf-empty-real',
  facts: [],
}, {
  acceptedCommit: {
    status: 'accepted',
    commit_id: 'commit-empty-real',
    workflow_id: 'wf-empty-real',
    facts: [fact],
  },
});
if (forgedOption.factIds.length !== 0) throw new Error('caller acceptedCommit option overrode persisted commit facts');
if (Object.prototype.hasOwnProperty.call(require(process.argv[2]), 'TRUSTED_ACCEPTED_COMMIT')) {
  throw new Error('trusted accepted commit token must not be exported');
}
NODE
}

@test "raw fact store API is not publicly writable" {
    node - "$REPO/scripts/lib/memory-fact-store.js" "$REPO/scripts/lib/memory-projection.js" <<'NODE'
const store = require(process.argv[2]);
const projection = require(process.argv[3]);
for (const name of ['appendAcceptedFacts', 'appendAcceptedFactsFromAcceptedPacket']) {
  if (Object.prototype.hasOwnProperty.call(store, name)) throw new Error(`raw fact write API exported: ${name}`);
}
if (Object.prototype.hasOwnProperty.call(projection, 'projectFactsFromAcceptedCommit')) {
  throw new Error('projectFactsFromAcceptedCommit must not be exported');
}
NODE
}

@test "fact store rejects evidence-free injected facts" {
    write_fact_authority wf-no-evidence
    [ -f "$REPO/scripts/lib/memory-fact-store.js" ]
    run node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const { projectAcceptedFacts } = require(process.argv[2]);
const fs = require('fs'); const path = require('path'); const root = process.argv[3];
fs.mkdirSync(path.join(root, '追踪/story-system/commits'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-no-evidence.json'), JSON.stringify({
  status: 'accepted', acceptance_status: 'accepted', commit_id: 'commit-no-evidence', workflow_id: 'wf-no-evidence',
  provenance: { task_family_id: 'family-wf-no-evidence', workflow_id: 'wf-no-evidence', branch_id: 'wf-no-evidence', stage_attempt_id: 'sa-wf-no-evidence', acceptance_status: 'accepted' },
  facts: [{ subject: '绿珠', predicate: '身份', object: '圣女', aliases: [], dependencies: [], scope: { book: 'current' } }],
}));
projectAcceptedFacts(process.argv[3], {
  status: 'accepted',
  commit_id: 'commit-no-evidence',
  workflow_id: 'wf-no-evidence',
  facts: [{ subject: '绿珠', predicate: '身份', object: '圣女', aliases: [], dependencies: [], scope: { book: 'current' } }],
});
NODE
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_fact_evidence_required"* ]]
    [ ! -e "$PROJECT/追踪/memory/facts.jsonl" ]
}

@test "fact store rejects evidence paths that do not exist inside the project" {
    write_fact_authority wf-bad-evidence
    run node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const { projectAcceptedFacts } = require(process.argv[2]);
const fs = require('fs'); const path = require('path'); const root = process.argv[3];
const fact = { subject: '绿珠', predicate: '身份', object: '圣女', evidence: [{ path: '追踪/不存在.md' }] };
fs.mkdirSync(path.join(root, '追踪/story-system/commits'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-bad-evidence.json'), JSON.stringify({
  status: 'accepted', acceptance_status: 'accepted', commit_id: 'commit-bad-evidence', workflow_id: 'wf-bad-evidence',
  provenance: { task_family_id: 'family-wf-bad-evidence', workflow_id: 'wf-bad-evidence', branch_id: 'wf-bad-evidence', stage_attempt_id: 'sa-wf-bad-evidence', acceptance_status: 'accepted' },
  facts: [fact],
}));
projectAcceptedFacts(process.argv[3], {
  status: 'accepted',
  commit_id: 'commit-bad-evidence',
  workflow_id: 'wf-bad-evidence',
  facts: [{
    subject: '绿珠',
    predicate: '身份',
    object: '圣女',
    evidence: [{ path: '追踪/不存在.md' }],
  }],
});
NODE
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_fact_evidence_missing"* ]]
    [ ! -e "$PROJECT/追踪/memory/facts.jsonl" ]
}

@test "fact store rejects symlinked evidence paths" {
    write_fact_authority wf-symlink-evidence
    printf '外部证据\n' > "$TMP_DIR/outside.md"
    ln -s "$TMP_DIR/outside.md" "$PROJECT/追踪/外部证据.md"
    run node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const { projectAcceptedFacts } = require(process.argv[2]);
const root = process.argv[3];
fs.mkdirSync(path.join(root, '追踪/story-system/commits'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-symlink-evidence.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-symlink-evidence',
  workflow_id: 'wf-symlink-evidence',
  acceptance_status: 'accepted',
  provenance: { task_family_id: 'family-wf-symlink-evidence', workflow_id: 'wf-symlink-evidence', branch_id: 'wf-symlink-evidence', stage_attempt_id: 'sa-wf-symlink-evidence', acceptance_status: 'accepted' },
  facts: [{
    subject: '绿珠',
    predicate: '身份',
    object: '圣女',
    evidence: [{ path: '追踪/外部证据.md' }],
  }],
}));
projectAcceptedFacts(root, {
  status: 'accepted',
  commit_id: 'commit-symlink-evidence',
  workflow_id: 'wf-symlink-evidence',
  facts: [{
    subject: '绿珠',
    predicate: '身份',
    object: '圣女',
    evidence: [{ path: '追踪/外部证据.md' }],
  }],
});
NODE
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_fact_evidence_symlink"* ]]
    [ ! -e "$PROJECT/追踪/memory/facts.jsonl" ]
}

@test "assembled markdown includes evidence for accepted facts" {
    write_fact_authority wf-md-evidence
    printf '# 伏笔\n绿珠身份为圣女。\n' > "$PROJECT/追踪/伏笔.md"
    node - "$REPO/scripts/lib/memory-projection.js" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const { projectAcceptedFacts } = require(process.argv[2]);
const root = process.argv[3];
fs.mkdirSync(path.join(root, '追踪/story-system/commits'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/commits/commit-md-evidence.json'), JSON.stringify({
  status: 'accepted',
  commit_id: 'commit-md-evidence',
  workflow_id: 'wf-md-evidence',
  acceptance_status: 'accepted',
  provenance: { task_family_id: 'family-wf-md-evidence', workflow_id: 'wf-md-evidence', branch_id: 'wf-md-evidence', stage_attempt_id: 'sa-wf-md-evidence', acceptance_status: 'accepted' },
  facts: [{
    subject: '绿珠',
    predicate: '身份',
    object: '圣女',
    aliases: ['圣女'],
    evidence: [{ path: '追踪/伏笔.md' }],
  }],
}));
projectAcceptedFacts(root, {
  status: 'accepted',
  commit_id: 'commit-md-evidence',
  workflow_id: 'wf-md-evidence',
  facts: [{
    subject: '绿珠',
    predicate: '身份',
    object: '圣女',
    aliases: ['圣女'],
    evidence: [{ path: '追踪/伏笔.md' }],
  }],
});
NODE
    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/markdown.json"
    md_file="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.packetMd)' "$TMP_DIR/markdown.json")"
    grep -q 'evidence: 追踪/伏笔.md' "$md_file"
}

@test "context assembler blocks relevant canonical facts whose evidence is missing or symlinked" {
    printf '外部证据\n' > "$TMP_DIR/outside.md"
    ln -s "$TMP_DIR/outside.md" "$PROJECT/追踪/外部证据.md"
    cat > "$PROJECT/追踪/memory/facts.jsonl" <<JSONL
{"fact_id":"fact.missing","subject":"绿珠","predicate":"身份","object":"圣女","aliases":["圣女"],"dependencies":[],"scope":{"book":"current"},"valid_from":"commit-a","valid_to":null,"evidence":[{"path":"追踪/不存在.md"}],"provenance":{"commit_id":"commit-a","workflow_id":"wf-a","acceptance_status":"accepted"},"confidence":1,"status":"active"}
{"fact_id":"fact.symlink","subject":"绿珠","predicate":"身份","object":"圣女","aliases":["圣女"],"dependencies":[],"scope":{"book":"current"},"valid_from":"commit-b","valid_to":null,"evidence":[{"path":"追踪/外部证据.md"}],"provenance":{"commit_id":"commit-b","workflow_id":"wf-b","acceptance_status":"accepted"},"confidence":1,"status":"active"}
JSONL
    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/invalid-evidence.json"
    node - "$TMP_DIR/invalid-evidence.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_memory_evidence_stale') throw new Error(JSON.stringify(out));
const debts = out.memory_debts || [];
if (!debts.some(entry => entry.fact_id === 'fact.missing' && entry.status === 'missing' && entry.severity === 'blocking')) throw new Error(JSON.stringify(debts));
if (!debts.some(entry => entry.fact_id === 'fact.symlink' && entry.status === 'symlink_escape' && entry.severity === 'blocking')) throw new Error(JSON.stringify(debts));
NODE
}

@test "context assembler blocks a relevant canonical fact when any evidence hash changed" {
    valid_hash="$(shasum -a 256 "$PROJECT/追踪/伏笔.md" | awk '{print $1}')"
    cat > "$PROJECT/追踪/memory/facts.jsonl" <<JSONL
{"fact_id":"fact.mixed","subject":"绿珠","predicate":"身份","object":"圣女","aliases":["圣女"],"dependencies":[],"scope":{"book":"current"},"valid_from":"commit-a","valid_to":null,"evidence":[{"path":"追踪/伏笔.md","hash":"sha256:$valid_hash"},{"path":"追踪/伏笔.md","hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}],"provenance":{"commit_id":"commit-a","workflow_id":"wf-a","acceptance_status":"accepted"},"confidence":1,"status":"active"}
JSONL
    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/mixed-evidence.json"
    node - "$TMP_DIR/mixed-evidence.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_memory_evidence_stale') throw new Error(JSON.stringify(out));
const debt = (out.memory_debts || []).find(entry => entry.fact_id === 'fact.mixed');
if (!debt || debt.status !== 'hash_mismatch' || debt.severity !== 'blocking') throw new Error(JSON.stringify(out.memory_debts));
NODE
}

@test "context assembler ignores stale facts replaced by a newer accepted section revision" {
    mkdir -p "$PROJECT/正文" "$PROJECT/追踪/private-short-extension"
    printf '当前采用正文。\n' > "$PROJECT/正文/第001节.md"
    current_hash="$(shasum -a 256 "$PROJECT/正文/第001节.md" | awk '{print $1}')"
    cat > "$PROJECT/追踪/private-short-extension/project-state.json" <<JSON
{"accepted_sections":[{"section_index":1,"canonical_path":"正文/第001节.md","section_commit_id":"commit-new","sha256":"$current_hash"}]}
JSON
    cat > "$PROJECT/追踪/memory/facts.jsonl" <<'JSONL'
{"fact_id":"fact.old","subject":"绿珠","predicate":"身份","object":"旧结论","aliases":["绿珠"],"dependencies":[],"scope":{"book":"current","section":1},"valid_from":"commit-old","valid_to":null,"evidence":[{"path":"正文/第001节.md","hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","source_commit_id":"commit-old"}],"provenance":{"commit_id":"commit-old","workflow_id":"wf-old","acceptance_status":"accepted"},"confidence":1,"status":"active"}
JSONL
    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章 绿珠" --budget 1200 --json > "$TMP_DIR/replaced-evidence.json"
    node - "$TMP_DIR/replaced-evidence.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'ok') throw new Error(JSON.stringify(out));
if ((out.memory_debts || []).some(item => item.fact_id === 'fact.old')) throw new Error(JSON.stringify(out.memory_debts));
if (!(out.omittedEntries || []).some(item => item.id === 'fact.old' && item.reason === 'superseded_canonical_revision')) throw new Error(JSON.stringify(out.omittedEntries));
NODE
}

@test "context assembler quarantines stale facts while their sections are in a controlled reacceptance queue" {
    mkdir -p "$PROJECT/正文" "$PROJECT/追踪/workflow/tasks/wf-recheck" "$PROJECT/追踪/workflow"
    printf '待重新验收的正文。\n' > "$PROJECT/正文/第006节.md"
    cat > "$PROJECT/追踪/workflow/tasks/wf-recheck/task.json" <<'JSON'
{"workflow_id":"wf-recheck","workflow_type":"private_short_startup","task_dir":"追踪/workflow/tasks/wf-recheck","state_version":1,"scope":"第6节","feedback_revision_queue":{"queue_id":"revision.assembly","source_stage":"full_story_assembly","status":"running","affected_sections":[6,7],"current_section_index":6}}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"workflow_id":"wf-recheck","task_dir":"追踪/workflow/tasks/wf-recheck","state_version":1}
JSON
    cat > "$PROJECT/追踪/memory/facts.jsonl" <<'JSONL'
{"fact_id":"fact.recheck","subject":"哥哥","predicate":"第6节状态","object":"旧状态","aliases":["哥哥"],"dependencies":[],"scope":{"book":"current","section":6},"valid_from":"commit-old","valid_to":null,"evidence":[{"path":"正文/第006节.md","hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","source_commit_id":"commit-old"}],"provenance":{"commit_id":"commit-old","workflow_id":"wf-recheck","acceptance_status":"accepted"},"confidence":1,"status":"active"}
JSONL
    node "$ASSEMBLER" --project-root "$PROJECT" --workflow-id wf-recheck --task write_section --target "第6节 哥哥" --budget 1200 --json > "$TMP_DIR/recheck-evidence.json"
    node - "$TMP_DIR/recheck-evidence.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'ok') throw new Error(JSON.stringify(out));
if ((out.memory_debts || []).some(item => item.fact_id === 'fact.recheck')) throw new Error(JSON.stringify(out.memory_debts));
if (!(out.omittedEntries || []).some(item => item.id === 'fact.recheck' && item.reason === 'pending_controlled_reacceptance')) throw new Error(JSON.stringify(out.omittedEntries));
NODE
}

@test "memory conflict detection keeps section-scoped facts independent" {
    node - "$REPO/scripts/lib/memory-conflict.js" <<'NODE'
const { detectMemoryConflicts } = require(process.argv[2]);
const entries = [
  { id: 's1', scope: { book: 'current', section: 1 }, facts: [{ key: '全篇:本节发生', value: '第一节事件' }] },
  { id: 's2', scope: { book: 'current', section: 2 }, facts: [{ key: '全篇:本节发生', value: '第二节事件' }] },
];
if (detectMemoryConflicts(entries).length !== 0) throw new Error(JSON.stringify(detectMemoryConflicts(entries)));
const conflict = detectMemoryConflicts([...entries, { id: 's1b', scope: { book: 'current', section: 1 }, facts: [{ key: '全篇:本节发生', value: '冲突版本' }] }]);
if (conflict.length !== 1 || conflict[0].scope.section !== 1) throw new Error(JSON.stringify(conflict));
NODE
}

@test "context assembler reports invalid advisory fact evidence without blocking prose context" {
    cat > "$PROJECT/追踪/memory/facts.jsonl" <<'JSONL'
{"fact_id":"fact.style-preference","subject":"叙述节奏","predicate":"偏好","object":"段落略长","aliases":[],"dependencies":[],"scope":{"book":"current"},"valid_from":"commit-style","valid_to":null,"evidence":[{"path":"追踪/不存在的风格卡.md"}],"provenance":{"commit_id":"commit-style","workflow_id":"wf-style","acceptance_status":"accepted"},"confidence":0.4,"critical":false,"status":"active"}
JSONL
    node "$ASSEMBLER" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/advisory-evidence.json"
    node - "$TMP_DIR/advisory-evidence.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'ok') throw new Error(JSON.stringify(out));
const debt = (out.memory_debts || []).find(entry => entry.fact_id === 'fact.style-preference');
if (!debt || debt.status !== 'missing' || debt.severity !== 'advisory') throw new Error(JSON.stringify(out.memory_debts));
if (!debt.recovery_action) throw new Error(JSON.stringify(debt));
NODE
}

@test "packaged bundle contains accepted fact retrieval runtime" {
    [ -f "$REPO/skills/novel-assistant/scripts/lib/memory-fact-store.js" ]
    [ -f "$REPO/skills/novel-assistant/scripts/lib/chinese-memory-retrieval.js" ]
    grep -q "rankChineseMemory" "$REPO/skills/novel-assistant/scripts/context-assembler.js"
}

@test "dynamic context budget favors the current workflow layer and unresolved dependencies" {
    node - "$REPO/scripts/lib/context-budget.js" <<'NODE'
const { allocateContextBudget } = require(process.argv[2]);
const text = '一二三四五六七八九十';
const result = allocateContextBudget({
  budget: 5,
  workflowLayer: 'chapter',
  sources: [
    { id: 'book-settled', kind: 'lore', layer: 'book', unresolvedDependencyCount: 0, rank: 10, text },
    { id: 'chapter-unresolved', kind: 'lore', layer: 'chapter', unresolvedDependencyCount: 2, rank: 10, text },
  ],
});
if (result.selected.length !== 1 || result.selected[0].id !== 'chapter-unresolved') throw new Error(JSON.stringify(result));
if (result.selected[0].allocation_reason.workflow_layer !== 'chapter') throw new Error(JSON.stringify(result.selected[0]));
if (result.selected[0].allocation_reason.unresolved_dependencies !== 2) throw new Error(JSON.stringify(result.selected[0]));
NODE
}
