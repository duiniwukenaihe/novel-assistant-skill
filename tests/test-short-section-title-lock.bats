#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/short-section-title-lock.js"
  BOOK="$(mktemp -d)"
  mkdir -p "$BOOK/追踪/private-short-extension"
  cat > "$BOOK/小节大纲.md" <<'MD'
## 第1节：直播误切空车间
## 第2节
MD
}

create_short_task() {
  local workflow_id="$1"
  local stage="${2:-first_section_brief}"
  mkdir -p "$BOOK/追踪/workflow/tasks/$workflow_id" "$BOOK/追踪/workflow"
  cat > "$BOOK/追踪/workflow/tasks/$workflow_id/task.json" <<JSON
{"workflow_id":"$workflow_id","workflow_type":"short_write","task_dir":"追踪/workflow/tasks/$workflow_id","state_version":1,"current_stage":"$stage","scope":"第1节","stage_execution":{"stage_id":"$stage","stage_attempt_id":"sa-$workflow_id","status":"running"}}
JSON
}

teardown() {
  rm -rf "$BOOK"
}

@test "section title lock previews titles before confirmation and preserves untitled sections" {
  run node "$SCRIPT" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"awaiting_section_title_confirmation"'* ]]
  [[ "$output" == *'"section_index":2,"title":""'* ]]
  [ ! -f "$BOOK/追踪/private-short-extension/section-title-lock.json" ]

  digest="$(printf '%s' "$output" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).digest))')"
  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short" --digest "$digest" --confirm --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"status":"blocked_task_authority_missing"'* ]]

  create_short_task "wf-short"
  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short" --digest "$digest" --confirm --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"section_titles_confirmed_and_bound"'* ]]
  node - "$BOOK/追踪/private-short-extension/section-title-lock.json" <<'NODE'
const x=require(process.argv[2]);
if(x.workflow_id!=='wf-short' || x.sections[1].title!=='' || x.sections[1].confirmed!==true) throw new Error(JSON.stringify(x));
NODE
}

@test "section title confirmation binds the explicit workflow after focus switches" {
  create_short_task "wf-short-a"
  create_short_task "wf-short-b" "section_outline"
  cat > "$BOOK/追踪/workflow/current-task.json" <<'JSON'
{"workflow_id":"wf-short-b","task_dir":"追踪/workflow/tasks/wf-short-b","state_version":1}
JSON

  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short-a" --json
  [ "$status" -eq 0 ]
  digest="$(printf '%s' "$output" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).digest))')"
  [[ "$output" == *'--workflow-id \\"wf-short-a\\"'* ]]

  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short-a" --digest "$digest" --confirm --json
  [ "$status" -eq 0 ]
  node - "$BOOK" <<'NODE'
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const lock=JSON.parse(fs.readFileSync(path.join(root,'追踪/private-short-extension/section-title-lock.json'),'utf8'));
const a=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks/wf-short-a/task.json'),'utf8'));
const b=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks/wf-short-b/task.json'),'utf8'));
const focus=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
if(lock.workflow_id!=='wf-short-a') throw new Error(JSON.stringify(lock));
if(a.state_version<=1 || String((a.stage_execution||{}).stage_id||'')!=='first_section_brief') throw new Error(JSON.stringify(a));
if(b.state_version!==1 || focus.workflow_id!=='wf-short-b') throw new Error(JSON.stringify({b,focus}));
NODE
}

@test "section plan lock accepts semantic story functions and derives short publication shape" {
  create_short_task "wf-short" "section_plan_lock"
  cat > "$BOOK/小节大纲.md" <<'MD'
# 小节大纲

- 总小节数：2 节；目标总字数：3000-4000 字。

## 第1节：直播拍到空车间
- 承接与场景动作：主角在直播中切到空车间。
- 可见阻力与压力变化：哥哥要求她立刻按话术解释。
- 主角选择与兑现：她拒绝把责任推给导播。
- 关系后果、代价与钩子：家人停掉她的权限。
- 因果链：误切监控 → 话术施压 → 拒绝甩锅。

## 第2节：镜头里终于有了果子
- 承接与场景动作：企业召回旧货并恢复真实鲜榨线。
- 可见阻力与压力变化：停线后员工工资与渠道索赔同时压来。
- 主角选择与兑现：她推动独立品控和公开生产直播。
- 关系收束：哥哥停职，信任只能慢慢重建。
- 终局兑现：真实鲜果重新进入工厂，全篇在生产公开后完稿。
- 因果链：主动召回 → 承担停线代价 → 恢复鲜榨线。
MD

  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"awaiting_section_title_confirmation"'* ]]
  [[ "$output" != *'publication_shape_missing'* ]]
  [[ "$output" != *'section_function_missing'* ]]
  [[ "$output" == *'- 第 1 节：直播拍到空车间'* ]]
}
