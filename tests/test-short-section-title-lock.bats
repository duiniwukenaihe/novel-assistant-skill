#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/short-section-title-lock.js"
  BOOK="$(mktemp -d)"
  mkdir -p "$BOOK/追踪/private-short-extension"
  cat > "$BOOK/小节大纲.md" <<'MD'
## 第1节：复核误切编号空缺
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
  [ ! -f "$BOOK/追踪/story-system/short/section-title-lock.json" ]

  digest="$(printf '%s' "$output" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).digest))')"
  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short" --digest "$digest" --confirm --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"status":"blocked_task_authority_missing"'* ]]

  create_short_task "wf-short"
  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short" --digest "$digest" --confirm --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"section_titles_confirmed_and_bound"'* ]]
  node - "$BOOK/追踪/story-system/short/section-title-lock.json" <<'NODE'
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
const lock=JSON.parse(fs.readFileSync(path.join(root,'追踪/story-system/short/section-title-lock.json'),'utf8'));
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

## 第1节：复核拍到编号空缺
- 承接与场景动作：主角在复核中发现凭证空缺。
- 可见阻力与压力变化：主管要求她立刻按话术解释。
- 主角选择与兑现：她拒绝把责任推给导播。
- 关系后果、代价与钩子：上级停掉她的权限。
- 因果链：误切凭证 → 话术施压 → 拒绝甩锅。

## 第2节：缺失凭证重新归档
- 承接与场景动作：部门撤回错误结论并恢复可追溯复核链路。
- 可见阻力与压力变化：延期问责与历史记录清理同时压来。
- 主角选择与兑现：她推动独立审查和公开复核。
- 关系收束：主管停职，信任只能慢慢重建。
- 终局兑现：真实凭证重新进入档案，全篇在责任公开后完稿。
- 因果链：撤回错误结论 → 承担延期代价 → 恢复复核链路。
MD

  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"awaiting_section_title_confirmation"'* ]]
  [[ "$output" != *'publication_shape_missing'* ]]
  [[ "$output" != *'section_function_missing'* ]]
  printf '%s' "$output" | node -e 'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => { const j = JSON.parse(s); if (!String((j.visible_response || {}).text || "").includes("- 第 1 节：复核拍到编号空缺")) throw new Error(JSON.stringify(j)); });'
}

@test "section plan lock accepts markdown headings and compact total budget line" {
  create_short_task "wf-short" "section_plan_lock"
  cat > "$BOOK/小节大纲.md" <<'MD'
# 小节大纲

- 总节数：2 节；总字数预算 3000—4000
- 每节节拍：开篇钩 → 主体推进 → 证据加 1 → 收束钩

## 第 1 节｜触发（1200—1500 字）

### 节奏定位
- 主要情绪：惊惧

### 压力变化
- 起：主角发现 AI 回答像旧人。

### 场景动作
- 她导出聊天文件并对照广告。

### 可见阻力
- 平台只承认匿名训练。

### 角色选择
- 她保存证据，不接受和解。

### 本节兑现
- 错别字证据第一次出现。

### 新钩子
- 另一个导出文件被提到。

## 第 2 节｜制度回应（1200—1500 字，收束节）

### 节奏定位
- 主要情绪：克制胜利

### 压力变化
- 起：平台试图把责任推回用户授权。

### 场景动作
- 主角公开证据链。

### 可见阻力
- 对方仍拒绝承认定向使用。

### 角色选择
- 她要求删除数据、赔礼和制度整改。

### 本节兑现
- 证据链被监管采纳。

### 终局兑现
- 用户可以查到自己的数据如何被使用，故事收束。
MD

  run node "$SCRIPT" --project-root "$BOOK" --workflow-id "wf-short" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"awaiting_section_title_confirmation"'* ]]
  [[ "$output" != *'planned_section_count_missing'* ]]
  [[ "$output" != *'target_length_band_missing'* ]]
  [[ "$output" != *'section_function_missing'* ]]
  printf '%s' "$output" | node -e 'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => { const j = JSON.parse(s); if (!String((j.visible_response || {}).text || "").includes("触发（1200—1500 字）")) throw new Error(JSON.stringify(j)); });'
}
