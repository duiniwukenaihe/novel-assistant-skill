#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STORE="$REPO/scripts/lib/task-family-store.js"
    HEARTBEAT="$REPO/scripts/workflow-session-heartbeat.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/workflow"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "live remote heartbeat blocks another writer without takeover" {
    node - "$STORE" "$HEARTBEAT" "$BOOK" <<'NODE'
const [storeFile,heartbeatFile,root]=process.argv.slice(2);
const store=require(storeFile);
const heartbeat=require(heartbeatFile);
const task={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
heartbeat.recordSessionHeartbeat(root,{taskFamilyId:family.task_family_id,sessionId:'claude:remote-a',host:'remote-a',observedAt:'2026-07-12T00:00:00.000Z',expiresAt:'2026-07-12T00:10:00.000Z',capability:{host_execution_mode:'cooperative_interactive'}});
const first=store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:remote-a',host:'remote-a'},{write:true,now:'2026-07-12T00:01:00.000Z'});
const second=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:local-b',host:'local-b'},{write:true,now:'2026-07-12T00:02:00.000Z'});
if(first.status!=='claimed') throw new Error(JSON.stringify(first));
if(second.status!=='takeover_required'||second.role!=='observer'||!second.takeover_required) throw new Error(JSON.stringify(second));
if(second.writer_lease.holder_session_id!=='claude:remote-a'||second.writer_lease.state!=='active') throw new Error(JSON.stringify(second.writer_lease));
NODE
}

@test "expired remote heartbeat becomes awaiting claim instead of automatic writer takeover" {
    node - "$STORE" "$HEARTBEAT" "$BOOK" <<'NODE'
const [storeFile,heartbeatFile,root]=process.argv.slice(2);
const store=require(storeFile);
const heartbeat=require(heartbeatFile);
const task={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
heartbeat.recordSessionHeartbeat(root,{taskFamilyId:family.task_family_id,sessionId:'claude:remote-a',host:'remote-a',observedAt:'2026-07-12T00:00:00.000Z',expiresAt:'2026-07-12T00:05:00.000Z',capability:{host_execution_mode:'cooperative_interactive'}});
store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:remote-a',host:'remote-a'},{write:true,now:'2026-07-12T00:01:00.000Z'});
const result=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:local-b',host:'local-b'},{write:true,now:'2026-07-12T00:30:00.000Z'});
if(result.status!=='awaiting_claim'||result.role!=='observer'||result.takeover_required!==true) throw new Error(JSON.stringify(result));
if(result.writer_lease.holder_session_id!=='claude:remote-a'||result.writer_lease.state!=='awaiting_claim') throw new Error(JSON.stringify(result.writer_lease));
const stored=store.readTaskFamily(root,family.task_family_id);
if(stored.writer_lease.holder_session_id!=='claude:remote-a'||stored.writer_lease.state!=='awaiting_claim') throw new Error(JSON.stringify(stored.writer_lease));
NODE
}

@test "same restarted desktop session can refresh its own writer lease" {
    node - "$STORE" "$HEARTBEAT" "$BOOK" <<'NODE'
const [storeFile,heartbeatFile,root]=process.argv.slice(2);
const store=require(storeFile);
const heartbeat=require(heartbeatFile);
const task={workflow_id:'wf-write',workflow_type:'long_write',status:'running',scope:'第1卷第001章',user_goal:'写第1章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
heartbeat.recordSessionHeartbeat(root,{taskFamilyId:family.task_family_id,sessionId:'claude:desktop-main',host:'macbook',observedAt:'2026-07-12T00:00:00.000Z',expiresAt:'2026-07-12T00:05:00.000Z'});
store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:desktop-main',host:'macbook'},{write:true,now:'2026-07-12T00:01:00.000Z'});
heartbeat.recordSessionHeartbeat(root,{taskFamilyId:family.task_family_id,sessionId:'claude:desktop-main',host:'macbook',observedAt:'2026-07-12T00:40:00.000Z',expiresAt:'2026-07-12T00:45:00.000Z'});
const refreshed=store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:desktop-main',host:'macbook'},{write:true,now:'2026-07-12T00:41:00.000Z'});
if(refreshed.status!=='claimed'||refreshed.role!=='writer') throw new Error(JSON.stringify(refreshed));
if(refreshed.writer_lease.holder_session_id!=='claude:desktop-main'||refreshed.writer_lease.state!=='active') throw new Error(JSON.stringify(refreshed.writer_lease));
NODE
}

@test "confirmed takeover is required before a second session becomes writer" {
    node - "$STORE" "$HEARTBEAT" "$BOOK" <<'NODE'
const [storeFile,heartbeatFile,root]=process.argv.slice(2);
const store=require(storeFile);
const heartbeat=require(heartbeatFile);
const task={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
heartbeat.recordSessionHeartbeat(root,{taskFamilyId:family.task_family_id,sessionId:'claude:remote-a',host:'remote-a',observedAt:'2026-07-12T00:00:00.000Z',expiresAt:'2026-07-12T00:05:00.000Z'});
store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:remote-a',host:'remote-a'},{write:true,now:'2026-07-12T00:01:00.000Z'});
const blocked=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:local-b',host:'local-b'},{write:true,now:'2026-07-12T00:30:00.000Z'});
const taken=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:local-b',host:'local-b'},{write:true,now:'2026-07-12T00:31:00.000Z',takeover:true,confirmed:true});
if(blocked.status!=='awaiting_claim'||blocked.writer_lease.holder_session_id!=='claude:remote-a') throw new Error(JSON.stringify(blocked));
if(taken.status!=='taken_over'||taken.role!=='writer'||taken.writer_lease.holder_session_id!=='codex:local-b') throw new Error(JSON.stringify(taken));
if(!taken.writer_lease.takeover_history.length) throw new Error(JSON.stringify(taken.writer_lease));
NODE
}
