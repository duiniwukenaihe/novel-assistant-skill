#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STORE="$REPO/scripts/lib/task-family-store.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/workflow"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "task family groups focus-switched workflow branches as one family" {
    node - "$STORE" "$BOOK" <<'NODE'
const fs=require('fs');
const [storeFile,root]=process.argv.slice(2);
const store=require(storeFile);
const first={workflow_id:'wf-review-a',workflow_type:'review_repair',status:'paused',scope:'1-200章 范围审阅',user_goal:'审阅 1-200 章节情节、钩子、人物、设定连续性与行文质量',lifecycle:{status:'paused',focus_switched_to:'wf-review-b'}};
const second={workflow_id:'wf-review-b',workflow_type:'review_repair',status:'running',scope:'1-200章 范围审阅',user_goal:'审阅 1-200 章节情节、钩子、人物、设定连续性与行文质量',lifecycle:{status:'active',focus_switched_from:'wf-review-a'}};
const a=store.ensureTaskFamily(root,first,{write:true});
const b=store.ensureTaskFamily(root,second,{write:true});
const families=store.listTaskFamilies(root);
if(a.family.task_family_id!==b.family.task_family_id) throw new Error(JSON.stringify({a,b}));
if(b.family.head_workflow_id!=='wf-review-b') throw new Error(JSON.stringify(b.family));
if(b.family.branches.length!==2 || families.unfinished_family_count!==1) throw new Error(JSON.stringify({family:b.family,families}));
if(!fs.existsSync(`${root}/追踪/workflow/task-family-index.json`)) throw new Error('family index missing');
NODE
}

@test "task family flags same workflow class and range without lineage as potential duplicate" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);
const store=require(storeFile);
const review={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章情节与钩子'};
const repair={workflow_id:'wf-repair',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'修复 1-200 章 AI 句式'};
store.ensureTaskFamily(root,review,{write:true});
const relationship=store.resolveTaskRelationship(root,repair);
if(relationship.kind!=='potential_duplicate') throw new Error(JSON.stringify(relationship));
const created=store.ensureTaskFamily(root,repair,{write:true});
const families=store.listTaskFamilies(root);
if(created.relationship.kind!=='potential_duplicate' || families.families.length!==2 || families.unfinished_family_count!==2) throw new Error(JSON.stringify({created,families}));
NODE
}

@test "task family preserves independent chapter writing and range review tasks" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);
const store=require(storeFile);
store.ensureTaskFamily(root,{workflow_id:'wf-write',workflow_type:'long_write',status:'running',scope:'第12卷第024章',user_goal:'继续写第 724 章'},{write:true});
store.ensureTaskFamily(root,{workflow_id:'wf-review',workflow_type:'review_repair',status:'paused',scope:'1-200章',user_goal:'审阅 1-200 章'},{write:true});
const families=store.listTaskFamilies(root);
if(families.families.length!==2 || families.unfinished_family_count!==2) throw new Error(JSON.stringify(families));
if(families.families.some(item=>item.branches.length!==1)) throw new Error(JSON.stringify(families));
NODE
}

@test "task family projects a completed head branch out of unfinished count" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const running={workflow_id:'wf-write',workflow_type:'long_write',status:'running',scope:'第1卷第001章',user_goal:'继续写第1章',lifecycle:{status:'active'}};
const first=store.ensureTaskFamily(root,running,{write:true});
const completed={...running,status:'completed',lifecycle:{status:'completed'}};
store.ensureTaskFamily(root,completed,{write:true});
const inventory=store.listTaskFamilies(root);
if(inventory.unfinished_family_count!==0||inventory.families[0].status!=='completed') throw new Error(JSON.stringify(inventory));
if(first.family.task_family_id!==inventory.families[0].task_family_id) throw new Error('family identity changed');
NODE
}

@test "reprojecting a paused head never promotes it back to active" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const task={workflow_id:'wf-short',workflow_type:'short_write',status:'paused',scope:'全篇',user_goal:'整篇回炉',lifecycle:{status:'paused'}};
const first=store.ensureTaskFamily(root,task,{write:true});
const second=store.ensureTaskFamily(root,task,{write:true});
if(first.family.status!=='paused'||second.family.status!=='paused') throw new Error(JSON.stringify({first:first.family,second:second.family}));
const head=second.family.branches.find(item=>item.workflow_id==='wf-short');
if(!head||head.status!=='paused') throw new Error(JSON.stringify(second.family));
NODE
}

@test "task family recognizes previous workflow lineage from older task records" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const oldTask={workflow_id:'wf-old',workflow_type:'review_repair',status:'paused',scope:'1-200章',user_goal:'审阅人物与钩子',lifecycle:{status:'paused'}};
const rebuilt={workflow_id:'wf-rebuilt',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'修复旧审阅状态并继续',lifecycle:{status:'active',previous_workflow_id:'wf-old'}};
const first=store.ensureTaskFamily(root,oldTask,{write:true});
const second=store.ensureTaskFamily(root,rebuilt,{write:true});
if(first.family.task_family_id!==second.family.task_family_id||second.family.head_workflow_id!=='wf-rebuilt') throw new Error(JSON.stringify({first,second}));
NODE
}

@test "private short startup alias stays in the canonical short write family" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const legacy={workflow_id:'wf-private-start',workflow_type:'private_short_startup',status:'paused',user_goal:'新开短篇',lifecycle:{status:'paused'}};
const canonical={workflow_id:'wf-short-write',workflow_type:'short_write',status:'running',user_goal:'新开短篇',lifecycle:{status:'active',previous_workflow_id:'wf-private-start'}};
const first=store.ensureTaskFamily(root,legacy,{write:true});
const second=store.ensureTaskFamily(root,canonical,{write:true});
if(first.family.task_family_id!==second.family.task_family_id) throw new Error(JSON.stringify({first,second}));
if(second.family.identity.workflow_class!=='short_write') throw new Error(JSON.stringify(second.family.identity));
if(second.family.branches.length!==2) throw new Error(JSON.stringify(second.family.branches));
NODE
}

@test "book identity remains stable when the deployed bundle changes" {
    printf '{"novel_assistant_bundle_id":"bundle-a"}\n' > "$BOOK/.story-deployed"
    first="$(node -e "console.log(require(process.argv[1]).bookId(process.argv[2]))" "$STORE" "$BOOK")"
    printf '{"novel_assistant_bundle_id":"bundle-b"}\n' > "$BOOK/.story-deployed"
    second="$(node -e "console.log(require(process.argv[1]).bookId(process.argv[2]))" "$STORE" "$BOOK")"
    [ "$first" = "$second" ]
}

@test "same review range with different objectives does not auto attach" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
store.ensureTaskFamily(root,{workflow_id:'wf-characters',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅人物发展'},{write:true});
const relationship=store.resolveTaskRelationship(root,{workflow_id:'wf-hooks',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅钩子回收'});
if(relationship.kind!=='potential_duplicate') throw new Error(JSON.stringify(relationship));
NODE
}

@test "previous workflow linkage cannot merge different workflow classes" {
    node - "$STORE" "$BOOK" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const writing=store.ensureTaskFamily(root,{workflow_id:'wf-write',workflow_type:'long_write',status:'running',scope:'第1卷第001章',user_goal:'写第1章'},{write:true});
const review={workflow_id:'wf-review',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章',lifecycle:{previous_workflow_id:'wf-write'}};
const relationship=store.resolveTaskRelationship(root,review);
if(relationship.kind==='same_family'&&relationship.family.task_family_id===writing.family.task_family_id) throw new Error(JSON.stringify(relationship));
NODE
}
