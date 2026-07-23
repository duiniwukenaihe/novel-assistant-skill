#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/book"
  mkdir -p "$BOOK/追踪/private-short-extension" "$BOOK/追踪/memory" "$BOOK/追踪/schema" "$BOOK/追踪/workflow"
  printf '%s\n' '{"project_id":"project-fruit","project_title":"果汁事件"}' > "$BOOK/追踪/private-short-extension/project-state.json"
  printf '%s\n' '{"fact_id":"fact-1","subject":"林照","predicate":"第1节状态","object":"决定查账","scope":{"section":1},"status":"active"}' > "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"promise_id":"promise-1","summary":"第二节核对签名","source_section":1,"target_section":2,"status":"active"}' > "$BOOK/追踪/schema/promises.jsonl"
  printf '%s\n' '{"rule_id":"rule-1","content":"使用第一人称","status":"confirmed","scope":"short_write"}' > "$BOOK/追踪/schema/user-style-rules.jsonl"
  printf '%s\n' '{"rule_id":"pollution-1","content":"禁止领域词循环填充","status":"active"}' > "$BOOK/追踪/schema/output-pollution-rules.jsonl"
  printf '%s\n' '{"learning_id":"learning-1","content":"素材仅供私有选题阶段使用","status":"active"}' > "$BOOK/追踪/private-short-extension/learning-ledger.jsonl"
}

@test "local storage backend keeps logical project identity independent from absolute path" {
  run node - "$REPO/scripts/lib/local-storage-backend.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const {LocalStorageBackend}=require(process.argv[2]);
const root=process.argv[3];
const backend=new LocalStorageBackend(root);
const first=backend.ensureProjectIdentity({write:true});
if(first.project_id!=='project-fruit'||!first.project_instance_id) throw new Error(JSON.stringify(first));
const file=path.join(root,'追踪/storage/project-identity.json');
const stored=JSON.parse(fs.readFileSync(file,'utf8'));
if('project_root' in stored||JSON.stringify(stored).includes(root)) throw new Error('identity leaked absolute project path');
const second=new LocalStorageBackend(root).ensureProjectIdentity();
if(second.project_instance_id!==first.project_instance_id) throw new Error('instance identity is not stable');
NODE
  [ "$status" -eq 0 ]
}

@test "read-only identity lookup never invents a random project instance" {
  run node - "$REPO/scripts/lib/local-storage-backend.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const {LocalStorageBackend}=require(process.argv[2]);
const root=process.argv[3];
const backend=new LocalStorageBackend(root);
const first=backend.projectIdentity();
const second=backend.projectIdentity();
if(first.status!=='uninitialized'||first.project_id!=='project-fruit'||first.project_instance_id!=='') throw new Error(JSON.stringify(first));
if(JSON.stringify(first)!==JSON.stringify(second)) throw new Error('read-only identity changed between calls');
if(fs.existsSync(path.join(root,'追踪/storage/project-identity.json'))) throw new Error('read-only lookup wrote identity');
NODE
  [ "$status" -eq 0 ]
}

@test "story memory repository exposes typed local records and revisions" {
  run node - "$REPO/scripts/lib/story-memory-repository.js" "$BOOK" <<'NODE'
const {StoryMemoryRepository}=require(process.argv[2]);
const repo=new StoryMemoryRepository(process.argv[3]);
if(repo.projectState().project_id!=='project-fruit') throw new Error('missing project');
if(repo.acceptedFacts().length!==1||repo.promises().length!==1||repo.styleRules().length!==1||repo.pollutionRules().length!==1||repo.domainLearning().length!==1) throw new Error('missing typed records');
const revisions=repo.sourceRevisions();
if(!String(revisions['追踪/memory/facts.jsonl']||'').startsWith('sha256:')) throw new Error(JSON.stringify(revisions));
if(revisions['追踪/private-short-extension/learning-ledger.jsonl']) throw new Error('domain learning must not invalidate story snapshot');
if(!repo.allSourceRevisions()['追踪/private-short-extension/learning-ledger.jsonl']) throw new Error('control plane cannot inspect learning revision');
NODE
  [ "$status" -eq 0 ]
}

