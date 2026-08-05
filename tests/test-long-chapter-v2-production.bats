#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  FAKE="$REPO/tests/fixtures/fake-workflow-host.js"
  TMP_DIR="$(mktemp -d)"
  PROJECT="$TMP_DIR/book"
  mkdir -p "$PROJECT/大纲/第2卷" "$PROJECT/正文/第2卷" "$PROJECT/设定" "$PROJECT/追踪/schema" "$PROJECT/追踪/章节契约/第2卷"
  cat > "$PROJECT/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","draftPath":"正文/第2卷/第002章_开端.md","contractPath":"追踪/章节契约/第2卷/第002章_开端.md"}
EOF
  cat > "$PROJECT/设定/故事圣经.md" <<'EOF'
# 主角：李长安
身份：二十八岁刑侦技术员。
外部目标：查清失踪案。
内在渴望：避免因自己的失误失去证人。
缺陷：盲信内部通报。
能力边界：不负责现场指挥，越权会被停职。
第一卷成长里程碑：从被动检验走向主动调查。
# 主要对手：赵明远
目标：掩盖案件并保住位置。
资源：拥有内部权限和人脉。
边界与代价：不能公开动用暴力，失败会失去职务。
升级路径：从封锁线索升级到威胁证人。
# 关键配角：周宁
目标：公开真相。
行动边界：不能牺牲无辜证人。
# 人物关系与责任债
李长安欠周宁救命责任，与赵明远从师徒走向公开对峙。
# 成长里程碑
终局主动公开证据并承担代价。
EOF
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "detail outline review context binds the authoritative volume outline and exact review batch" {
  cat > "$PROJECT/大纲/第2卷/卷纲.md" <<'EOF'
# 第2卷卷纲
第004章必须完成公开裁决；第005章进入内门资格试炼。
EOF
  cat > "$PROJECT/大纲/第2卷/细纲_第002章.md" <<'EOF'
# 旧细纲
不在本批，不应进入上下文。
EOF
  cat > "$PROJECT/大纲/第2卷/细纲_第004章.md" <<'EOF'
# 第004章细纲
错误地跳过公开裁决。
EOF
  cat > "$PROJECT/大纲/第2卷/细纲_第005章.md" <<'EOF'
# 第005章细纲
错误地跳过内门资格试炼。
EOF

  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const targets=[4,5].map((chapter)=>{
  const outline_path=`大纲/第2卷/细纲_第${String(chapter).padStart(3,'0')}章.md`;
  const text=fs.readFileSync(path.join(root,outline_path),'utf8');
  return {outline_path,outline_sha256:crypto.createHash('sha256').update(text).digest('hex')};
});
const task={
  workflow_id:'wf-detail-review-context',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-detail-review-context',
  current_stage:'detail_outline_review',stage_execution:{stage_attempt_id:'attempt-2',review_targets:targets},
};
const packet=buildLongStageContextPacket({projectRoot:root,task,stage:'detail_outline_review'});
if(packet.status!=='assembled'||packet.review_target_count!==2) throw new Error(JSON.stringify(packet));
const paths=packet.source_files.map((item)=>item.path);
if(JSON.stringify(paths)!==JSON.stringify(['大纲/第2卷/卷纲.md',...targets.map((item)=>item.outline_path)])) throw new Error(JSON.stringify(paths));
const markdown=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
if(!markdown.includes('第004章必须完成公开裁决')||!markdown.includes('错误地跳过内门资格试炼')) throw new Error(markdown);
if(markdown.includes('不在本批，不应进入上下文')) throw new Error('unscoped outline leaked into packet');
const disk=JSON.parse(fs.readFileSync(path.join(root,packet.packet_json),'utf8'));
if(disk.authority_files.length!==1||disk.review_targets.length!==2||disk.source_files.some((item)=>item.truncated)) throw new Error(JSON.stringify(disk));

fs.unlinkSync(path.join(root,'大纲/第2卷/卷纲.md'));
const blocked=buildLongStageContextPacket({projectRoot:root,task,stage:'detail_outline_review'});
if(blocked.status!=='blocked_long_detail_outline_review_authority_missing'||blocked.blocking!==true) throw new Error(JSON.stringify(blocked));
NODE
}

@test "detail outline revision context binds volume authority, blocking findings, and failed targets only" {
  cat > "$PROJECT/大纲/第2卷/卷纲.md" <<'EOF'
# 第2卷卷纲
第004章必须完成公开裁决；第005章进入内门资格试炼。
EOF
  cat > "$PROJECT/大纲/第2卷/细纲_第004章.md" <<'EOF'
# 第004章细纲
错误地跳过公开裁决。
EOF
  cat > "$PROJECT/大纲/第2卷/细纲_第005章.md" <<'EOF'
# 第005章细纲
当前已通过，不应进入回炉上下文。
EOF

  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const targets=[4,5].map((chapter)=>{
  const outline_path=`大纲/第2卷/细纲_第${String(chapter).padStart(3,'0')}章.md`;
  const text=fs.readFileSync(path.join(root,outline_path),'utf8');
  return {outline_path,outline_sha256:crypto.createHash('sha256').update(text).digest('hex')};
});
const resultPath='追踪/workflow/tasks/wf-detail-revision/result-packets/detail_outline_review.result.json';
fs.mkdirSync(path.dirname(path.join(root,resultPath)),{recursive:true});
fs.writeFileSync(path.join(root,resultPath),JSON.stringify({
  workflow_id:'wf-detail-revision',stage_id:'detail_outline_review',review_decision:'revise',
  handoff_summary:'第004章与卷纲冲突。',next_recommendation:'只修订第004章。',
  outputs:{detail_outline_quality:{version:'detail_outline_quality_v2',status:'revise',identities:[
    {outline_path:targets[0].outline_path,status:'revise',findings:[{severity:'blocking',dimension:'causality',message:'必须补回公开裁决及其页面后果。'}]},
    {outline_path:targets[1].outline_path,status:'pass',findings:[{severity:'advisory',message:'不应注入回炉上下文。'}]},
  ]}},
},null,2));
const task={
  workflow_id:'wf-detail-revision',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-detail-revision',
  current_stage:'stage_detail_outline',detail_outline_review_targets:targets,
  detail_outline_review_failure:{status:'recorded',result_packet_path:resultPath,failed_targets:[targets[0].outline_path]},
  stage_execution:{stage_attempt_id:'attempt-revise',stage_id:'stage_detail_outline',revision_targets:[targets[0].outline_path],write_set:[targets[0].outline_path]},
};
const packet=buildLongStageContextPacket({projectRoot:root,task,stage:'stage_detail_outline'});
if(packet.status!=='assembled'||packet.revision_target_count!==1) throw new Error(JSON.stringify(packet));
const paths=packet.source_files.map((item)=>item.path);
if(JSON.stringify(paths)!==JSON.stringify(['大纲/第2卷/卷纲.md',resultPath,targets[0].outline_path])) throw new Error(JSON.stringify(paths));
const markdown=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
if(!markdown.includes('第004章必须完成公开裁决')||!markdown.includes('必须补回公开裁决及其页面后果')) throw new Error(markdown);
if(markdown.includes('当前已通过，不应进入回炉上下文')||markdown.includes('不应注入回炉上下文')) throw new Error('unscoped review material leaked into revision packet');
fs.unlinkSync(path.join(root,resultPath));
const blocked=buildLongStageContextPacket({projectRoot:root,task,stage:'stage_detail_outline'});
if(blocked.status!=='blocked_long_detail_outline_revision_review_evidence_missing'||blocked.blocking!==true) throw new Error(JSON.stringify(blocked));
NODE
}

