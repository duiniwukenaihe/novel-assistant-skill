#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MODULE="$REPO_ROOT/scripts/lib/workflow-character-contract.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/设定" "$BOOK/追踪/memory"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "workflow blocks long character stage before accepting an incomplete cast" {
  printf '%s\n' '# 人物' '- 主角：沈七，杂役。' '- 对手：莫青山，内门弟子。' > "$BOOK/设定/人物.md"
  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-long',workflow_type:'long_startup',current_stage:'character_design'};
const result={step_status:'completed',changed_files:['设定/人物.md']};
const out=api.validateWorkflowCharacterContract(root,task,result);
if(!out||out.status!=='blocked_character_contract_revision_required') throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "workflow projects long cast only after an accepted character stage" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计
## 主角：沈七
十九岁杂役。目标是脱离杂役身份，最怕失去亲近的人，误区是凡事独自承担；能力边界是不懂阵法和宗门政治。第一卷从被动自保到主动结盟，终局必须选择新秩序。
## 主要对手：莫青山
他要保住资源权，认为牺牲少数人能维持秩序；拥有执法名义和修为资源，但不能公开违背门规，失败会失去师门信用，压力从断供升级到围杀。
## 关键配角：绿珠
她想查清兄长死因，掌握药堂账册但不能无代价盗取档案。
## 人物关系与责任债
- 三人因救命债和资源权形成持续利益冲突。
## 出场与成长里程碑
- 第一卷主动结盟；第二卷公开站队；第三卷承担领袖责任；终局选择新秩序。
EOF
  run node - "$MODULE" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-long',workflow_type:'long_write',current_stage:'story_bible'};
const result={step_status:'completed',changed_files:['设定/人物.md']};
const checked=api.validateWorkflowCharacterContract(root,task,result);
if(!checked||checked.status!=='pass') throw new Error(JSON.stringify(checked));
const projected=api.projectWorkflowCharacterContract(root,task,result);
if(projected.status!=='projected') throw new Error(JSON.stringify(projected));
const memory=JSON.parse(fs.readFileSync(path.join(root,'追踪/memory/active-cast.json'),'utf8'));
if(memory.workflow_id!=='wf-long'||!memory.characters['沈七']) throw new Error(JSON.stringify(memory));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "workflow leaves read-only review stages outside the character write gate" {
  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const out=api.validateWorkflowCharacterContract(process.argv[3],{workflow_type:'short_review',current_stage:'evidence_scan'},{step_status:'completed'});
if(out!==null) throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
