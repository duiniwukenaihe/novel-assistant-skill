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
- 主角：陆川，外门杂役。
- 对手：韩岳，内门弟子。
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

@test "long character contract recognizes split legacy cards with roles in headings" {
  mkdir -p "$BOOK/设定/角色"
  cat > "$BOOK/设定/角色/林川.md" <<'EOF'
# 林川（主角）
## 人物发动机
- 身份：二十二岁外门弟子。
- 外部目标：查清师门失踪案并保住证人。
- 内在渴望：最怕再次失去家人。
- 缺陷：习惯独自承担并误信权威。
- 能力边界：不懂阵法，越权调查会付出停职代价。
- 成长里程碑：第一卷从独断到主动信任同伴，终局主动选择公开证据并承担代价。
EOF
  cat > "$BOOK/设定/角色/赵衡.md" <<'EOF'
# 赵衡（少主 / 主反派）
## 对抗发动机
- 目标：为了保住继承权而封锁证据。
- 资源：拥有执法名义、修为和人脉。
- 边界与代价：不能公开杀人，失败会失去长老支持。
- 升级路径：从试探、施压到断供证据。
EOF
  cat > "$BOOK/设定/角色/陈某.md" <<'EOF'
# 陈某（反派）
仅负责前期传话。
EOF
  cat > "$BOOK/设定/关系.md" <<'EOF'
# 人物关系与责任债
林川欠同伴一次救命责任，赵衡利用林川对家人的愧疚持续施压。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const out=api.checkLongCharacterContract(process.argv[3]);
if(out.status!=='pass'||out.protagonist!=='林川'||out.pressure_actor!=='赵衡') throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract prefers bracketed role headings over conceptual parenthetical headings" {
  cat > "$BOOK/设定/世界观.md" <<'EOF'
# 世界观

## 修炼体系

### 灵族修炼等级（主角所属）
这是一套世界规则，不是人物档案。境界分为启灵、凝魄和化形。修炼目标是化形；普通灵族不能化形，受血脉限制，也要付出晋级代价。
EOF
  mkdir -p "$BOOK/设定/角色"
  cat > "$BOOK/设定/角色/世界规则.md" <<'EOF'
# 世界规则

## 灵族修炼等级（主角所属）
修炼目标是化形；普通灵族不能化形，受血脉限制，也要付出晋级代价。
EOF
  cat > "$BOOK/设定/角色.md" <<'EOF'
# 角色档案

## 【主角】顾川
二十一岁，边城巡夜人。外部目标是查清失踪案并保住证人；内在渴望是摆脱被安排的人生，最怕同伴因自己再次失踪。缺陷是习惯独自承担并误信权威。能力边界是不懂阵法，越权调查会失去职位。第一卷从独断到主动结盟，终局主动选择公开真相并承担代价。

## 【反派/竞争者】韩峥
他要保住家族的资源权，认为牺牲边城能维持秩序；拥有执法权限、人脉和修为，但不能公开违背盟约，失败会失去继承资格。升级路径从试探、施压到断供和围杀。

## 【关键配角】苏禾
她想查清兄长死因，掌握药房账册，但不能无代价盗取核心档案。

## 人物关系与责任债
三人因救命债、账册和资源权形成持续利益冲突。

## 出场与成长里程碑
第一卷主角主动结盟；第二卷关系债转为公开站队；第三卷承担领袖责任；终局选择新秩序。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const out = api.checkLongCharacterContract(process.argv[3]);
if (out.protagonist !== '顾川') throw new Error(JSON.stringify(out));
if (out.pressure_actor !== '韩峥') throw new Error(JSON.stringify(out));
  if (out.characters.some(item => item.name === '灵族修炼等级')) throw new Error(JSON.stringify(out));
if (out.status !== 'pass') throw new Error(JSON.stringify(out));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract ignores bracketed growth-stage headings" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计

## 【主角成长】第一阶段
二十一岁巡夜人，外部目标是查清失踪案；内在渴望是获得选择权；缺陷是独自承担；能力边界是不懂阵法。

## 【主角】顾川
二十一岁，身份是边城巡夜人。外部目标是查清失踪案并保住证人。内在渴望是获得自主选择权。缺陷是习惯独自承担。能力边界是不懂阵法。第一卷从独自追查到主动结盟，终局主动选择公开证据。

## 【主要对手】韩峭
他的目标是保住家族资源权，认为牺牲证人能维持秩序；拥有执法权限和人脉，但不能公开违背盟约，失败会失去继承资格。升级路径从试探、施压到断供。

## 【关键配角】苏禾
她想要找回遗失档案，掌握库房账册，但不能无代价进入密库。

## 人物关系与责任债
三人因证人、账册和资源权形成持续利益冲突。

## 出场与成长里程碑
第一卷主角主动结盟；第二卷公开站队；第三卷承担领导责任；终局选择新秩序。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const out = api.checkLongCharacterContract(process.argv[3]);
if (out.status !== 'pass' || out.protagonist !== '顾川') throw new Error(JSON.stringify(out));
if (out.characters.some(item => item.name === '第一阶段')) throw new Error(JSON.stringify(out));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract binds legacy relationship pressure to its relationship section" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计

## 主角：顾川
二十一岁巡夜人。外部目标是查清失踪案；核心执念是获得自主选择权；性格烙印是讨好型人格。能力边界是不懂阵法。第一卷从独断到主动结盟，终局主动选择公开真相。

## 主要对手：韩峥
他为了保住资源权而利用城防渠道封锁证据；拥有执法权限和人脉，但不能公开违背盟约，失败会失去继承资格；升级路径从试探到施压和围捕。
EOF
  cat > "$BOOK/设定/关系.md" <<'EOF'
# 角色关系

## 关系类型
待补。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const out = api.checkLongCharacterContract(process.argv[3]);
if (out.status !== 'blocked') throw new Error(JSON.stringify(out));
if (!out.findings.some(item => item.code === 'missing_relationship_engine')) throw new Error(JSON.stringify(out));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract merges compact rosters with standalone legacy profiles" {
  mkdir -p "$BOOK/设定/角色"
  cat > "$BOOK/设定/角色.md" <<'EOF'
# 角色设定

## 【主角】顾川
| 身份 | 边城巡夜人 |

## 【反派/竞争者】韩峥
| 身份 | 城防司副统领 |
EOF
  cat > "$BOOK/设定/角色/顾川.md" <<'EOF'
# 角色档案：顾川
> **身份定位**：边城巡夜人 / 主角

- 外部目标：查清失踪案并保住证人。
- 核心执念：获得自主选择权，不再让同伴替自己承担后果。
- 性格烙印：讨好型人格令他总想独自扛下责任。
- 能力边界：不懂阵法，越权调查会失去职位。
- 第一卷从独断到主动结盟；终局主动选择公开真相并承担代价。
EOF
  cat > "$BOOK/设定/角色/韩峥.md" <<'EOF'
# 角色档案：韩峥
> **身份定位**：城防司副统领 / 反派

- 目标：为了保住家族资源权而封锁证据。
- 可用资源：拥有执法权限、城防人脉和家族名义。
- 边界与代价：不能公开违背盟约，失败会失去继承资格。
- 升级路径：从试探、施压到断供和围捕。
EOF
  cat > "$BOOK/设定/关系.md" <<'EOF'
# 角色关系图

## 关系类型
顾川与韩峥是调查者和控制者，韩峥持续利用执法权压迫顾川停查。

## 关系演变
第一卷从暗中监视升级到公开追捕；终局由顾川选择公开证据。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const out = api.checkLongCharacterContract(process.argv[3]);
if (out.status !== 'pass' || out.protagonist !== '顾川' || out.pressure_actor !== '韩峥') throw new Error(JSON.stringify(out));
const protagonist = out.characters.find(item => item.name === '顾川');
if (!protagonist || !protagonist.body.includes('能力边界')) throw new Error(JSON.stringify(out));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract blocks identity-only character sheets" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物
- 主角：陆川，外门杂役。
- 对手：韩岳，内门弟子。
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

## 主角：陆川
十九岁，外门杂役。外部目标是脱离任人宰割的杂役身份，查清师父失踪的真相；内在渴望是被当成有选择权的人。他最怕再次因为软弱失去亲近的人，误区是凡事独自承担才不会拖累别人。能力边界是只懂底层生存和基础刀法，不会突然精通阵法、炼丹或宗门政治。第一卷从只求自保到主动结盟；第三卷学会承担领袖责任；终局必须在复仇和建立新秩序之间作出主动选择。

## 主要对手：韩岳
内门执事弟子。他要保住资源分配权与师门地位，认为牺牲少数杂役能维持宗门秩序；拥有执法名义、内门人脉和修为优势，但不能公开违背门规。他从试探、断供升级到借规则围杀，失败也会损失师门信用和盟友。

## 关键配角：苏禾
药堂学徒。她想查清兄长死因并获得独立身份，不只负责救治主角；她掌握药堂账册，却不能无代价偷取核心档案。她与陆川从互相利用走向共同承担风险。

## 人物关系与责任债
- 陆川欠苏禾一次救命债，苏禾需要陆川进入她无法进入的矿洞。
- 韩岳用秩序和资源压迫二人，三人的利益冲突会随卷级升级。

## 出场与成长里程碑
- 第一卷：陆川、苏禾、韩岳完成首次正面碰撞，陆川从被动自保到主动结盟。
- 第二卷：关系债转为公开站队，能力成长必须支付失去安全退路的代价。
- 第三卷：主角承担领袖责任，对手失去合法性但获得更危险的外部资源。
- 终局：主角主动选择新秩序，关系债完成兑现。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const api = require(process.argv[2]);
const result = api.checkLongCharacterContract(process.argv[3]);
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
if (result.protagonist !== '陆川' || result.characters.length < 3) throw new Error(JSON.stringify(result));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract projects canonical cast memory" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计
## 主角：陆川
十九岁，外门杂役。目标是脱离杂役身份，最怕再次失去亲近的人，误区是凡事独自承担。能力边界是不懂阵法和宗门政治。第一卷从被动自保到主动结盟，终局必须主动选择新秩序。
## 主要对手：韩岳
他要保住资源分配权，认为牺牲杂役能维持秩序；拥有执法名义和修为优势，但不能公开违背门规，阻力会从断供升级到围杀。
## 关键配角：苏禾
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
if (!memory.characters['陆川'] || !memory.characters['韩岳']) throw new Error(JSON.stringify(memory));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character memory ignores markdown fragments and unclosed prose" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计

## 主角：顾川
| 身份 | 临江档案员 |
二十四岁，职业是临江城档案员。
- 外部目标：查清旧档失窃案并保住证人。
- 内在渴望：不再让同伴替自己承担后果。
### 核心矛盾
缺陷是习惯独自承担。
- 能力边界是“只会查档，不懂阵法。
能力边界是不懂阵法，越权调查会失去职位。
- 第一卷从独自追查到主动结盟；终局主动选择公开证据。

## 主要对手：韩峭
他的目标是保住家族资源权，认为牺牲证人能维持秩序；拥有执法权限、人脉和证据渠道，但不能公开违背盟约，失败会失去继承资格。升级路径从试探、施压到断供和围捕。

## 关键配角：苏禾
她想要找回遗失档案，掌握库房账册，但不能无代价进入密库。

## 人物关系与责任债
三人因证人、账册和资源权形成持续利益冲突。

## 出场与成长里程碑
第一卷主角主动结盟；第二卷公开站队；第三卷承担领导责任；终局选择新秩序。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const result = api.projectLongCharacterMemory(root, { workflowId: 'wf-neutral' });
if (result.status !== 'projected') throw new Error(JSON.stringify(result));
const memory = JSON.parse(fs.readFileSync(path.join(root, '追踪/memory/active-cast.json'), 'utf8'));
const protagonist = memory.characters['顾川'];
if (!protagonist) throw new Error(JSON.stringify(memory));
if (protagonist.identity !== '二十四岁，职业是临江城档案员。') throw new Error(JSON.stringify(protagonist));
if (protagonist.flaw_or_misbelief !== '缺陷是习惯独自承担。') throw new Error(JSON.stringify(protagonist));
if (protagonist.capability_boundary !== '能力边界是不懂阵法，越权调查会失去职位。') throw new Error(JSON.stringify(protagonist));
for (const value of Object.values(protagonist)) {
  if (typeof value !== 'string') continue;
  if (/^#{1,6}\s|^\s*\|/.test(value)) throw new Error(JSON.stringify(protagonist));
  if ((value.match(/“/g) || []).length !== (value.match(/”/g) || []).length) throw new Error(JSON.stringify(protagonist));
}
if (memory.presentCharacters.length !== 0) throw new Error(JSON.stringify(memory));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character memory keeps valid plain-text profile sentences" {
  cat > "$BOOK/设定/人物.md" <<'EOF'
# 人物设计
## 主角：顾川
二十四岁，身份是临江档案员。外部目标是查清旧档失窃案。最怕证人因自己受伤。缺陷是习惯独自承担。能力边界是不懂阵法。第一卷从独自追查到主动结盟，终局主动选择公开证据。
## 主要对手：韩峭
他的目标是保住家族资源权，认为牺牲证人能维持秩序；拥有执法权限和人脉，但不能公开违背盟约，失败会失去继承资格。升级路径从试探、施压到断供。
## 关键配角：苏禾
她想要找回遗失档案，掌握库房账册，但不能无代价进入密库。
## 人物关系与责任债
三人因证人、账册和资源权形成持续利益冲突。
## 出场与成长里程碑
第一卷主角主动结盟；第二卷公开站队；第三卷承担领导责任；终局选择新秩序。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const result = api.projectLongCharacterMemory(root, { workflowId: 'wf-neutral' });
if (result.status !== 'projected') throw new Error(JSON.stringify(result));
const protagonist = JSON.parse(fs.readFileSync(path.join(root, '追踪/memory/active-cast.json'), 'utf8')).characters['顾川'];
if (protagonist.identity !== '二十四岁，身份是临江档案员。') throw new Error(JSON.stringify(protagonist));
if (protagonist.goal !== '外部目标是查清旧档失窃案。') throw new Error(JSON.stringify(protagonist));
if (protagonist.flaw_or_misbelief !== '缺陷是习惯独自承担。') throw new Error(JSON.stringify(protagonist));
if (protagonist.capability_boundary !== '能力边界是不懂阵法。') throw new Error(JSON.stringify(protagonist));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract blocks a core profile that cannot be safely projected" {
  LONG_DETAIL="$(printf '他必须逐项核验每份旧档并记录证据链%.0s' {1..28})"
  cat > "$BOOK/设定/人物.md" <<EOF
# 人物设计
## 主角：顾川
二十四岁，身份是临江档案员，外部目标是查清旧档失窃案，内在渴望是保住证人，缺陷是习惯独自承担，能力边界是不懂阵法，${LONG_DETAIL}，第一卷从独自追查成长为主动结盟，终局主动选择公开证据。
## 主要对手：韩峭
他的目标是保住家族资源权，认为牺牲证人能维持秩序；拥有执法权限和人脉，但不能公开违背盟约，失败会失去继承资格。升级路径从试探、施压到断供。
## 关键配角：苏禾
她想要找回遗失档案，掌握库房账册，但不能无代价进入密库。
## 人物关系与责任债
三人因证人、账册和资源权形成持续利益冲突。
## 出场与成长里程碑
第一卷主角主动结盟；第二卷公开站队；第三卷承担领导责任；终局选择新秩序。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const result = api.projectLongCharacterMemory(root, { workflowId: 'wf-neutral' });
  if (result.status !== 'blocked') throw new Error(JSON.stringify(result));
const finding = result.findings.find(item => item.code === 'unprojectable_character_memory_fields');
if (!finding || finding.character !== '顾川' || !finding.missing_fields.includes('identity')) throw new Error(JSON.stringify(result));
if (fs.existsSync(path.join(root, '追踪/memory/active-cast.json'))) throw new Error('active-cast should not be written');
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "long character contract accepts one-file-per-character projects" {
  mkdir -p "$BOOK/设定/角色"
  cat > "$BOOK/设定/角色/陆川.md" <<'EOF'
# 陆川
角色定位：主角。十九岁杂役，目标是脱离杂役身份；最怕失去亲近的人，误区是凡事独自承担。能力边界是不懂阵法和宗门政治。第一卷从被动自保到主动结盟，终局必须选择新秩序。
EOF
  cat > "$BOOK/设定/角色/韩岳.md" <<'EOF'
# 韩岳
角色定位：主要对手。他要保住资源权，认为牺牲少数人能维持秩序；拥有执法名义和修为资源，但不能公开违背门规，失败会失去信用，压力从断供升级到围杀。
EOF
  cat > "$BOOK/设定/角色/苏禾.md" <<'EOF'
# 苏禾
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
if(out.status!=='pass'||out.characters.length!==3||out.protagonist!=='陆川') throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