@test "context packet uses frozen V2 target: global display, local files, candidate prose" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const targetApi=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',outline='第二章细纲',outlineFile=path.join(root,outlinePath);
fs.writeFileSync(outlineFile,outline);
const target=targetApi.buildLongChapterTargetV2({
  projectRoot:root,outlinePath,
  outlineSha256:crypto.createHash('sha256').update(outline).digest('hex'),workflowId:'wf-context',
}).target;
fs.writeFileSync(path.join(root,target.draft_path),'卷内第二章旧稿');
fs.writeFileSync(path.join(root,target.contract_path),'章节契约不是正文');
fs.writeFileSync(path.join(root,'大纲/第2卷/细纲_第002章_旧.md'),'不应读取的遗留细纲');
fs.writeFileSync(path.join(root,'追踪/章节契约/第2卷/第002章_旧.md'),'不应读取的遗留契约');
fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});
fs.writeFileSync(path.join(root,target.candidate_draft_path),'当前候选正文');
const task={
  workflow_id:'wf-context',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-context',current_stage:'prose_acceptance',
  scope:'第34章',user_goal:'继续第34章',active_chapter_target:target,stage_execution:{chapter_target:target},
};
const packet=buildLongStageContextPacket({projectRoot:root,task,stage:'prose_acceptance'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
if(packet.chapter!==2||packet.global_chapter_no!==27||packet.chapter_identity!=='全书第027章 / 第2卷第002章') throw new Error(JSON.stringify(packet));
if(packet.draft!==target.candidate_draft_path) throw new Error(JSON.stringify({draft:packet.draft,target}));
const disk=JSON.parse(fs.readFileSync(path.join(root,packet.packet_json),'utf8'));
if(disk.chapter_target_v2.target_id!==target.target_id||disk.chapter_identity!==packet.chapter_identity) throw new Error(JSON.stringify(disk));
const chapterContext=JSON.parse(fs.readFileSync(path.join(root,'追踪/context-pack/第2卷/第002章.json'),'utf8'));
if(chapterContext.sourceFiles.outline!==target.outline_path||chapterContext.sourceFiles.currentContract!==target.contract_path) throw new Error(JSON.stringify(chapterContext.sourceFiles));
const markdown=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
if(!markdown.includes('全书第027章 / 第2卷第002章')||markdown.includes('第034章')) throw new Error(markdown);
const externalOutline=path.join(root,'..','outside-outline.md');
fs.writeFileSync(externalOutline,outline);fs.unlinkSync(outlineFile);fs.symlinkSync(externalOutline,outlineFile);
const escaped=buildLongStageContextPacket({projectRoot:root,task,stage:'prose_acceptance'});
if(escaped.status!=='blocked_long_chapter_context_target_mismatch'||escaped.blocking!==true) throw new Error(JSON.stringify(escaped));
fs.unlinkSync(outlineFile);fs.writeFileSync(outlineFile,outline);
fs.unlinkSync(path.join(root,target.candidate_draft_path));
const missing=buildLongStageContextPacket({projectRoot:root,task,stage:'prose_acceptance'});
if(missing.status!=='blocked_long_chapter_candidate_missing'||missing.blocking!==true) throw new Error(JSON.stringify(missing));
NODE
}

@test "chapter brief context binds the exact outline without requiring its output contract to exist" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',content='第二章细纲',outlineFile=path.join(root,outlinePath);fs.writeFileSync(outlineFile,content);
fs.writeFileSync(path.join(root,'追踪/章节契约/第2卷/第002章_旧.md'),'不应读取的旧契约');
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(content).digest('hex'),workflowId:'wf-brief-context'}).target;
const task={workflow_id:'wf-brief-context',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-brief-context',current_stage:'chapter_brief',active_chapter_target:target,stage_execution:{chapter_target:target}};
const packet=buildLongStageContextPacket({projectRoot:root,task,stage:'chapter_brief'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
const context=JSON.parse(fs.readFileSync(path.join(root,'追踪/context-pack/第2卷/第002章.json'),'utf8'));
if(context.sourceFiles.outline!==target.outline_path||context.sourceFiles.currentContract!==null) throw new Error(JSON.stringify(context.sourceFiles));
NODE
}

@test "chapter brief receives the complete frozen outline and rejects hash drift without trusting an old contract" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md';
const outline=`# 第二章完整细纲\n${'推进现场证据。'.repeat(1800)}\n冻结细纲结尾权威标记`;
fs.writeFileSync(path.join(root,outlinePath),outline);
const outlineSha256=crypto.createHash('sha256').update(outline).digest('hex');
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256,workflowId:'wf-brief-authority'}).target;
fs.writeFileSync(path.join(root,target.contract_path),'旧 Brief 污染标记：不得成为 chapter_brief 输入。');
const task={workflow_id:'wf-brief-authority',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-brief-authority',current_stage:'chapter_brief',active_chapter_target:target,stage_execution:{chapter_target:target}};
const packet=buildLongStageContextPacket({projectRoot:root,task,stage:'chapter_brief'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
const markdown=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
if(!markdown.includes(outline)||!markdown.includes('冻结细纲结尾权威标记')) throw new Error('complete frozen outline missing');
if(markdown.includes('旧 Brief 污染标记')) throw new Error('old contract overrode frozen outline authority');
const disk=JSON.parse(fs.readFileSync(path.join(root,packet.packet_json),'utf8'));
const authority=disk.source_files.find((item)=>item.kind==='frozen_chapter_outline');
if(!authority||authority.path!==outlinePath||authority.content_digest!==outlineSha256||authority.truncated!==false) throw new Error(JSON.stringify(disk.source_files));
fs.appendFileSync(path.join(root,outlinePath),'\n未经冻结的漂移');
const blocked=buildLongStageContextPacket({projectRoot:root,task,stage:'chapter_brief'});
if(blocked.status!=='blocked_long_chapter_target_incomplete'||!blocked.missing_fields.includes('outline_sha256_mismatch')) throw new Error(JSON.stringify(blocked));
NODE
}

@test "brief review receives both the current brief and the complete frozen outline" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',outline='# 第二章细纲\n必须让主角公开证据。\n冻结细纲审阅标记';
fs.writeFileSync(path.join(root,outlinePath),outline);
const outlineSha256=crypto.createHash('sha256').update(outline).digest('hex');
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256,workflowId:'wf-brief-review-authority'}).target;
const brief='# 当前章节 Brief\n场景改为私下销毁证据。\n当前 Brief 审阅标记';
fs.writeFileSync(path.join(root,target.contract_path),brief);
const task={workflow_id:'wf-brief-review-authority',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-brief-review-authority',current_stage:'brief_review',active_chapter_target:target,stage_execution:{chapter_target:target}};
const packet=buildLongStageContextPacket({projectRoot:root,task,stage:'brief_review'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
const markdown=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
if(!markdown.includes('冻结细纲审阅标记')||!markdown.includes('当前 Brief 审阅标记')) throw new Error(markdown);
const disk=JSON.parse(fs.readFileSync(path.join(root,packet.packet_json),'utf8'));
const sources=disk.source_files.filter((item)=>['frozen_chapter_outline','current_chapter_brief'].includes(item.kind));
if(sources.length!==2||sources.some((item)=>item.truncated!==false)) throw new Error(JSON.stringify(disk.source_files));
const blocked=buildLongStageContextPacket({projectRoot:root,task,stage:'brief_review',options:{tokenBudget:1}});
if(blocked.status!=='blocked_required_context_budget'||blocked.required_tokens<=1) throw new Error(JSON.stringify(blocked));
fs.unlinkSync(path.join(root,target.contract_path));
const missing=buildLongStageContextPacket({projectRoot:root,task,stage:'brief_review'});
if(missing.status!=='blocked_long_chapter_brief_authority_missing'||missing.blocking!==true) throw new Error(JSON.stringify(missing));
NODE
}

@test "long chapter Brief budget gate rejects contradictory beat totals without requiring one fixed template" {
  node - "$REPO" <<'NODE'
const path=require('path');
const {inspectLongChapterBriefBudget}=require(path.join(process.argv[2],'scripts/lib/long-chapter-brief-quality.js'));
const inconsistent=`# Chapter Brief\n目标字数：3200\n| 拍 | 行动 | 字数 |\n|---|---|---|\n| 1 | 开场 | 200 |\n| 2 | 推进 | 300 |\n| **合计** | | **3200** |\n`;
const blocked=inspectLongChapterBriefBudget(inconsistent);
if(blocked.status!=='revise'||blocked.beat_total!==500||blocked.declared_total!==3200||blocked.findings[0]?.code!=='brief_beat_total_mismatch') throw new Error(JSON.stringify(blocked));
const consistent=inspectLongChapterBriefBudget(inconsistent.replace('**3200**','**500**'));
if(consistent.status!=='pass'||consistent.beat_total!==500) throw new Error(JSON.stringify(consistent));
const freeform=inspectLongChapterBriefBudget('# Brief\n目标字数：3200\n按场景自然推进。');
if(freeform.status!=='not_applicable') throw new Error(JSON.stringify(freeform));
NODE
}

@test "long chapter Brief compactness gate uses the structured nominal target at the 45 and 55 percent boundaries" {
  node - "$REPO" <<'NODE'
const path=require('path');
const {inspectLongChapterBriefBudget}=require(path.join(process.argv[2],'scripts/lib/long-chapter-brief-quality.js'));
const cjkCount=(text)=>(String(text||'').match(/\p{Script=Han}/gu)||[]).length;
function briefAt(cjk){
  const scaffold=`# Chapter Brief
> 字数目标：6400（合法区间 5760—7680）
| Beat | Action | Words |
|---|---|---|
| 1 | opening | 1600 |
| 2 | turn | 1600 |
| **total** | | **3200** |
`;
  return `${scaffold}${'情'.repeat(Math.max(0,cjk-cjkCount(scaffold)))}`;
}
const pass=inspectLongChapterBriefBudget(briefAt(1440),{targetWords:3200});
if(pass.status!=='pass'||pass.brief_cjk!==1440||pass.target_words!==3200||pass.target_source!=='structured_target'||pass.brief_target_ratio!==0.45) throw new Error(JSON.stringify(pass));
const compress=inspectLongChapterBriefBudget(briefAt(1441),{targetWords:3200});
if(compress.status!=='revise'||compress.findings.every((item)=>item.code!=='brief_compactness_above_target')) throw new Error(JSON.stringify(compress));
const excessive=inspectLongChapterBriefBudget(briefAt(1761),{targetWords:3200});
if(excessive.status!=='revise'||excessive.findings.every((item)=>item.code!=='brief_compactness_excessive')) throw new Error(JSON.stringify(excessive));
NODE
}

@test "long chapter Brief compactness gate parses the nominal target before its legal interval" {
  node - "$REPO" <<'NODE'
const path=require('path');
const {inspectLongChapterBriefBudget}=require(path.join(process.argv[2],'scripts/lib/long-chapter-brief-quality.js'));
const cjkCount=(text)=>(String(text||'').match(/\p{Script=Han}/gu)||[]).length;
const scaffold=`# Chapter Brief
> Target: 3200
> 字数目标：3200（合法区间 2880—3840）
| Beat | Action | Words |
|---|---|---|
| 1 | opening | 1600 |
| 2 | turn | 1600 |
| **total** | | **3200** |
`;
const brief=`${scaffold}${'情'.repeat(1500-cjkCount(scaffold))}`;
const result=inspectLongChapterBriefBudget(brief);
if(result.status!=='revise'||result.target_words!==3200||result.target_source!=='brief_nominal_target'||result.brief_target_ratio!==0.469) throw new Error(JSON.stringify(result));
NODE
}

@test "long chapter Brief compactness gate counts primary beats once and rejects less than 150 words per beat" {
  node - "$REPO" <<'NODE'
const path=require('path');
const {inspectLongChapterBriefBudget}=require(path.join(process.argv[2],'scripts/lib/long-chapter-brief-quality.js'));
const primary16=Array.from({length:16},(_,index)=>`- B${index+1} scene change`).join('\n');
const repeated=Array.from({length:3},()=>Array.from({length:16},(_,index)=>`- verify B${index+1}`).join('\n')).join('\n');
const normal=inspectLongChapterBriefBudget(`# Brief\n## Must-have beats\n${primary16}\n## Acceptance\n${repeated}`,{targetWords:3200});
if(normal.beat_count!==16||normal.average_words_per_beat!==200||normal.findings.some((item)=>item.code==='brief_beat_density_too_high')) throw new Error(JSON.stringify(normal));
const primary22=Array.from({length:22},(_,index)=>`${index+1}. scene change`).join('\n');
const dense=inspectLongChapterBriefBudget(`# Brief\n## Beat Sheet\n${primary22}\n## Acceptance\ncomplete`,{targetWords:3200});
if(dense.status!=='revise'||dense.beat_count!==22||dense.average_words_per_beat!==145||dense.findings.every((item)=>item.code!=='brief_beat_density_too_high')) throw new Error(JSON.stringify(dense));
NODE
}

@test "long chapter Brief compactness gate uses an absolute fallback only when no target exists" {
  node - "$REPO" <<'NODE'
const path=require('path');
const {inspectLongChapterBriefBudget}=require(path.join(process.argv[2],'scripts/lib/long-chapter-brief-quality.js'));
const result=inspectLongChapterBriefBudget(`# Brief\n${'情'.repeat(1801)}`);
if(result.status!=='revise'||result.target_words!==0||result.target_source!=='missing'||result.findings.every((item)=>item.code!=='brief_compactness_target_missing_excessive')) throw new Error(JSON.stringify(result));
NODE
}

@test "prose retry context includes the existing candidate and prior machine blockers" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',content='第二章细纲';fs.writeFileSync(path.join(root,outlinePath),content);
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(content).digest('hex'),workflowId:'wf-prose-retry'}).target;
fs.writeFileSync(path.join(root,target.contract_path),'# 当前章节 Brief\n完整 Brief 权威标记\n- 合法区间：2880—3840');fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});
fs.writeFileSync(path.join(root,target.candidate_draft_path),'当前候选正文包含待修标点。');
const rejected='追踪/workflow/tasks/wf-prose-retry/result-packets/prose_acceptance.result.json';fs.mkdirSync(path.dirname(path.join(root,rejected)),{recursive:true});
fs.writeFileSync(path.join(root,rejected),JSON.stringify({workflow_id:'wf-prose-retry',stage_id:'prose_acceptance',step_status:'blocked',chapter_target:target,blocking_findings:[{code:'ascii_quotes',message:'将半角直引号统一为中文弯引号。'}]}));
const task={workflow_id:'wf-prose-retry',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-prose-retry',current_stage:'prose',active_chapter_target:target,machine:{last_transition:'runtime_reconciled',last_result_packet:rejected},stage_execution:{attempt_no:2,chapter_target:target}};
const packet=buildLongStageContextPacket({projectRoot:root,task,stage:'prose'});
if(packet.status!=='assembled'||packet.draft!==target.candidate_draft_path) throw new Error(JSON.stringify(packet));
const markdown=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
if(!markdown.includes('完整 Brief 权威标记')||!markdown.includes('当前候选正文包含待修标点。')||!markdown.includes('将半角直引号统一为中文弯引号。')) throw new Error(markdown);
const disk=JSON.parse(fs.readFileSync(path.join(root,packet.packet_json),'utf8'));
const brief=disk.source_files.find((item)=>item.kind==='current_chapter_brief');
if(!brief||brief.path!==target.contract_path||brief.truncated!==false) throw new Error(JSON.stringify(disk.source_files));
NODE
}

