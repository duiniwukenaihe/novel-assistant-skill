#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MODULE="$REPO_ROOT/scripts/lib/long-chapter-target.js"
  CONTEXT_MODULE="$REPO_ROOT/scripts/lib/long-stage-context-packet.js"
  RUNNER_EXEC="$REPO_ROOT/scripts/lib/workflow-runner-execution.js"
  STATE_MACHINE="$REPO_ROOT/scripts/workflow-state-machine.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/追踪/workflow/tasks" "$BOOK/设定" "$BOOK/追踪/memory" "$BOOK/追踪/schema" "$BOOK/正文/第2卷" "$BOOK/大纲/第2卷"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "V2 schema join maps volume-local chapter 2 to global chapter 27 and preserves titled draftPath" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"title":"开端","volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","contractPath":"追踪/章节契约/第2卷/第002章_开端.md","draftPath":"正文/第2卷/第002章_开端.md","handoffPath":"","auditStatus":"pass"}
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const result=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第002章.md',outlineSha256:'a'.repeat(64),workflowId:'wf-map'});
if(result.status!=='ok') throw new Error('expected ok, got '+JSON.stringify(result));
const t=result.target;
if(t.schema_version!=='long_chapter_target_v2') throw new Error('schema_version');
if(t.volume!=='第2卷') throw new Error('volume');
if(t.volume_chapter_no!==2) throw new Error('volume_chapter_no');
if(t.global_chapter_no!==27) throw new Error('global_chapter_no');
if(t.draft_path!=='正文/第2卷/第002章_开端.md') throw new Error('draft_path preserved');
if(t.contract_path!=='追踪/章节契约/第2卷/第002章_开端.md') throw new Error('contract_path preserved');
if(!/^sha256:[a-f0-9]{64}$/.test(t.target_id)) throw new Error('target_id format');
if(!t.candidate_draft_path.endsWith('正文.md')) throw new Error('candidate_draft_path');
process.stdout.write(JSON.stringify(t));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V2 schema join uses an explicit plannedDraftPath for an outline-only chapter" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第034章","chapterNo":34,"volume":"第2卷","volumeChapterNo":8,"globalDraftOrder":34,"outlinePath":"大纲/第2卷/细纲_第008章.md","contractPath":"追踪/章节契约/第2卷/第008章.md","draftPath":"","plannedDraftPath":"正文/第2卷/第008章.md"}
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const result=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第008章.md',outlineSha256:'a'.repeat(64),workflowId:'wf-planned'});
if(result.status!=='ok') throw new Error(JSON.stringify(result));
if(result.target.draft_path!=='正文/第2卷/第008章.md') throw new Error(JSON.stringify(result.target));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "story schema records a generic planned path without claiming an unwritten chapter is drafted" {
  mkdir -p "$BOOK/追踪/章节契约/第2卷"
  cat > "$BOOK/大纲/第2卷/细纲_第008章.md" <<'EOF'
# 细纲_第034章：药味识别·账本对账
EOF
  cat > "$BOOK/追踪/章节契约/第2卷/第008章.md" <<'EOF'
# 第008章契约
EOF

  run node "$REPO_ROOT/scripts/story-schema-build.js" "$BOOK" --write --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2];
const rows=fs.readFileSync(path.join(root,'追踪/schema/chapters.jsonl'),'utf8').trim().split(/\r?\n/).map(JSON.parse);
const row=rows.find((item)=>item.outlinePath==='大纲/第2卷/细纲_第008章.md');
if(!row||row.draftPath!==''||row.plannedDraftPath!=='正文/第2卷/第008章.md'||row.wordCount!==0||row.auditStatus!=='warn') throw new Error(JSON.stringify(row));
NODE
}