@test "memory contract binds query snapshot and read receipt without exposing backend details" {
  run node - "$REPO/scripts/lib/memory-query-contract.js" <<'NODE'
const api=require(process.argv[2]);
const query=api.normalizeMemoryQuery({project_id:'project-fruit',project_instance_id:'instance-1',workflow_id:'wf-1',stage_id:'draft_section',scope:{section_index:2},needs:['accepted_facts','active_promises']});
const contract=api.createMemoryContract({query,provider:'story-memory',memoryRevision:'sha256:abc',packetPath:'追踪/memory-packets/p.json',packetDigest:'sha256:def',tokenBudget:500,usedTokens:120,selectedEntryIds:['fact-1'],omittedCount:3});
const receipt=api.createMemoryReadReceipt(contract);
const checked=api.validateMemoryReadReceipt(contract,receipt);
if(checked.status!=='current'||contract.backend) throw new Error(JSON.stringify({contract,checked}));
const stale=api.validateMemoryReadReceipt(contract,{...receipt,memory_revision:'sha256:other'});
if(stale.status!=='stale') throw new Error(JSON.stringify(stale));
NODE
  [ "$status" -eq 0 ]
}

@test "workflow control summary reads tasks and global preferences directly but exposes only story memory counts" {
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-short"
  printf '%s\n' '{"workflow_id":"wf-short","workflow_type":"short_write","current_stage":"draft_section","status":"running","updated_at":"2026-07-22T10:00:00Z"}' > "$BOOK/追踪/workflow/tasks/wf-short/task.json"
  printf '%s\n' '{"workflow_id":"wf-short"}' > "$BOOK/追踪/workflow/current-task.json"
  printf '%s\n' '{"entryId":"pref-menu","category":"interaction","content":"首屏使用数字菜单","status":"accepted"}' > "$BOOK/追踪/workflow/preference-memory.jsonl"
  run node "$REPO/scripts/workflow-control-summary.js" --project-root "$BOOK" --write-identity --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s' "$output" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s);if(x.task_store.unfinished_count!==1||x.task_store.focused_workflow_id!=="wf-short")throw new Error(s);if(x.user_profile.preference_count!==1||x.story_memory.active_facts!==1)throw new Error(s);if(JSON.stringify(x.story_memory).includes("决定查账"))throw new Error("control summary leaked story facts");});'
}

@test "artifact repository uses project-relative identity and deterministic review cache keys" {
  mkdir -p "$BOOK/正文"
  printf '%s\n' '候选正文' > "$BOOK/正文/第001节.md"
  run node - "$REPO/scripts/lib/artifact-repository.js" "$BOOK" <<'NODE'
const {ArtifactRepository}=require(process.argv[2]);
const repo=new ArtifactRepository(process.argv[3]);
const artifact=repo.describe('正文/第001节.md',{artifactType:'short_section'});
if(!artifact.exists||artifact.relative_path!=='正文/第001节.md'||!artifact.content_digest.startsWith('sha256:')) throw new Error(JSON.stringify(artifact));
if(JSON.stringify(artifact).includes(process.argv[3])) throw new Error('artifact leaked absolute project path');
const input={sourceDigest:artifact.content_digest,planningDigest:'sha256:plan',memoryRevision:'sha256:memory',rubricVersion:'short-v2',detectorVersion:'ai-v3'};
const first=repo.reviewCacheKey(input);
const second=repo.reviewCacheKey(input);
if(first!==second||!first.startsWith('review-cache:')) throw new Error(JSON.stringify({first,second}));
const changed=repo.reviewCacheKey({...input,memoryRevision:'sha256:new'});
if(changed===first) throw new Error('memory revision did not invalidate review cache');
NODE
  [ "$status" -eq 0 ]
}