@test "chapter commit context blocks an underlength candidate before the host can write canonical prose" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildLongStageContextPacket}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',content='第二章细纲',outlineFile=path.join(root,outlinePath);fs.writeFileSync(outlineFile,content);
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(content).digest('hex'),workflowId:'wf-length-preflight'}).target;
fs.writeFileSync(path.join(root,target.contract_path),'- 目标字数：3200\n- 合法区间：2880—3840');
fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});
fs.writeFileSync(path.join(root,target.candidate_draft_path),'汉'.repeat(2146));
const task={workflow_id:'wf-length-preflight',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-length-preflight',current_stage:'chapter_commit',active_chapter_target:target,stage_execution:{chapter_target:target}};
const blocked=buildLongStageContextPacket({projectRoot:root,task,stage:'chapter_commit'});
if(blocked.status!=='blocked_long_chapter_length_contract'||blocked.blocking!==true||blocked.length_contract.cjk_chars!==2146) throw new Error(JSON.stringify(blocked));
fs.writeFileSync(path.join(root,target.candidate_draft_path),'汉'.repeat(3000));
const pass=buildLongStageContextPacket({projectRoot:root,task,stage:'chapter_commit'});
if(pass.status!=='assembled') throw new Error(JSON.stringify(pass));
NODE
}

