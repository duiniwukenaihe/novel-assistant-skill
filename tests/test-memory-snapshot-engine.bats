#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "memory snapshot engine derives a stage budget and keeps priority facts first" {
  run node - "$REPO/scripts/lib/memory-snapshot-engine.js" <<'NODE'
const api=require(process.argv[2]);
const task={runtime_guard:{token_estimate:{context_chars_budget:8000}}};
const small=api.deriveMemoryTokenBudget({task,query:'简短提要',stageId:'draft_next_section'});
const large=api.deriveMemoryTokenBudget({task,query:'人物关系与未决钩子'.repeat(120),stageId:'next_section_brief'});
if(!(small>0&&large>=small&&large<4000)) throw new Error(JSON.stringify({small,large}));
const priority=[{id:'must',text:'上一节未决钩子：母亲认出了签名。'}];
const ranked=Array.from({length:80},(_,i)=>({id:`fact-${i}`,text:`历史事实${i}：${'无关说明'.repeat(20)}`}));
const selected=api.selectWithinTokenBudget({priority,ranked,tokenBudget:small,serialize:item=>item.text});
if(!selected.entries.some(item=>item.id==='must')) throw new Error(JSON.stringify(selected));
if(selected.entries.length>=ranked.length+priority.length) throw new Error('budget did not trim low-priority memory');
if(selected.used_tokens>selected.token_budget&&!selected.priority_overflow) throw new Error(JSON.stringify(selected));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "memory revision changes only when selected memory or scope changes" {
  run node - "$REPO/scripts/lib/memory-snapshot-engine.js" <<'NODE'
const api=require(process.argv[2]);
const base={project_id:'p1',scope:{section_index:2},selected_memory:{facts:[{id:'f1',value:'A'}]}};
const first=api.buildMemoryRevision(base);
const same=api.buildMemoryRevision({...base,diagnostic_source_digest:'ignored'});
const changed=api.buildMemoryRevision({...base,selected_memory:{facts:[{id:'f1',value:'B'}]}});
if(first!==same||first===changed||!first.startsWith('sha256:')) throw new Error(JSON.stringify({first,same,changed}));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "short memory stage policy blocks stale receipts but preserves legacy compatibility" {
  run node - "$REPO/scripts/lib/short-memory-stage-policy.js" <<'NODE'
const api=require(process.argv[2]);
const current=api.classifyShortMemoryStage({status:'current'},'quality_gate');
const stale=api.classifyShortMemoryStage({status:'stale',stale_sources:['追踪/memory/facts.jsonl']},'section_accept_anchor');
const legacy=api.classifyShortMemoryStage({status:'not_recorded'},'quality_gate');
if(current.status!=='pass'||current.blocking) throw new Error(JSON.stringify(current));
if(stale.status!=='short_memory_context_refresh_required'||!stale.blocking||stale.resume_stage!=='quality_gate') throw new Error(JSON.stringify(stale));
if(legacy.status!=='legacy_memory_unverified'||legacy.blocking) throw new Error(JSON.stringify(legacy));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
