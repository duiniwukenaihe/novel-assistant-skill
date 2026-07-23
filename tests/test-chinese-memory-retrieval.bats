#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "exact Chinese alias returns the accepted evidence path" {
    node - "$REPO/scripts/lib/chinese-memory-retrieval.js" <<'NODE'
const { rankChineseMemory } = require(process.argv[2]);
const entries = [
  {
    id: 'fact.green-pearl.identity',
    subject: '绿珠',
    predicate: '身份',
    object: '圣女',
    aliases: ['绿珠', '圣女'],
    dependencies: ['血脉觉醒'],
    scope: { book: 'book-001', chapter_id: 'v01-c003' },
    valid_from: 'commit-002',
    valid_to: null,
    evidence: [{ path: '追踪/伏笔.md', note: 'accepted result packet' }],
    status: 'active',
  },
  {
    id: 'fact.saintess-rumor',
    subject: '宗门',
    predicate: '流言',
    object: '有人猜测圣女将现身',
    aliases: ['宗门流言'],
    dependencies: [],
    evidence: [{ path: '追踪/上下文.md', note: 'accepted result packet' }],
    status: 'active',
  },
];
const ranked = rankChineseMemory(entries, '圣女', { aliases: { 圣女: ['绿珠'] }, limit: 2 });
if (ranked.length !== 2) throw new Error(JSON.stringify(ranked));
if (ranked[0].entry.id !== 'fact.green-pearl.identity') throw new Error(JSON.stringify(ranked));
if (!ranked[0].evidence.some(item => item.path === '追踪/伏笔.md')) throw new Error(JSON.stringify(ranked[0]));
if (ranked[0].score <= ranked[1].score) throw new Error(JSON.stringify(ranked));
NODE
}

@test "dependency adjacency ranks before Han bigram overlap" {
    node - "$REPO/scripts/lib/chinese-memory-retrieval.js" <<'NODE'
const { rankChineseMemory } = require(process.argv[2]);
const entries = [
  { id: 'identity', subject: '绿珠', predicate: '身份', object: '圣女', aliases: ['圣女'], dependencies: ['血脉觉醒'], evidence: [{ path: '追踪/伏笔.md' }] },
  { id: 'cause', subject: '血脉觉醒', predicate: '导致', object: '身份显现', aliases: ['血脉觉醒'], dependencies: [], evidence: [{ path: '追踪/时间线.md' }] },
  { id: 'overlap', subject: '圣女候选', predicate: '住处', object: '圣女峰', aliases: [], dependencies: [], evidence: [{ path: '设定/地点.md' }] },
];
const ranked = rankChineseMemory(entries, '圣女', { limit: 3 });
if (ranked.map(item => item.entry.id).join(',') !== 'identity,cause,overlap') throw new Error(JSON.stringify(ranked));
NODE
}

@test "active memory index uses typed aliases, BM25 Han terms, and causal expansion" {
    node - "$REPO/scripts/lib/memory-active-index.js" "$REPO/tests/fixtures/memory-retrieval-golden.json" <<'NODE'
const fs=require('fs');
const { buildActiveMemoryIndex }=require(process.argv[2]);
const { retrieveFacts }=require(process.argv[2].replace('memory-active-index.js','chinese-memory-retrieval.js'));
const golden=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const index=buildActiveMemoryIndex(golden.entries);
const rows=retrieveFacts(index,golden.query,{limit:5});
const ids=rows.map(item=>item.fact_id);
for(const expected of golden.expected_top_ids) if(!ids.includes(expected)) throw new Error(JSON.stringify(rows));
for(const prohibited of golden.prohibited_ids) if(ids.includes(prohibited)) throw new Error(JSON.stringify(rows));
if(!rows[0].reasons.some(reason=>reason.code==='typed_alias_exact')) throw new Error(JSON.stringify(rows[0]));
if(!rows.find(item=>item.fact_id==='fact.bloodline.trigger').reasons.some(reason=>reason.code==='causal_dependency')) throw new Error(JSON.stringify(rows));
NODE
}
