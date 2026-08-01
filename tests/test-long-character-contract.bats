#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MODULE="$REPO_ROOT/scripts/lib/long-character-contract.js"
  CONTEXT_MODULE="$REPO_ROOT/scripts/lib/long-stage-context-packet.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/设定" "$BOOK/追踪/memory"
}

@test "long chapter entry blocks legacy projects until the character contract is complete" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物
- 主角：沈七，外门杂役。
- 对手：莫青山，内门弟子。
EOF

  run node - "$CONTEXT_MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const result = api.buildLongStageContextPacket({
  projectRoot: process.argv[3],
  task: { workflow_id: 'wf-long', workflow_type: 'long_write', current_stage: 'chapter_brief', user_goal: '写第1章' },
  stage: 'chapter_brief',
});
if (result.status !== 'blocked_long_character_contract_upgrade_required') throw new Error(JSON.stringify(result));
if (result.resume_stage !== 'story_bible' || !Array.isArray(result.findings) || result.findings.length === 0) throw new Error(JSON.stringify(result));
process.stdout.write(JSON.stringify(result));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "long character contract blocks identity-only character sheets" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物
- 主角：沈七，外门杂役。
- 对手：莫青山，内门弟子。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const result = api.checkLongCharacterContract(process.argv[3]);
process.stdout.write(JSON.stringify(result));
NODE

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and (.findings[] | select(.code == "missing_protagonist_engine")) and (.findings[] | select(.code == "missing_longform_growth_map"))'
}

@test "long character contract accepts a durable story bible" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计

## 主角：沈七
十九岁，外门杂役。外部目标是脱离任人宰割的杂役身份，查清师父失踪的真相；内在渴望是被当成有选择权的人。他最怕再次因为软弱失去亲近的人，误区是凡事独自承担才不会拖累别人。能力边界是只懂底层生存和基础刀法，不会突然精通阵法、炼丹或宗门政治。第一卷从只求自保到主动结盟；第三卷学会承担领袖责任；终局必须在复仇和建立新秩序之间作出主动选择。

## 主要对手：莫青山
内门执事弟子。他要保住资源分配权与师门地位，认为牺牲少数杂役能维持宗门秩序；拥有执法名义、内门人脉和修为优势，但不能公开违背门规。他从试探、断供升级到借规则围杀，失败也会损失师门信用和盟友。

## 关键配角：绿珠
药堂学徒。她想查清兄长死因并获得独立身份，不只负责救治主角；她掌握药堂账册，却不能无代价偷取核心档案。她与沈七从互相利用走向共同承担风险。

## 人物关系与责任债
- 沈七欠绿珠一次救命债，绿珠需要沈七进入她无法进入的矿洞。
- 莫青山用秩序和资源压迫二人，三人的利益冲突会随卷级升级。

## 出场与成长里程碑
- 第一卷：沈七、绿珠、莫青山完成首次正面碰撞，沈七从被动自保到主动结盟。
- 第二卷：关系债转为公开站队，能力成长必须支付失去安全退路的代价。
- 第三卷：主角承担领袖责任，对手失去合法性但获得更危险的外部资源。
- 终局：主角主动选择新秩序，关系债完成兑现。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const result = api.checkLongCharacterContract(process.argv[3]);
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
if (result.protagonist !== '沈七' || result.characters.length < 3) throw new Error(JSON.stringify(result));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract projects canonical cast memory" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计
## 主角：沈七
十九岁，外门杂役。目标是脱离杂役身份，最怕再次失去亲近的人，误区是凡事独自承担。能力边界是不懂阵法和宗门政治。第一卷从被动自保到主动结盟，终局必须主动选择新秩序。
## 主要对手：莫青山
他要保住资源分配权，认为牺牲杂役能维持秩序；拥有执法名义和修为优势，但不能公开违背门规，阻力会从断供升级到围杀。
## 关键配角：绿珠
她想查清兄长死因并获得独立身份，掌握药堂账册但不能无代价盗取档案。
## 人物关系与责任债
- 三人因救命债、账册和资源分配形成持续利益冲突。
## 出场与成长里程碑
- 第一卷：主角主动结盟；第二卷：公开站队；第三卷：承担领袖责任；终局：选择新秩序。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const result = api.projectLongCharacterMemory(root, { workflowId: 'wf-long' });
if (result.status !== 'projected') throw new Error(JSON.stringify(result));
const memory = JSON.parse(fs.readFileSync(path.join(root, '追踪/memory/active-cast.json'), 'utf8'));
if (memory.source_kind !== 'canonical_story_bible' || memory.workflow_id !== 'wf-long') throw new Error(JSON.stringify(memory));
if (!memory.characters['沈七'] || !memory.characters['莫青山']) throw new Error(JSON.stringify(memory));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract accepts one-file-per-character projects" {
  mkdir -p "$BOOK/设定/角色"
  cat > "$BOOK/设定/角色/沈七.md" <<'EOF'
# 沈七
角色定位：主角。十九岁杂役，目标是脱离杂役身份；最怕失去亲近的人，误区是凡事独自承担。能力边界是不懂阵法和宗门政治。第一卷从被动自保到主动结盟，终局必须选择新秩序。
EOF
  cat > "$BOOK/设定/角色/莫青山.md" <<'EOF'
# 莫青山
角色定位：主要对手。他要保住资源权，认为牺牲少数人能维持秩序；拥有执法名义和修为资源，但不能公开违背门规，失败会失去信用，压力从断供升级到围杀。
EOF
  cat > "$BOOK/设定/角色/绿珠.md" <<'EOF'
# 绿珠
角色定位：关键配角。她想查清兄长死因，掌握药堂账册但不能无代价盗取档案。
EOF
  cat > "$BOOK/设定/关系.md" <<'EOF'
# 人物关系与责任债
- 三人因救命债和资源权形成持续利益冲突。
# 出场与成长里程碑
- 第一卷主动结盟；第二卷公开站队；第三卷承担领袖责任；终局选择新秩序。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const out=api.checkLongCharacterContract(process.argv[3]);
if(out.status!=='pass'||out.characters.length!==3||out.protagonist!=='沈七') throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
