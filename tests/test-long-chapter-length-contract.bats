#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "long chapter length contract parses explicit range and blocks underlength prose" {
    node - "$REPO" <<'NODE'
const assert=require('assert'),path=require('path');
const {evaluateLongChapterLength}=require(path.join(process.argv[2],'scripts/lib/long-chapter-length-contract.js'));
const contract='> 字数目标：3200（合法区间 2880—3840）\n\n## 字数合同\n- 目标字数：3200\n- 合法区间：2880—3840';
const short=evaluateLongChapterLength(contract,'汉'.repeat(2146));
assert.deepEqual({target:short.target,min:short.min,max:short.max,cjk:short.cjk_chars,status:short.status},{target:3200,min:2880,max:3840,cjk:2146,status:'blocking'});
assert.match(short.message,/2146.*2880.*3840/);
const pass=evaluateLongChapterLength(contract,'汉'.repeat(3000));
assert.equal(pass.status,'pass');
NODE
}

@test "long chapter length contract derives minus ten plus twenty only from an explicit target" {
    node - "$REPO" <<'NODE'
const assert=require('assert'),path=require('path');
const {evaluateLongChapterLength}=require(path.join(process.argv[2],'scripts/lib/long-chapter-length-contract.js'));
const result=evaluateLongChapterLength('- 目标字数：3000','汉'.repeat(2700));
assert.deepEqual({target:result.target,min:result.min,max:result.max,status:result.status},{target:3000,min:2700,max:3600,status:'pass'});
assert.equal(evaluateLongChapterLength('- 目标字数：3000','汉'.repeat(2699)).status,'blocking');
NODE
}

@test "long chapter length gate fails closed when the chapter contract has no length" {
    node - "$REPO" <<'NODE'
const assert=require('assert'),path=require('path');
const {evaluateLongChapterLength}=require(path.join(process.argv[2],'scripts/lib/long-chapter-length-contract.js'));
const result=evaluateLongChapterLength('# 章节 Brief\n没有篇幅字段','汉'.repeat(3200));
assert.equal(result.status,'blocking');
assert.equal(result.reason_code,'length_contract_missing');
NODE
}

@test "long chapter acceptance binding becomes stale when the accepted candidate changes" {
    node - "$REPO" <<'NODE'
const assert=require('assert'),path=require('path');
const api=require(path.join(process.argv[2],'scripts/lib/long-chapter-length-contract.js'));
const contract='- 目标字数：3200\n- 合法区间：2880—3840';
const accepted='汉'.repeat(3000);
const candidatePath='追踪/workflow/tasks/wf-long/artifacts/target/正文.md';
const binding=api.buildLongChapterAcceptanceBinding(contract,accepted,candidatePath);
assert.equal(binding.status,'bound');
assert.equal(binding.length_contract.cjk_chars,3000);
assert.match(binding.candidate_sha256,/^sha256:[0-9a-f]{64}$/);
assert.equal(api.validateLongChapterAcceptanceBinding(binding,contract,accepted,candidatePath).status,'current');
const stale=api.validateLongChapterAcceptanceBinding(binding,contract,`${accepted}后来补写`,candidatePath);
assert.equal(stale.status,'stale');
assert.equal(stale.reason_code,'candidate_digest_mismatch');
NODE
}

@test "legacy long chapter acceptance without a candidate binding requires revalidation" {
    node - "$REPO" <<'NODE'
const assert=require('assert'),path=require('path');
const api=require(path.join(process.argv[2],'scripts/lib/long-chapter-length-contract.js'));
const result=api.validateLongChapterAcceptanceBinding(null,'- 合法区间：2880—3840','汉'.repeat(3000),'候选.md');
assert.equal(result.status,'stale');
assert.equal(result.reason_code,'acceptance_binding_missing');
NODE
}

@test "deterministic chapter length evidence replaces contradictory model counts" {
    node - "$REPO" <<'NODE'
const assert=require('assert'),path=require('path');
const api=require(path.join(process.argv[2],'scripts/lib/long-chapter-length-contract.js'));
const binding=api.buildLongChapterAcceptanceBinding('- 目标字数：3400\n- 合法区间：3060—4080','汉'.repeat(3211),'候选.md');
const packet={
  handoff_summary:'候选正文 3724 字符，落在细纲约束 3060-4080 区间。',
  evidence:[
    {check:'word_count',value:3724,range:[3060,4080],pass:true},
    {check:'continuity',result:'pass',note:'承接关系正确。'},
    {kind:'machine_gate',items:[{rule:'length',characters:3724,status:'pass'},{rule:'beat_count',actual:16,status:'pass'}]},
  ],
};
api.normalizeLongChapterLengthEvidence(packet,binding);
assert.match(packet.handoff_summary,/3211 个中文字符/);
assert.doesNotMatch(JSON.stringify(packet),/3724/);
assert.equal(packet.evidence[0].check,'chapter_length');
assert.deepEqual({actual:packet.evidence[0].actual_cjk_chars,min:packet.evidence[0].allowed_min,max:packet.evidence[0].allowed_max},{actual:3211,min:3060,max:4080});
assert(packet.evidence.some(item=>item.check==='continuity'));
const machine=packet.evidence.find(item=>item.kind==='machine_gate');
assert(machine.items.some(item=>item.rule==='beat_count'));
assert(!machine.items.some(item=>item.rule==='length'));
NODE
}