@test "long chapter commit is a deterministic transaction command and never delegates canonical prose writes to the host" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),cp=require('child_process');
const repo=process.argv[2],root=process.argv[3],state=path.join(repo,'scripts/workflow-state-machine.js');
const created=cp.spawnSync(process.execPath,[state,'create','--workflow-type','long_write','--project-root',root,'--scope','第2卷第2章','--user-goal','提交当前章','--json'],{encoding:'utf8'});
if(created.status!==0) throw new Error(created.stdout||created.stderr);
const task=JSON.parse(created.stdout).task,taskFile=path.join(root,task.task_dir,'task.json');
const outlinePath='大纲/第2卷/细纲_第002章.md',outline='第二章细纲';fs.writeFileSync(path.join(root,outlinePath),outline);
const target=require(path.join(repo,'scripts/lib/long-chapter-target.js')).buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(outline).digest('hex'),workflowId:task.workflow_id}).target;
fs.appendFileSync(path.join(root,'追踪/schema/chapters.jsonl'),'\n'+JSON.stringify({chapterId:'第028章',chapterNo:28,volume:'第2卷',volumeChapterNo:3,globalDraftOrder:28,outlinePath:'大纲/第2卷/细纲_第003章.md',draftPath:'正文/第2卷/第003章_后续.md',contractPath:'追踪/章节契约/第2卷/第003章_后续.md'})+'\n');
const nextOutline='第三章细纲';fs.writeFileSync(path.join(root,'大纲/第2卷/细纲_第003章.md'),nextOutline);
const nextTarget=require(path.join(repo,'scripts/lib/long-chapter-target.js')).buildLongChapterTargetV2({projectRoot:root,outlinePath:'大纲/第2卷/细纲_第003章.md',outlineSha256:crypto.createHash('sha256').update(nextOutline).digest('hex'),workflowId:task.workflow_id}).target;
fs.writeFileSync(path.join(root,target.contract_path),'- 目标字数：3200\n- 合法区间：2880—3840');
fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});fs.writeFileSync(path.join(root,target.candidate_draft_path),'汉'.repeat(3000));
fs.writeFileSync(path.join(root,target.draft_path),'汉'.repeat(3000));
const template=JSON.parse(cp.spawnSync(process.execPath,[state,'templates','--json'],{encoding:'utf8'}).stdout).templates.find(item=>item.workflow_type==='long_write');
const ids=template.stages.map(item=>item.stage_id),commitIndex=ids.indexOf('chapter_commit'),now=new Date().toISOString();
task.current_stage='chapter_commit';task.current_step='chapter_commit';task.status='running';task.active_chapter_target=target;task.accepted_detail_outline_targets=[target,nextTarget];task.consumed_detail_outline_targets=[];
task.machine={...(task.machine||{}),completed_stages:ids.slice(0,commitIndex),remaining_stages:ids.slice(commitIndex),allowed_actions:['continue_next_stage','pause']};
const completed=ids.slice(0,commitIndex),reviewResults={};for(const stage of template.stages)if(completed.includes(stage.stage_id)&&stage.review_requirement.required)reviewResults[stage.stage_id]={status:'accepted',verification_result:'pass',result_packet_path:'fixture://accepted'};
task.lifecycle_graph={version:'1.0.0',current_node:'chapter_commit',asset_target:{kind:'chapter',id:'current-chapter'},completed_nodes:completed,invalidated_nodes:[],review_results:reviewResults,last_transition_validation:null,nodes:template.stages.map((stage,index)=>({id:stage.stage_id,order:index,owner_module:stage.owner_module,asset_target:stage.asset_target,review_requirement:stage.review_requirement,status:index<commitIndex?'accepted':'missing'}))};
const binding=require(path.join(repo,'scripts/lib/long-chapter-length-contract.js')).buildLongChapterAcceptanceBinding('- 合法区间：2880—3840','汉'.repeat(3000),target.candidate_draft_path);
fs.mkdirSync(path.join(root,'追踪/story-system'),{recursive:true});fs.writeFileSync(path.join(root,'追踪/story-system/write-policy.json'),JSON.stringify({schemaVersion:'1.0.0',mode:'strict'},null,2)+'\n');
task.stage_attempt_history=[];
for(const stageId of ['prose','prose_acceptance']){
 const packetRel=`${task.task_dir}/result-packets/${stageId}.result.json`,packetFile=path.join(root,packetRel);fs.mkdirSync(path.dirname(packetFile),{recursive:true});
 const packet={workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:stageId,step_id:stageId,step_status:'completed',verification_result:stageId==='prose'?'pass':'accepted',chapter_target:target,[stageId==='prose'?'chapter_prose_candidate':'chapter_prose_acceptance']:binding};
 fs.writeFileSync(packetFile,JSON.stringify(packet,null,2)+'\n');
 task.stage_attempt_history.push({stage_attempt_id:`sa-${stageId}`,work_unit_id:`wu-${stageId}`,stage_id:stageId,status:'completed',expected_result_packet:packetRel,accepted_result_packet:packetRel,result_packet:packetRel});
}
const expected=`${task.task_dir}/result-packets/chapter_commit.result.json`;
task.stage_execution={status:'running',stage_attempt_id:'sa-chapter-commit',work_unit_id:'wu-chapter-commit',work_unit_scope:'第2卷第2章',stage_id:'chapter_commit',step_id:'chapter_commit',expected_result_packet:expected,owner_module:'story-workflow',chapter_target:target,write_set:[target.draft_path],memory_contract_version:0,confirmation_context:{status:'confirmed',target_scope:'第2卷第2章'}};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const initialized=cp.spawnSync(process.execPath,[state,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:deterministic-commit','--json'],{encoding:'utf8'});
if(initialized.status!==0) throw new Error(initialized.stdout||initialized.stderr);
const ready=JSON.parse(fs.readFileSync(taskFile,'utf8')),command=String((ready.stage_execution||{}).execution_command||'');
if(!command.includes('long-chapter-commit-finalize.js')||!command.includes('--apply')||String(ready.stage_execution.host_execution_mode||'')!=='deterministic_command') throw new Error(JSON.stringify(ready.stage_execution));
const currentScope='全书第027章 / 第2卷第002章';
if(ready.scope!==currentScope||ready.lifecycle?.scope!==currentScope||ready.unit_lifecycle?.current_scope!==currentScope||ready.stage_execution?.work_unit_scope!==currentScope||ready.stage_execution?.confirmation_context?.target_scope!==currentScope) throw new Error(JSON.stringify({reason:'runtime reconcile kept stale chapter scope',scope:ready.scope,lifecycle_scope:ready.lifecycle?.scope,unit_scope:ready.unit_lifecycle?.current_scope,execution_scope:ready.stage_execution?.work_unit_scope,confirmation_scope:ready.stage_execution?.confirmation_context?.target_scope}));
if(ready.stage_execution?.memory_context?.memory_contract?.query?.scope?.target!==currentScope) throw new Error(JSON.stringify({reason:'runtime reconcile kept stale memory query scope',memory_context:ready.stage_execution?.memory_context}));
const excluded=[ready.task_dir, '追踪/context-pack','追踪/story-system/transactions','追踪/story-system/commits','追踪/story-system/projection-log.jsonl','追踪/workflow/.workflow.lock','追踪/workflow/current-task.json','追踪/workflow/current-task.md','追踪/workflow/history.jsonl','追踪/workflow/families','追踪/workflow/sessions','追踪/workflow/task-family-index.json'];
const files={};function visit(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const abs=path.join(dir,entry.name),rel=path.relative(root,abs).split(path.sep).join('/');if(rel==='.git'||rel.startsWith('.git/')||excluded.some(item=>rel===item||rel.startsWith(`${item}/`)))continue;if(entry.isDirectory())visit(abs);else if(entry.isFile())files[rel]=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(abs)).digest('hex')}`;}}
visit(root);ready.stage_execution.write_snapshot={version:1,captured_at:new Date().toISOString(),authorized_write_set:[target.draft_path],excluded_paths:excluded,files};fs.writeFileSync(taskFile,JSON.stringify(ready,null,2)+'\n');
const executed=cp.spawnSync(process.execPath,[path.join(repo,'scripts/long-chapter-commit-finalize.js'),'--project-root',root,'--workflow-id',task.workflow_id,'--apply','--json'],{encoding:'utf8'});
if(executed.status!==0) throw new Error(executed.stdout||executed.stderr);const out=JSON.parse(executed.stdout);
if(out.status!=='applied'||out.accepted_commit_id===''||out.host_started===true) throw new Error(executed.stdout);
const after=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(after.current_stage!=='chapter_brief'||after.active_chapter_target?.target_id!==nextTarget.target_id||after.consumed_detail_outline_targets.length!==1) throw new Error(JSON.stringify(after));
const nextScope='全书第028章 / 第2卷第003章';
if(after.scope!==nextScope||after.lifecycle?.scope!==nextScope||after.unit_lifecycle?.current_scope!==nextScope||after.stage_execution?.work_unit_scope!==nextScope) throw new Error(JSON.stringify({reason:'next chapter scope was not synchronized',scope:after.scope,lifecycle_scope:after.lifecycle?.scope,unit_scope:after.unit_lifecycle?.current_scope,execution_scope:after.stage_execution?.work_unit_scope}));
if(after.stage_execution?.confirmation_context&&after.stage_execution.confirmation_context.target_scope!==nextScope) throw new Error(JSON.stringify({reason:'confirmation still points at prior chapter',confirmation:after.stage_execution.confirmation_context}));
if(fs.readFileSync(path.join(root,target.draft_path),'utf8')!==fs.readFileSync(path.join(root,target.candidate_draft_path),'utf8')) throw new Error('canonical draft does not match candidate');
const packet=JSON.parse(fs.readFileSync(path.join(root,expected),'utf8'));
if(packet.chapter_commit?.mode!=='transactional'||packet.chapter_target?.target_id!==target.target_id) throw new Error(JSON.stringify(packet));
if(packet.changed_files.length!==0||packet.result_write_set.length!==0) throw new Error(JSON.stringify({reason:'idempotent adoption declared a canonical rewrite',changed_files:packet.changed_files,result_write_set:packet.result_write_set}));
after.current_stage='milestone_review';after.current_step='milestone_review';after.active_chapter_target=null;after.stage_execution={status:'running',stage_id:'milestone_review',step_id:'milestone_review',stage_attempt_id:'sa-wrong-milestone',work_unit_id:'wu-wrong-milestone',expected_result_packet:`${after.task_dir}/result-packets/milestone_review.result.json`};fs.rmSync(path.join(root,after.stage_execution.expected_result_packet),{force:true});fs.writeFileSync(taskFile,JSON.stringify(after,null,2)+'\n');
const repaired=cp.spawnSync(process.execPath,[state,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:deterministic-commit','--json'],{encoding:'utf8'});if(repaired.status!==0)throw new Error(repaired.stdout||repaired.stderr);const repairedOut=JSON.parse(repaired.stdout),repairedTask=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(repairedOut.skipped_long_chapter_loop_repaired!==true||repairedTask.current_stage!=='chapter_brief'||repairedTask.active_chapter_target?.target_id!==nextTarget.target_id)throw new Error(JSON.stringify({repairedOut,repairedTask}));
NODE
}

@test "long chapter machine gate reads the frozen candidate path instead of a guessed chapter file" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),cp=require('child_process');
const repo=process.argv[2],root=process.argv[3],state=path.join(repo,'scripts/workflow-state-machine.js'),gate=path.join(repo,'scripts/long-chapter-machine-gate.js');
const created=cp.spawnSync(process.execPath,[state,'create','--workflow-type','long_write','--project-root',root,'--scope','全书第27章','--user-goal','验收当前章','--json'],{encoding:'utf8'});
if(created.status!==0) throw new Error(created.stdout||created.stderr);const task=JSON.parse(created.stdout).task,taskFile=path.join(root,task.task_dir,'task.json');
const outlinePath='大纲/第2卷/细纲_第002章.md',outline='第二章细纲';fs.writeFileSync(path.join(root,outlinePath),outline);
const target=require(path.join(repo,'scripts/lib/long-chapter-target.js')).buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(outline).digest('hex'),workflowId:task.workflow_id}).target;
fs.writeFileSync(path.join(root,target.contract_path),'- 合法区间：2880—3840');fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});fs.writeFileSync(path.join(root,target.candidate_draft_path),'汉'.repeat(3000));
task.current_stage='prose_acceptance';task.current_step='prose_acceptance';task.active_chapter_target=target;task.stage_execution={status:'running',stage_id:'prose_acceptance',step_id:'prose_acceptance',chapter_target:target};fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const checked=cp.spawnSync(process.execPath,[gate,'--project-root',root,'--workflow-id',task.workflow_id,'--json'],{encoding:'utf8'});if(checked.status!==0) throw new Error(checked.stdout||checked.stderr);
const out=JSON.parse(checked.stdout);if(out.status==='blocked_long_draft_missing'||out.draft!==target.candidate_draft_path) throw new Error(checked.stdout);
NODE
}

@test "blocking long chapter machine gate returns to prose instead of authorizing edits in read-only acceptance" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),cp=require('child_process');
const repo=process.argv[2],root=process.argv[3],state=path.join(repo,'scripts/workflow-state-machine.js'),gate=path.join(repo,'scripts/long-chapter-machine-gate.js');
const created=cp.spawnSync(process.execPath,[state,'create','--workflow-type','long_write','--project-root',root,'--scope','全书第27章','--user-goal','验收当前章','--json'],{encoding:'utf8'});
if(created.status!==0) throw new Error(created.stdout||created.stderr);
const task=JSON.parse(created.stdout).task,taskFile=path.join(root,task.task_dir,'task.json');
const outlinePath='大纲/第2卷/细纲_第002章.md',outline='第二章细纲';fs.writeFileSync(path.join(root,outlinePath),outline);
const target=require(path.join(repo,'scripts/lib/long-chapter-target.js')).buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(outline).digest('hex'),workflowId:task.workflow_id}).target;
fs.writeFileSync(path.join(root,target.contract_path),'- 目标字数：3200\n- 合法区间：2880—3840');
fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});
const candidate=`${'汉'.repeat(316)}\n\n"对白"${'汉'.repeat(2682)}`;fs.writeFileSync(path.join(root,target.candidate_draft_path),candidate);
fs.writeFileSync(path.join(root,target.draft_path),'正式稿不应改动');
const template=JSON.parse(cp.spawnSync(process.execPath,[state,'templates','--json'],{encoding:'utf8'}).stdout).templates.find(item=>item.workflow_type==='long_write');
const ids=template.stages.map(item=>item.stage_id),acceptanceIndex=ids.indexOf('prose_acceptance'),completed=ids.slice(0,acceptanceIndex),reviewResults={};
for(const stage of template.stages)if(completed.includes(stage.stage_id)&&stage.review_requirement.required)reviewResults[stage.stage_id]={status:'accepted',verification_result:'pass',result_packet_path:'fixture://accepted'};
task.current_stage='prose_acceptance';task.current_step='prose_acceptance';task.status='running';task.active_chapter_target=target;task.accepted_detail_outline_targets=[target];task.consumed_detail_outline_targets=[];
task.machine={...(task.machine||{}),completed_stages:completed,remaining_stages:ids.slice(acceptanceIndex),allowed_actions:['continue_next_stage','pause']};
task.lifecycle_graph={version:'1.0.0',current_node:'prose_acceptance',asset_target:{kind:'chapter',id:'current-chapter'},completed_nodes:completed,invalidated_nodes:[],review_results:reviewResults,last_transition_validation:null,nodes:template.stages.map((stage,index)=>({id:stage.stage_id,order:index,owner_module:stage.owner_module,asset_target:stage.asset_target,review_requirement:stage.review_requirement,status:index<acceptanceIndex?'accepted':'missing'}))};
task.stage_execution={status:'running',stage_attempt_id:'sa-machine-block',work_unit_id:'wu-machine-block',stage_id:'prose_acceptance',step_id:'prose_acceptance',expected_result_packet:`${task.task_dir}/result-packets/prose_acceptance.result.json`,owner_module:'story-review',lifecycle_node:'prose_acceptance',asset_target:{kind:'chapter',id:'current-chapter'},review_requirement:{required:true,failure_return:'prose'},chapter_target:target,write_set:[],memory_contract_version:0};
const excluded=[task.task_dir,'追踪/context-pack','追踪/workflow/.workflow.lock','追踪/workflow/current-task.json','追踪/workflow/current-task.md','追踪/workflow/history.jsonl','追踪/workflow/families','追踪/workflow/sessions','追踪/workflow/task-family-index.json'];
const files={};function visit(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const abs=path.join(dir,entry.name),rel=path.relative(root,abs).split(path.sep).join('/');if(rel==='.git'||rel.startsWith('.git/')||excluded.some(item=>rel===item||rel.startsWith(`${item}/`)))continue;if(entry.isDirectory())visit(abs);else if(entry.isFile())files[rel]=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(abs)).digest('hex')}`;}}
visit(root);task.stage_execution.write_snapshot={version:1,captured_at:new Date().toISOString(),authorized_write_set:[],excluded_paths:excluded,files};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const checked=cp.spawnSync(process.execPath,[gate,'--project-root',root,'--workflow-id',task.workflow_id,'--apply','--json'],{encoding:'utf8'});
if(checked.status!==0) throw new Error(checked.stdout||checked.stderr);const out=JSON.parse(checked.stdout),after=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(out.status!=='repair_started'||after.current_stage!=='prose'||after.stage_execution?.stage_id!=='prose') throw new Error(JSON.stringify({out,after}));
if(JSON.stringify(after.stage_execution.write_set)!==JSON.stringify([target.candidate_draft_path])) throw new Error(JSON.stringify(after.stage_execution));
if(!String(after.stage_execution.resume_hint||'').includes('半角直引号')) throw new Error(JSON.stringify(after.stage_execution));
if(fs.readFileSync(path.join(root,target.candidate_draft_path),'utf8')!==candidate) throw new Error('machine gate rewrote candidate prose');
if(fs.readFileSync(path.join(root,target.draft_path),'utf8')!=='正式稿不应改动') throw new Error('machine gate touched canonical prose');
const packet=JSON.parse(fs.readFileSync(path.join(root,task.task_dir,'result-packets/prose_acceptance.result.json'),'utf8'));
if(packet.verification_result!=='rejected'||packet.next_stage_id!=='prose'||packet.lifecycle_transition_request?.target!=='prose') throw new Error(JSON.stringify(packet));
if(packet.stage_attempt_id!=='sa-machine-block'||packet.work_unit_id!=='wu-machine-block') throw new Error(JSON.stringify(packet));
NODE
}

