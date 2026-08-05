#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MODULE="$REPO_ROOT/scripts/lib/short-character-contract.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/追踪/memory"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "short character contract blocks a named cast without character engines" {
  cat > "$BOOK/设定.md" <<'EOF'
# 设定
- 叙事方式：第一人称。
- 主角：阿岚，刚毕业。
- 主管：部门负责人，39岁。
EOF

  run node - "$MODULE" "$BOOK/设定.md" <<'NODE'
const fs = require('fs');
const api = require(process.argv[2]);
const text = fs.readFileSync(process.argv[3], 'utf8');
const result = api.analyzeShortCharacterContract(text);
process.stdout.write(JSON.stringify(result));
NODE

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and (.findings[] | select(.code == "missing_protagonist_engine")) and (.findings[] | select(.code == "missing_pressure_actor_engine"))'
}

@test "short character contract accepts semantic character design without one exact template" {
  cat > "$BOOK/设定.md" <<'EOF'
# 设定

## 主要人物

### 阿岚，27 岁，女主
刚毕业，第一人称“我”。她想保住被甩锅的同事并查清凭证事故，也渴望团队把她当成能承担责任的人。她最怕失去同事的信任，误区是把主管的保证当成事实。她不懂凭证、财务和法律，只能核对亲眼所见与普通文件。最终必须亲自撤回自己的错误背书。

### 主管，39 岁，压力角色
部门负责人。他要保住渠道、授信和员工工资，认为暂时隐瞒能救部门；手里有经营权限和部门话语权，也害怕纠错导致流程失控。他不会无成本伤人，终局需要为自己的经营选择付出职位代价。

## 角色锁定卡
| 角色名 | 性别/称谓/视角身份 | 年龄/职业 | 与主角关系 | 本篇目标 | 行动边界 | 声口标记 | 证据物/证据事 |
|---|---|---|---|---|---|---|---|
| 阿岚 | 女，第一人称“我” | 27岁，毕业生 | 主管的下属 | 查清真相并保护同事 | 不突然精通商业与法律 | 嘴快，心寒时话少 | 复核回放 |
| 主管 | 男，阿岚称“主管” | 39岁，负责人 | 上级，也是主要压力来源 | 保住部门与控制权 | 不调用神秘势力 | 用工资和订单说服人 | 渠道索赔测算 |

## 人物关系与责任债
- 阿岚欠主管救过部门的现实债；主管欠阿岚被借用的公众信用。
- 两人的关系从保护与依赖，走向公开冲突与责任分离。

## 人性共鸣锁定
- 主角最怕失去同事的信任，最终选择是停止用关系替事实担保。

### 五个核心爆点
- 复核误切、主管施压、证据闭合、公开纠错、真实归档恢复。
EOF

  run node - "$MODULE" "$BOOK/设定.md" <<'NODE'
const fs = require('fs');
const api = require(process.argv[2]);
const text = fs.readFileSync(process.argv[3], 'utf8');
const result = api.analyzeShortCharacterContract(text);
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
if (result.protagonist !== '阿岚' || !result.characters.some(item => item.name === '主管')) throw new Error(JSON.stringify(result));
if (result.characters.some(item => item.name === '五个核心爆点')) throw new Error(JSON.stringify(result));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "accepted character contract projects compact active cast memory" {
  cat > "$BOOK/设定.md" <<'EOF'
# 设定
## 主要人物
### 阿岚，27 岁，女主
第一人称“我”。目标是查清真相；最怕失去团队，误区是盲信上级。她不懂财务与法律，最终必须亲自撤回错误背书。
### 主管，39 岁，压力角色
他要保住员工工资和部门控制权，认为隐瞒能救部门，也害怕纠错失去一切；不会无成本伤人。
## 角色锁定卡
| 角色名 | 性别/称谓/视角身份 | 年龄/职业 | 与主角关系 | 本篇目标 | 行动边界 | 声口标记 | 证据物/证据事 |
|---|---|---|---|---|---|---|---|
| 阿岚 | 女，第一人称“我” | 27岁，毕业生 | 下属 | 查清真相 | 不突然精通专业 | 心寒时话少 | 复核回放 |
| 主管 | 男，称“主管” | 39岁，负责人 | 上级/压力角色 | 保住部门 | 不调用神秘势力 | 用工资说服人 | 账册 |
## 人物关系与责任债
- 上下级互相背负部门与信任的责任债。
## 人性共鸣锁定
- 主角最怕失去团队，最终必须主动承担公开纠错的代价。
EOF

  run node - "$MODULE" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const result = api.projectShortCharacterMemory(root, { workflowId: 'wf-short' });
if (result.status !== 'projected') throw new Error(JSON.stringify(result));
const memory = JSON.parse(fs.readFileSync(path.join(root, '追踪/memory/active-cast.json'), 'utf8'));
if (memory.source_kind !== 'canonical_setting' || !memory.characters['阿岚'] || !memory.characters['主管']) throw new Error(JSON.stringify(memory));
if (!memory.characters['阿岚'].fear_or_stake || !memory.characters['阿岚'].capability_boundary) throw new Error(JSON.stringify(memory));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