@test "legacy schema migration adds only missing planned paths and is idempotent" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第033章","chapterNo":33,"volume":"第2卷","volumeChapterNo":7,"globalDraftOrder":33,"outlinePath":"大纲/第2卷/细纲_第007章.md","contractPath":"追踪/章节契约/第2卷/第007章.md","draftPath":"正文/第2卷/第007章_已有正文.md"}
{"chapterId":"第034章","chapterNo":34,"volume":"第2卷","volumeChapterNo":8,"globalDraftOrder":34,"outlinePath":"大纲/第2卷/细纲_第008章.md","contractPath":"追踪/章节契约/第2卷/第008章.md","draftPath":""}
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path'),api=require(process.argv[2]),root=process.argv[3];
const scope=[{outline_path:'大纲/第2卷/细纲_第007章.md'},{outline_path:'大纲/第2卷/细纲_第008章.md'}];
const first=api.migrateLegacyPlannedDraftPaths(root,scope);
if(first.status!=='migrated'||first.changed_count!==1) throw new Error(JSON.stringify(first));
const rows=fs.readFileSync(path.join(root,'追踪/schema/chapters.jsonl'),'utf8').trim().split(/\r?\n/).map(JSON.parse);
if(rows[0].plannedDraftPath!==undefined||rows[0].draftPath!=='正文/第2卷/第007章_已有正文.md') throw new Error(JSON.stringify(rows[0]));
if(rows[1].draftPath!==''||rows[1].plannedDraftPath!=='正文/第2卷/第008章.md') throw new Error(JSON.stringify(rows[1]));
const second=api.migrateLegacyPlannedDraftPaths(root,scope);
if(second.status!=='noop'||second.changed_count!==0) throw new Error(JSON.stringify(second));
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath:scope[1].outline_path,outlineSha256:'a'.repeat(64),workflowId:'wf-migrated'});
if(target.status!=='ok'||target.target.draft_path!=='正文/第2卷/第008章.md') throw new Error(JSON.stringify(target));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "missing schema identity fails closed when schema authority is required" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第001章","chapterNo":1,"volume":"第1卷","outlinePath":"大纲/第1卷/细纲_第001章.md","draftPath":"正文/第1卷/第001章.md"}
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const result=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第002章.md',schemaAuthorityRequired:true});
if(result.status!=='missing_schema_identity') throw new Error('expected missing, got '+JSON.stringify(result));
if(result.reason_code!=='missing_schema_identity') throw new Error('reason_code');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "ambiguous schema identity fails closed when multiple rows match" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"dup-1","chapterNo":1,"volume":"第1卷","outlinePath":"大纲/第1卷/细纲_第001章.md","draftPath":"正文/第1卷/第001章_a.md"}
{"chapterId":"dup-2","chapterNo":2,"volume":"第1卷","outlinePath":"大纲/第1卷/细纲_第001章.md","draftPath":"正文/第1卷/第001章_b.md"}
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const result=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第1卷/细纲_第001章.md'});
if(result.status!=='ambiguous_schema_identity') throw new Error('expected ambiguous, got '+JSON.stringify(result));
if(result.match_count!==2) throw new Error('match_count');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "different outlines cannot share one global local contract or draft identity" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"a","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章-a.md","contractPath":"追踪/章节契约/第2卷/第002章.md","draftPath":"正文/第2卷/第002章.md"}
{"chapterId":"b","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章-b.md","contractPath":"追踪/章节契约/第2卷/第002章.md","draftPath":"正文/第2卷/第002章.md"}
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
for(const outlinePath of ['大纲/第2卷/细纲_第002章-a.md','大纲/第2卷/细纲_第002章-b.md']) {
  const result=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath,outlineSha256:'a'.repeat(64),workflowId:'wf-conflict'});
  if(result.status!=='ambiguous_schema_identity') throw new Error('shared canonical identity accepted: '+JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "incomplete V2 target is rejected by validateLongChapterTargetV2" {
  run node - "$MODULE" <<'NODE'
const api=require(process.argv[2]);
const partial={schema_version:'long_chapter_target_v2',outline_path:'大纲/第2卷/细纲_第002章.md'};
const v=api.validateLongChapterTargetV2(partial);
if(v.ok) throw new Error('expected incomplete');
if(!v.missing_fields.includes('target_id')) throw new Error('missing target_id');
if(!v.missing_fields.includes('volume')) throw new Error('missing volume');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "assertTargetsEqual reports diff and blocks when any field differs" {
  run node - "$MODULE" <<'NODE'
const api=require(process.argv[2]);
const a={schema_version:'long_chapter_target_v2',target_id:'sha256:'+'a'.repeat(64),outline_path:'大纲/第2卷/细纲_第002章.md',outline_sha256:'b'.repeat(64),volume:'第2卷',global_chapter_no:27,volume_chapter_no:2,contract_path:'追踪/章节契约/第2卷/第002章.md',draft_path:'正文/第2卷/第002章.md',candidate_draft_path:'追踪/workflow/tasks/w1/artifacts/t1/正文.md'};
const b={...a,outline_sha256:'c'.repeat(64)};
const same=api.assertTargetsEqual(a,a);
if(!same.ok) throw new Error('same should be ok');
const diff=api.assertTargetsEqual(a,b);
if(diff.ok) throw new Error('diff should fail');
if(diff.error.status!=='blocked_chapter_target_echo_mismatch') throw new Error('status code');
if(!diff.error.diff.includes('outline_sha256')) throw new Error('diff field');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "scope and user_goal cannot override the active V2 target" {
  run node - "$CONTEXT_MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const target={schema_version:'long_chapter_target_v2',target_id:'sha256:'+'1'.repeat(64),outline_path:'大纲/第2卷/细纲_第002章.md',outline_sha256:'1'.repeat(64),volume:'第2卷',global_chapter_no:27,volume_chapter_no:2,contract_path:'追踪/章节契约/第2卷/第002章.md',draft_path:'正文/第2卷/第002章.md',candidate_draft_path:'x'};
const task={workflow_id:'wf-t',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-t',scope:'继续当前已接受的全局第27—29章细纲',user_goal:'旧上下文下一目标：第34章',active_chapter_target:target,stage_execution:{chapter_target:target}};
const chapter=api.inferLongChapter('/tmp',task,'chapter_brief');
if(chapter!==2) throw new Error('chapter overridden by scope/user_goal: '+chapter);
const volume=api.inferVolume(task);
if(volume!=='第2卷') throw new Error('volume overridden: '+volume);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "formatLongChapterDisplay renders the dual identity" {
  run node - "$MODULE" <<'NODE'
const api=require(process.argv[2]);
const t={volume:'第2卷',global_chapter_no:27,volume_chapter_no:2};
const out=api.formatLongChapterDisplay(t);
if(out!=='全书第027章 / 第2卷第002章') throw new Error('format: '+out);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V2 validation recomputes target identity and binds the candidate path to workflow and target" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","contractPath":"追踪/章节契约/第2卷/第002章.md","draftPath":"正文/第2卷/第002章_开端.md"}
EOF
  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const built=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第002章.md',outlineSha256:'a'.repeat(64),workflowId:'wf-one'});
if(built.status!=='ok') throw new Error(JSON.stringify(built));
const target=built.target;
if(!target.candidate_draft_path.includes('/wf-one/')) throw new Error(target.candidate_draft_path);
if(target.candidate_draft_path.includes('/target/')) throw new Error(target.candidate_draft_path);
if(!api.validateLongChapterTargetV2(target,{workflowId:'wf-one'}).ok) throw new Error('valid target rejected');
if(api.validateLongChapterTargetV2(target,{workflowId:'wf-two'}).ok) throw new Error('foreign workflow candidate accepted');
const forgedId={...target,target_id:'sha256:'+'f'.repeat(64)};
if(api.validateLongChapterTargetV2(forgedId,{workflowId:'wf-one'}).ok) throw new Error('forged target_id accepted');
const forgedCandidate={...target,candidate_draft_path:'追踪/workflow/tasks/wf-one/artifacts/other/正文.md'};
if(api.validateLongChapterTargetV2(forgedCandidate,{workflowId:'wf-one'}).ok) throw new Error('forged candidate path accepted');
const other=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第002章.md',outlineSha256:'a'.repeat(64),workflowId:'wf-two'}).target;
if(other.candidate_draft_path===target.candidate_draft_path) throw new Error('workflow candidate paths collided');
const unsafe=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第002章.md',outlineSha256:'a'.repeat(64),workflowId:'../wf-two'});
if(unsafe.status==='ok') throw new Error('unsafe workflow id produced a target');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V2 schema identity requires explicit global and volume-local chapter numbers" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","outlinePath":"大纲/第2卷/细纲_第002章.md","contractPath":"追踪/章节契约/第2卷/第002章.md","draftPath":"正文/第2卷/第002章_开端.md"}
EOF
  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const result=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第002章.md',outlineSha256:'a'.repeat(64),workflowId:'wf-explicit'});
if(result.status!=='incomplete_v2_target') throw new Error('implicit global/local identity accepted: '+JSON.stringify(result));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V2 schema identity requires explicit contract and draft paths" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","draftPath":"正文/第2卷/第002章_开端.md"}
EOF
  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const result=api.buildLongChapterTargetV2({projectRoot:process.argv[3],outlinePath:'大纲/第2卷/细纲_第002章.md',outlineSha256:'a'.repeat(64),workflowId:'wf-paths'});
if(result.status!=='incomplete_v2_target') throw new Error('missing contract path was inferred: '+JSON.stringify(result));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "malformed schema authority fails closed instead of being silently skipped" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","draftPath":"正文/第2卷/第002章.md"}
{not-json}
EOF
  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const joined=api.joinSchemaByOutlinePath(process.argv[3],'大纲/第2卷/细纲_第002章.md');
if(joined.status!=='invalid_schema_authority') throw new Error(JSON.stringify(joined));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V2 prose acceptance resolves only the candidate draft before commit" {
  mkdir -p "$BOOK/正文/第2卷" "$BOOK/追踪/workflow/tasks/wf-draft/artifacts/0123456789abcdef" "$BOOK/追踪/章节契约/第2卷"
  printf '%s\n' 'canonical old prose' > "$BOOK/正文/第2卷/第002章_开端.md"
  printf '%s\n' 'candidate current prose' > "$BOOK/追踪/workflow/tasks/wf-draft/artifacts/0123456789abcdef/正文.md"
  printf '%s\n' 'brief is not prose' > "$BOOK/追踪/章节契约/第2卷/第002章.md"
  run node - "$CONTEXT_MODULE" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const api=require(process.argv[2]);
const root=process.argv[3];
const target={schema_version:'long_chapter_target_v2',target_id:'sha256:'+'0'.repeat(64),outline_path:'大纲/第2卷/细纲_第002章.md',outline_sha256:'a'.repeat(64),volume:'第2卷',global_chapter_no:27,volume_chapter_no:2,contract_path:'追踪/章节契约/第2卷/第002章.md',draft_path:'正文/第2卷/第002章_开端.md',candidate_draft_path:'追踪/workflow/tasks/wf-draft/artifacts/0123456789abcdef/正文.md'};
const resolved=api.resolveChapterDraft(root,{workflow_id:'wf-draft'},target,'prose_acceptance');
const expected=path.join(root,target.candidate_draft_path);
if(resolved!==expected) throw new Error(JSON.stringify({resolved,expected}));
fs.unlinkSync(expected);
const missing=api.resolveChapterDraft(root,{workflow_id:'wf-draft'},target,'prose_acceptance');
if(missing!=='') throw new Error('candidate missing fell back to canonical: '+missing);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "runner echo mismatch across five stages blocks the stage with the diff" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"title":"开端","volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","contractPath":"追踪/章节契约/第2卷/第002章_开端.md","draftPath":"正文/第2卷/第002章_开端.md","handoffPath":"","auditStatus":"pass"}
EOF
  run node - "$REPO_ROOT" "$BOOK" "$REPO_ROOT/tests/fixtures/fake-workflow-host.js" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',outlineFile=path.join(root,outlinePath),content='第二章细纲';
fs.mkdirSync(path.dirname(outlineFile),{recursive:true});fs.writeFileSync(outlineFile,content);
const outlineSha256=crypto.createHash('sha256').update(content).digest('hex');
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256,workflowId:'wf-echo'}).target;
const task={workflow_id:'wf-echo',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-echo',active_chapter_target:target,accepted_detail_outline_targets:[target],lifecycle_graph:{nodes:[]}};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
for(const stage of ['chapter_brief','brief_review','prose','prose_acceptance','chapter_commit']) {
  const execution={stage_id:stage,step_id:stage,expected_result_packet:`result.${stage}.json`,chapter_target:target,write_set:api.expectedLongChapterWriteSet(stage,target),chapter_targets:stage==='chapter_brief'?[target]:[]};
  const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
  const echoed=run.runnerPacket.stage_contract.chapter_target;
  if(!echoed||echoed.target_id!==target.target_id) throw new Error(`${stage}: target_id missing/mismatch`);
  if(echoed.volume_chapter_no!==target.volume_chapter_no) throw new Error(`${stage}: volume_chapter_no mismatch`);
  if(echoed.global_chapter_no!==target.global_chapter_no) throw new Error(`${stage}: global_chapter_no mismatch`);
  // Now simulate the host returning a different echo and assert equality check.
  const wrongEchoed={...echoed,outline_sha256:'f'.repeat(64)};
  const check=api.assertTargetsEqual(echoed,wrongEchoed);
  if(check.ok) throw new Error(`${stage}: equality check should fail`);
  if(check.error.status!=='blocked_chapter_target_echo_mismatch') throw new Error(`${stage}: error status`);
}
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "existing chapter brief runner targets test still passes against V2 target" {
  cat > "$BOOK/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第026章","chapterNo":26,"volume":"第2卷","volumeChapterNo":1,"globalDraftOrder":26,"outlinePath":"大纲/第2卷/细纲_第001章.md","contractPath":"追踪/章节契约/第2卷/第001章.md","draftPath":"正文/第2卷/第001章.md"}
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","contractPath":"追踪/章节契约/第2卷/第002章.md","draftPath":"正文/第2卷/第002章.md"}
{"chapterId":"第028章","chapterNo":28,"volume":"第2卷","volumeChapterNo":3,"globalDraftOrder":28,"outlinePath":"大纲/第2卷/细纲_第003章.md","contractPath":"追踪/章节契约/第2卷/第003章.md","draftPath":"正文/第2卷/第003章.md"}
EOF
  run node - "$REPO_ROOT" "$BOOK" "$REPO_ROOT/tests/fixtures/fake-workflow-host.js" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const accepted=[1,2,3].map((n)=>{
  const outlinePath=`大纲/第2卷/细纲_第${String(n).padStart(3,'0')}章.md`,content=`第${n}章细纲`,file=path.join(root,outlinePath);
  fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);
  const outlineSha256=crypto.createHash('sha256').update(content).digest('hex');
  return api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256,workflowId:'wf-brief'}).target;
});
if(!accepted.every(Boolean)) throw new Error('not all accepted built: '+JSON.stringify(accepted));
const legacyOutline={outline_path:accepted[0].outline_path,outline_sha256:accepted[0].outline_sha256};
const task={workflow_id:'wf-brief',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-brief',scope:'继续当前已接受的全局第27—29章细纲',user_goal:'旧上下文下一目标：第34章',accepted_detail_outline_targets:accepted,active_chapter_target:accepted[0],lifecycle_graph:{nodes:[{id:'chapter_brief',owner_module:'story-long-write',lifecycle_node:'chapter_brief'}]}};
const execution={stage_id:'chapter_brief',step_id:'chapter_brief',expected_result_packet:'result.json',write_set:[accepted[0].contract_path],chapter_target:accepted[0],chapter_targets:accepted};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
const ids=run.runnerPacket.stage_contract.chapter_targets.map((t)=>t.target_id);
if(ids.length!==accepted.length) throw new Error('chapter_targets count');
for(let i=0;i<ids.length;i+=1){
  if(ids[i]!==accepted[i].target_id) throw new Error('chapter_targets mismatch at '+i);
}
if(run.runnerPacket.stage_contract.chapter_target.target_id!==accepted[0].target_id) throw new Error('chapter_target mismatch');
const incompleteExecution={...execution,chapter_targets:[accepted[0],{outline_path:accepted[1].outline_path}]};
const incompleteRun=buildRunPreview(root,task,incompleteExecution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
if(incompleteRun.runnerPacket.stage_contract.chapter_target_missing!==true) throw new Error('incomplete chapter_targets list was silently shortened');
if(incompleteRun.runnerPacket.stage_contract.chapter_targets.length!==0) throw new Error('partial chapter_targets leaked into contract');
const dump=JSON.stringify(run.runnerPacket);
if(dump.includes('细纲_第027章')) throw new Error('stale global 027 leaked');
if(dump.includes('细纲_第034章')) throw new Error('stale user_goal 34 leaked');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
