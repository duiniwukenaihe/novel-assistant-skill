#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STORE="$REPO/scripts/lib/task-family-store.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "three sessions attach to one family but only one receives writer role" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const task={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
const live=()=> 'running';
const a=store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:1',host:'claude'},{write:true,hostLiveness:live});
const b=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:2',host:'codex'},{write:true,hostLiveness:live});
const c=store.claimFamilyWriter(root,family.task_family_id,{session_id:'zcode:3',host:'zcode'},{write:true,hostLiveness:live});
const loaded=store.readTaskFamily(root,family.task_family_id);
if(a.status!=='claimed'||b.status!=='takeover_required'||c.status!=='takeover_required') throw new Error(JSON.stringify({a,b,c}));
if(loaded.writer_lease.holder_session_id!=='claude:1') throw new Error(JSON.stringify(loaded));
if(loaded.sessions.filter(s=>s.role==='observer').length!==2) throw new Error(JSON.stringify(loaded.sessions));
NODE
}

@test "suspended claude writer lease is reclaimed without killing the process" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const task={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:111',host:'claude'},{write:true,hostLiveness:()=> 'running'});
const reclaimed=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:222',host:'codex'},{write:true,hostLiveness:(session)=>session==='claude:111'?'suspended':'running'});
const loaded=store.readTaskFamily(root,family.task_family_id);
if(reclaimed.status!=='reclaimed_stale'||loaded.writer_lease.holder_session_id!=='codex:222') throw new Error(JSON.stringify({reclaimed,loaded}));
NODE
}

@test "healthy writer requires confirmed takeover" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const task={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:1',host:'claude'},{write:true,hostLiveness:()=> 'running'});
const blocked=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:2',host:'codex'},{write:true,hostLiveness:()=> 'running'});
const taken=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:2',host:'codex'},{write:true,takeover:true,confirmed:true,hostLiveness:()=> 'running'});
if(blocked.status!=='takeover_required'||taken.status!=='taken_over') throw new Error(JSON.stringify({blocked,taken}));
NODE
}

@test "expired lease with a live host still requires confirmed takeover" {
    node - "$STORE" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const task={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章'};
const family=store.ensureTaskFamily(root,task,{write:true}).family;
store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:111',host:'claude'},{write:true,hostLiveness:()=> 'running'});
const file=store.familyPath(root,family.task_family_id);const value=JSON.parse(fs.readFileSync(file,'utf8'));value.writer_lease.expires_at='2000-01-01T00:00:00.000Z';fs.writeFileSync(file,JSON.stringify(value));
const blocked=store.claimFamilyWriter(root,family.task_family_id,{session_id:'codex:222',host:'codex'},{write:true,hostLiveness:()=> 'running'});
if(blocked.status!=='takeover_required'||blocked.writer_lease.holder_session_id!=='claude:111') throw new Error(JSON.stringify(blocked));
NODE
}