@test "long chapter story quality routes planning drift to Brief and prose-only findings to prose" {
  node - "$REPO" "$TMP_DIR" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),cp=require('child_process');
const repo=process.argv[2],tmp=process.argv[3],state=path.join(repo,'scripts/workflow-state-machine.js'),gate=path.join(repo,'scripts/long-chapter-quality-gate.js');
const source=path.join(tmp,'book');

function fixture(name,failed,expectedStage){
  const root=path.join(tmp,name);fs.cpSync(source,root,{recursive:true});
  const created=cp.spawnSync(process.execPath,[state,'create','--workflow-type','long_write','--project-root',root,'--scope','第2卷第27章','--user-goal','验收当前章','--json'],{encoding:'utf8'});
  if(created.status!==0) throw new Error(created.stdout||created.stderr);
  const task=JSON.parse(created.stdout).task,taskFile=path.join(root,task.task_dir,'task.json');
  const outlinePath='大纲/第2卷/细纲_第002章.md',outline='# 第二章细纲\n必须完成公开裁决，不得提前突破。';fs.writeFileSync(path.join(root,outlinePath),outline);
  const target=require(path.join(repo,'scripts/lib/long-chapter-target.js')).buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(outline).digest('hex'),workflowId:task.workflow_id}).target;
  fs.writeFileSync(path.join(root,target.contract_path),'# 当前 Brief\n旧 Brief 错误地安排提前突破。');
  fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});
  const candidate='候选正文不得被质量审查改写。';fs.writeFileSync(path.join(root,target.candidate_draft_path),candidate);
  const canonical='正式正文不得被质量审查覆盖。';fs.writeFileSync(path.join(root,target.draft_path),canonical);
  const template=JSON.parse(cp.spawnSync(process.execPath,[state,'templates','--no-private-registry','--json'],{encoding:'utf8'}).stdout).templates.find(item=>item.workflow_type==='long_write');
  const ids=template.stages.map(item=>item.stage_id),index=ids.indexOf('prose_acceptance'),completed=ids.slice(0,index),reviewResults={};
  for(const stage of template.stages)if(completed.includes(stage.stage_id)&&stage.review_requirement.required)reviewResults[stage.stage_id]={status:'accepted',verification_result:'pass',result_packet_path:'fixture://accepted'};
  task.current_stage='prose_acceptance';task.current_step='prose_acceptance';task.status='running';task.active_chapter_target=target;task.accepted_detail_outline_targets=[target];task.consumed_detail_outline_targets=[];
  task.machine={...(task.machine||{}),completed_stages:completed,remaining_stages:ids.slice(index),allowed_actions:['continue_next_stage','pause']};
  task.lifecycle_graph={version:'1.0.0',current_node:'prose_acceptance',asset_target:{kind:'chapter',id:'current-chapter'},completed_nodes:completed,invalidated_nodes:[],review_results:reviewResults,last_transition_validation:null,nodes:template.stages.map((stage,order)=>({id:stage.stage_id,order,owner_module:stage.owner_module,asset_target:stage.asset_target,review_requirement:stage.review_requirement,status:order<index?'accepted':'missing'}))};
  task.stage_execution={status:'running',stage_attempt_id:`sa-${name}`,work_unit_id:`wu-${name}`,stage_id:'prose_acceptance',step_id:'prose_acceptance',expected_result_packet:`${task.task_dir}/result-packets/prose_acceptance.result.json`,owner_module:'story-review',lifecycle_node:'prose_acceptance',asset_target:{kind:'chapter',id:'current-chapter'},review_requirement:{required:true,failure_return:'prose'},chapter_target:target,write_set:[],memory_contract_version:0};
  const machineRel=`${task.task_dir}/artifacts/chapter-002-machine-gate.json`;fs.mkdirSync(path.dirname(path.join(root,machineRel)),{recursive:true});fs.writeFileSync(path.join(root,machineRel),JSON.stringify({status:'pass',blocking_count:0}));
  const excluded=[task.task_dir,'追踪/context-pack','追踪/workflow/.workflow.lock','追踪/workflow/current-task.json','追踪/workflow/current-task.md','追踪/workflow/history.jsonl','追踪/workflow/families','追踪/workflow/sessions','追踪/workflow/task-family-index.json'];
  const files={};function visit(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const abs=path.join(dir,entry.name),rel=path.relative(root,abs).split(path.sep).join('/');if(rel==='.git'||rel.startsWith('.git/')||excluded.some(item=>rel===item||rel.startsWith(`${item}/`)))continue;if(entry.isDirectory())visit(abs);else if(entry.isFile())files[rel]=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(abs)).digest('hex')}`;}}visit(root);
  task.stage_execution.write_snapshot={version:1,captured_at:new Date().toISOString(),authorized_write_set:[],excluded_paths:excluded,files};
  fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
  const run=cp.spawnSync(process.execPath,[gate,'--project-root',root,'--workflow-id',task.workflow_id,'--decision','revise','--failed',failed,'--summary','细纲要求公开裁决，正文却提前突破。','--apply','--json'],{encoding:'utf8'});
  if(run.status!==0) throw new Error(run.stdout||run.stderr);const out=JSON.parse(run.stdout),after=JSON.parse(fs.readFileSync(taskFile,'utf8'));
  if(out.status!=='applied'||after.current_stage!==expectedStage) throw new Error(JSON.stringify({out,stage:after.current_stage}));
  if(fs.readFileSync(path.join(root,target.candidate_draft_path),'utf8')!==candidate||fs.readFileSync(path.join(root,target.draft_path),'utf8')!==canonical) throw new Error('quality review modified story files');
  const packet=JSON.parse(fs.readFileSync(path.join(root,task.stage_execution.expected_result_packet),'utf8'));
  if(packet.chapter_target?.target_id!==target.target_id||packet.next_stage_id!==expectedStage||packet.lifecycle_transition_request?.target!==expectedStage) throw new Error(JSON.stringify(packet));
  if(packet.changed_files.length!==0||packet.result_write_set.length!==0) throw new Error(JSON.stringify({changed_files:packet.changed_files,result_write_set:packet.result_write_set}));
  if(expectedStage==='chapter_brief'){
    for(const stageId of ['chapter_brief','brief_review','prose','prose_acceptance','chapter_commit']) if(!after.lifecycle_graph.invalidated_nodes.includes(stageId)) throw new Error(JSON.stringify(after.lifecycle_graph));
    if(after.stage_execution||!after.pending_action) throw new Error(JSON.stringify({stage_execution:after.stage_execution,pending_action:after.pending_action}));
    const confirmed=cp.spawnSync(process.execPath,[state,'resolve-action','--project-root',root,'--input','1','--bind-current','--json'],{encoding:'utf8'});
    if(confirmed.status!==0) throw new Error(confirmed.stdout||confirmed.stderr);
    const resumed=JSON.parse(fs.readFileSync(taskFile,'utf8'));
    if(resumed.current_stage!=='chapter_brief'||resumed.stage_execution?.stage_id!=='chapter_brief'||resumed.stage_execution?.chapter_target?.target_id!==target.target_id) throw new Error(JSON.stringify(resumed));
    const packetContext=require(path.join(repo,'scripts/lib/long-stage-context-packet.js')).buildLongStageContextPacket({projectRoot:root,task:resumed,stage:'chapter_brief'});
    if(packetContext.status!=='assembled') throw new Error(JSON.stringify(packetContext));
    const markdown=fs.readFileSync(path.join(root,packetContext.packet_md),'utf8');
    if(!markdown.includes('正文与冻结细纲或当前 Brief 不一致')||!markdown.includes('正文出现规划外剧情漂移')) throw new Error(markdown);
  }
}

fixture('upstream-drift','brief_alignment,drift_control','chapter_brief');
fixture('prose-repair','story_attraction','prose');
NODE
}

@test "runtime reconcile archives stale prose receipts and restarts the exact chapter at prose" {
  node - "$REPO" "$PROJECT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),cp=require('child_process');
const repo=process.argv[2],root=process.argv[3],script=path.join(repo,'scripts/workflow-state-machine.js');
const created=cp.spawnSync(process.execPath,[script,'create','--workflow-type','long_write','--project-root',root,'--scope','第2卷第2章','--user-goal','继续当前章','--json'],{encoding:'utf8'});
if(created.status!==0) throw new Error(created.stdout||created.stderr);
const task=JSON.parse(created.stdout).task,taskFile=path.join(root,task.task_dir,'task.json');
const outlinePath='大纲/第2卷/细纲_第002章.md',outline='第二章细纲';fs.writeFileSync(path.join(root,outlinePath),outline);
const api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(outline).digest('hex'),workflowId:task.workflow_id}).target;
fs.writeFileSync(path.join(root,target.contract_path),'- 目标字数：3200\n- 合法区间：2880—3840');
fs.mkdirSync(path.dirname(path.join(root,target.candidate_draft_path)),{recursive:true});fs.writeFileSync(path.join(root,target.candidate_draft_path),'汉'.repeat(3000));
fs.writeFileSync(path.join(root,target.draft_path),'正式旧稿');
const templates=JSON.parse(cp.spawnSync(process.execPath,[script,'templates','--json'],{encoding:'utf8'}).stdout).templates;
const tpl=templates.find(item=>item.workflow_type==='long_write'),ids=tpl.stages.map(item=>item.stage_id),commitIndex=ids.indexOf('chapter_commit');
task.current_stage='chapter_commit';task.current_step='chapter_commit';task.status='running';task.active_chapter_target=target;task.accepted_detail_outline_targets=[target];task.consumed_detail_outline_targets=[];
task.stage_attempt_history=[];
task.machine={...(task.machine||{}),completed_stages:ids.slice(0,commitIndex),remaining_stages:ids.slice(commitIndex),allowed_actions:['continue_next_stage','pause']};
task.lifecycle_graph={version:'1.0.0',current_node:'chapter_commit',asset_target:{kind:'chapter',id:'current-chapter'},completed_nodes:ids.slice(0,commitIndex),invalidated_nodes:ids.slice(commitIndex),review_results:{},last_transition_validation:null,nodes:tpl.stages.map((stage,index)=>({...stage,status:index<commitIndex?'accepted':'invalidated'}))};
const packetDir=path.join(root,task.task_dir,'result-packets');fs.mkdirSync(packetDir,{recursive:true});
for(const stage of ['prose','prose_acceptance']) {
  const rel=`${task.task_dir}/result-packets/${stage}.result.json`;
  fs.writeFileSync(path.join(root,rel),JSON.stringify({workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:stage,step_id:stage,step_status:'completed',verification_result:'pass',chapter_target:target},null,2));
  task.stage_attempt_history.push({stage_attempt_id:`legacy-${stage}`,work_unit_id:`wu-${stage}`,stage_id:stage,status:'completed',expected_result_packet:rel,accepted_result_packet:rel,result_packet:rel});
}
task.runtime_guard={...(task.runtime_guard||{}),heartbeat:{...((task.runtime_guard||{}).heartbeat||{}),latest_trusted_artifact:`${task.task_dir}/result-packets/prose_acceptance.result.json`}};
task.stage_execution={status:'running',stage_attempt_id:'legacy-commit',work_unit_id:'wu-commit',stage_id:'chapter_commit',step_id:'chapter_commit',expected_result_packet:`${task.task_dir}/result-packets/chapter_commit.result.json`,chapter_target:target,write_set:[target.draft_path]};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const preview=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:stale-prose','--json'],{encoding:'utf8'});
if(preview.status!==0) throw new Error(preview.stdout||preview.stderr);const previewOut=JSON.parse(preview.stdout);
if(previewOut.status!=='longform_chapter_prose_revalidation_confirmation_required'||previewOut.resume_stage!=='prose') throw new Error(preview.stdout);
const applied=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:stale-prose','--confirm','--json'],{encoding:'utf8'});
if(applied.status!==0) throw new Error(applied.stdout||applied.stderr);const out=JSON.parse(applied.stdout),next=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(out.status!=='longform_chapter_prose_revalidation_applied'||next.current_stage!=='prose'||next.stage_execution?.status!=='running') throw new Error(applied.stdout);
if(next.machine.completed_stages.includes('prose')||next.machine.remaining_stages[0]!=='prose') throw new Error(JSON.stringify(next.machine));
if(next.runtime_guard?.heartbeat?.latest_trusted_artifact!==target.contract_path) throw new Error(JSON.stringify(next.runtime_guard?.heartbeat));
const confirmation=require(path.join(repo,'scripts/lib/workflow-confirmation-context.js')).validateWorkflowConfirmation(next,next.stage_execution);
if(!confirmation.valid) throw new Error(JSON.stringify({confirmation,selection:next.last_selection,execution:next.stage_execution}));
if(fs.readFileSync(path.join(root,target.draft_path),'utf8')!=='正式旧稿'||fs.readFileSync(path.join(root,target.candidate_draft_path),'utf8').length!==3000) throw new Error('creative assets changed');
for(const stage of ['prose','prose_acceptance']) if(fs.existsSync(path.join(packetDir,`${stage}.result.json`))) throw new Error(`${stage} packet not archived`);
const manifest=JSON.parse(fs.readFileSync(path.join(root,next.longform_chapter_prose_revalidation.archive_manifest_path),'utf8'));
if(manifest.entries.length!==2||manifest.entries.some(item=>!fs.existsSync(path.join(root,item.archive_path)))) throw new Error(JSON.stringify(manifest));
next.runtime_guard.heartbeat.latest_trusted_artifact=`${next.task_dir}/result-packets/prose_acceptance.result.json`;
next.pending_action=null;next.last_selection={};next.stage_execution.confirmation_token='';next.stage_execution.confirmation_context=null;
fs.writeFileSync(taskFile,JSON.stringify(next,null,2)+'\n');
const repaired=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:stale-prose','--json'],{encoding:'utf8'});
if(repaired.status!==0) throw new Error(repaired.stdout||repaired.stderr);
const repairedTask=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(repairedTask.runtime_guard?.heartbeat?.latest_trusted_artifact!==target.contract_path) throw new Error(repaired.stdout);
const repairedConfirmation=require(path.join(repo,'scripts/lib/workflow-confirmation-context.js')).validateWorkflowConfirmation(repairedTask,repairedTask.stage_execution);
if(!repairedConfirmation.valid) throw new Error(JSON.stringify(repairedConfirmation));
NODE
}

@test "runner refuses every long chapter stage without a complete frozen target" {
  node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const task={workflow_id:'wf-no-target',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-no-target',scope:'第34章',user_goal:'继续第34章',lifecycle_graph:{nodes:[]}};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
for(const stage of ['chapter_brief','brief_review','prose','prose_acceptance','chapter_commit']) {
  const execution={stage_id:stage,step_id:stage,expected_result_packet:`追踪/workflow/tasks/wf-no-target/result-packets/${stage}.result.json`};
  const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
  const contract=run.runnerPacket.stage_contract;
  if(contract.chapter_target_missing!==true||contract.chapter_target!==null||!contract.chapter_target_blocking_reason) throw new Error(`${stage}: ${JSON.stringify(contract)}`);
}
NODE
}

@test "runner refuses a valid frozen target that drifts from the durable active target" {
  cat >> "$PROJECT/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第028章","chapterNo":28,"volume":"第2卷","volumeChapterNo":3,"globalDraftOrder":28,"outlinePath":"大纲/第2卷/细纲_第003章.md","draftPath":"正文/第2卷/第003章.md","contractPath":"追踪/章节契约/第2卷/第003章.md"}
EOF
  node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
function build(outlinePath,content) {
  const file=path.join(root,outlinePath);fs.writeFileSync(file,content);
  return api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(content).digest('hex'),workflowId:'wf-drift'}).target;
}
const active=build('大纲/第2卷/细纲_第002章.md','第二章细纲');
const frozen=build('大纲/第2卷/细纲_第003章.md','第三章细纲');
const task={workflow_id:'wf-drift',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-drift',active_chapter_target:active,lifecycle_graph:{nodes:[]}};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
for(const stage of ['chapter_brief','brief_review','prose','prose_acceptance','chapter_commit']) {
  const execution={stage_id:stage,step_id:stage,expected_result_packet:`追踪/workflow/tasks/wf-drift/result-packets/${stage}.result.json`,chapter_target:frozen,chapter_targets:stage==='chapter_brief'?[frozen]:[]};
  const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
  const contract=run.runnerPacket.stage_contract;
  if(contract.chapter_target_missing!==true||contract.chapter_target!==null||!contract.chapter_target_blocking_reason.includes('active_chapter_target')) throw new Error(`${stage}: ${JSON.stringify(contract)}`);
  if(stage==='prose'&&!run.runnerPacket.requirements.some((item)=>item.includes('正文机器检查统一由 prose_acceptance 阶段执行'))) throw new Error(JSON.stringify(run.runnerPacket.requirements));
}
NODE
}

@test "managed runner preserves a blocking long context packet and stops before host spawn" {
  node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const api=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const {buildRunPreview,runHost}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',content='第二章细纲',outlineFile=path.join(root,outlinePath);
fs.writeFileSync(outlineFile,content);
const target=api.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256:crypto.createHash('sha256').update(content).digest('hex'),workflowId:'wf-context-block'}).target;
const task={workflow_id:'wf-context-block',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-context-block',active_chapter_target:target,lifecycle_graph:{nodes:[]}};
const execution={stage_id:'prose_acceptance',step_id:'prose_acceptance',expected_result_packet:'追踪/workflow/tasks/wf-context-block/result-packets/prose_acceptance.result.json',chapter_target:target};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
const blockedPacket={status:'blocked_long_chapter_candidate_missing',blocking:true,reason:'candidate missing'};
const options={adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'};
const run=buildRunPreview(root,task,execution,options,0,memory,blockedPacket);
(async()=>{
  const result=await runHost(root,task,execution,run,options);
  if(result.status!==blockedPacket.status||result.host_started!==false) throw new Error(JSON.stringify(result));
  const marker=process.env.NOVEL_ASSISTANT_FAKE_HOST_LOG;
  if(marker&&fs.existsSync(marker)) throw new Error('fake host was started');
  const outside=path.join(root,'..','outside-write');fs.mkdirSync(outside,{recursive:true});
  const candidateParent=path.dirname(path.join(root,target.candidate_draft_path));
  fs.mkdirSync(path.dirname(candidateParent),{recursive:true});fs.symlinkSync(outside,candidateParent);
  const proseExecution={...execution,stage_id:'prose',step_id:'prose',chapter_target:target,write_set:[target.candidate_draft_path]};
  const unsafeRun=buildRunPreview(root,task,proseExecution,options,0,memory,null);
  const unsafe=await runHost(root,task,proseExecution,unsafeRun,options);
  if(unsafe.status!=='blocked_long_chapter_write_path_unsafe'||unsafe.host_started!==false) throw new Error(JSON.stringify(unsafe));
})().catch((error)=>{console.error(error);process.exit(1);});
NODE
}
