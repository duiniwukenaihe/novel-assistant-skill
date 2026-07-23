#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/short-plan-contract.js"
  ENTRY_GUARD="$REPO_ROOT/scripts/short-prose-entry-guard.js"
  BRIEF_FRESHNESS="$REPO_ROOT/scripts/short-brief-freshness.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/追踪/private-short-extension"
  printf '# 素材卡\n> 状态：已确认\n\n故事核：直播翻车。\n' > "$BOOK/素材卡.md"
  cat > "$BOOK/设定.md" <<'EOF'
# 设定
> 状态：素材、核心设定、节奏模型和3节写作计划已确认。
- 叙事方式：第一人称女主有限视角。
- 目标长度：4,500-5,500字，共3节。
- 主节奏：直播翻车 -> 查证 -> 公开纠错。
EOF
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：直播翻车
- 结构功能：开篇。
- 场景动作：主角主动开播回应质疑，镜头误切到空车间。
- 角色选择：主角拒绝下播，当场追问车间为何是空的。
- 开篇钩子：宣称现榨的直播间后方没有一只水果。
- 故事承诺：主角将在亲情与真相之间做出不可退回的选择。
- 子事件：
  1. 主角用家族身份为产品背书。
  2. 镜头误切让谎言暴露。
- 情绪目标：自信到茫然。
- 因果链：回应质疑 -> 直播 -> 误切。
- 节尾钩子：空车间。
## 第2节：替员工出头
- 结构功能：升级。
- 承接上节：空车间的直播画面逼主角追问生产现场。
- 场景动作：管理层当面要求员工背锅，主角当场调取播放日志。
- 角色选择：主角拒绝签署甩锅声明。
- 可见阻力：家人用公司存亡和员工生计逼她沉默。
- 本节兑现：播放日志证明出错素材早在三年前就被上传。
- 关系变化：主角从信任家人转为保护员工并独立查证。
- 代价升级：她失去家人保护，并成为公司危机的第一责任人。
- 核心承诺兑现：她第一次公开选择真相而不是家族。
- 决定性行动：她备份日志并联系独立审查方。
- 即时代价：哥哥取消她的公司权限。
- 子事件：
  1. 管理层逼员工背锅。
  2. 主角调取日志并备份证据。
- 情绪目标：信任到动摇。
- 压力变化：主角从网络质疑转入家人与员工之间的正面冲突。
- 因果链：甩锅 -> 查日志 -> 旧素材。
- 节尾钩子：三年前上传。
## 第3节：我先认错
- 结构功能：高潮与结尾。
- 承接上节：三年前上传的素材迫使主角公开核对品牌承诺。
- 场景动作：主角在直播中公布脱敏证据并启动召回。
- 角色选择：她先承认自己的传播责任，不把过错推给员工。
- 现实后果：产品召回、公司停产、主角退还报酬。
- 关系收束：她与家人保持裂痕，不写突然和解。
- 主题回扣：从家族故事背书转向只说自己能核实的事。
- 子事件：
  1. 主角公布证据并认错。
  2. 召回与家庭代价真正落地。
- 情绪目标：恐惧到承担。
- 因果链：证据闭合 -> 公开承认 -> 召回。
- 节尾钩子：承担后果。
EOF
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'EOF'
{
  "project_id": "short-plan-test",
  "plan_revision": 1,
  "narrative": {"planned_sections": 3, "target_length": "4500-5500字"},
  "current_section_index": 1,
  "accepted_sections": [],
  "remaining_sections": [1, 2, 3]
}
EOF
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "short plan contract accepts a complete whole-story section blueprint" {
  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "current" and .planned_sections == 3 and .outlined_sections == [1,2,3] and .current_section_index == 1'
}

@test "short plan contract accepts inline causal chains as executable events" {
  node - "$BOOK/小节大纲.md" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8').replace(
  /- 子事件：\n\s*1[.、)]\s*([^\n]+)\n\s*2[.、)]\s*([^\n]+)/gu,
  (_, first, second) => `- 因果链：${first.trim()} → ${second.trim()}`,
);
fs.writeFileSync(file, text);
NODE

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "current" and .narrative_quality.status == "pass"'
}

@test "section outline contract accepts semantic combined fields without legacy labels" {
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲

## 第1节：镜头拍到空车间
- 承接与场景动作：主角主动开播回应质疑，镜头误切到空车间。
- 可见阻力与压力变化：家人要求她按统一口径解释，舆论开始质疑产品。
- 主角选择与兑现：她拒绝甩锅导播，保留直播回放并追问生产记录。
- 关系后果、代价与钩子：家人停掉她的权限；旧生产记录显示三年前已经没有鲜果入厂。
- 开篇钩子：宣称鲜榨的工厂里没有一只水果。
- 故事承诺：她必须在家族利益与消费者知情权之间作出选择。
- 因果链：回应质疑 -> 误切空车间 -> 拒绝甩锅 -> 权限被停。

## 第2节：记录早已过期
- 承接与场景动作：主角核对生产记录并当面质问管理层。
- 承接上节：空车间直播迫使主角追查生产记录。
- 可见阻力与压力变化：家人用员工工资和渠道索赔逼她沉默。
- 主角选择与兑现：她备份记录并联系独立审查方。
- 核心爆点兑现：生产记录证明品牌承诺与真实生产长期相反。
- 决定性行动：她把证据交给独立审查方并拒绝撤回。
- 关系后果、代价与钩子：她失去家人保护，并发现压榨线已经卖掉。
- 因果链：查记录 -> 发现断档 -> 备份证据 -> 找到设备交易。

## 第3节：镜头里重新有了水果
- 承接与场景动作：企业停售旧货，主角提交召回与整改方案。
- 承接上节：设备交易证据迫使企业停止旧产品销售。
- 可见阻力与压力变化：停线后的工资、渠道和家庭压力同时落地。
- 主角选择与兑现：她推动独立品控和真实鲜果入厂直播。
- 关系收束：家人退出治理，信任没有立刻恢复。
- 主题回扣与结尾钩子：镜头里终于有水果，所有批次继续公开接受核验。
- 因果链：停售召回 -> 承担停线代价 -> 恢复真实生产 -> 长期公开。
EOF

  run node - "$REPO_ROOT/scripts/lib/short-section-outline-contract.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const root=process.argv[3];
for (const index of [1,2,3]) {
  const result=api.buildShortSectionOutlineContract(root,index);
  if(result.status!=='current' || result.obligations.length<4) throw new Error(JSON.stringify(result));
}
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run node "$SCRIPT" check --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "current" and ([.findings[] | select(.code == "section_blueprint_underfilled")] | length) == 0'
}

@test "short plan contract blocks missing planned sections" {
  perl -0pi -e 's/## 第2节：[\s\S]*?(?=## 第3节：)//' "$BOOK/小节大纲.md"

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and (.findings[] | select(.code == "missing_outlined_sections" and (.sections | index(2)) != null))'
}

@test "short plan contract blocks writing beyond the locked section count" {
  jq '.current_section_index = 4' "$BOOK/追踪/private-short-extension/project-state.json" > "$BOOK/state.tmp"
  mv "$BOOK/state.tmp" "$BOOK/追踪/private-short-extension/project-state.json"

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and (.findings[] | select(.code == "current_section_out_of_range"))'
}

@test "short plan contract blocks a mechanically complete outline with no dramatic engine" {
  node - "$BOOK/小节大纲.md" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
let text = fs.readFileSync(file, 'utf8');
text = text.replace(/(## 第2节：[\s\S]*?)(?=## 第3节：)/u, (block) => block
  .replace(/- 角色选择：[^\n]*\n/u, '')
  .replace(/- 可见阻力：[^\n]*\n/u, '')
  .replace(/- 本节兑现：[^\n]*\n/u, '')
  .replace(/- 关系变化：[^\n]*\n/u, '')
  .replace(/- 代价升级：[^\n]*\n/u, '')
  .replace('1. 管理层逼员工背锅。', '1. 读取三年前记录。')
  .replace('2. 主角调取日志并备份证据。', '2. 核对附件编号。'));
fs.writeFileSync(file, text);
NODE

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and (.findings[] | select(.code == "section_narrative_engine_underfilled" and .section == 2 and (.missing_signals | index("protagonist_choice")) != null))'
}

@test "short plan contract blocks a disconnected cross-section hook" {
  perl -0pi -e 's/承接上节：空车间的直播画面逼主角追问生产现场。/承接上节：主角忽然收到一封与直播无关的匿名情书。/' "$BOOK/小节大纲.md"

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and (.findings[] | select(.code == "section_hook_handoff_disconnected" and .section == 2))'
}

@test "protected prose still participates in the next section hook handoff" {
  node - "$BOOK/追踪/private-short-extension/project-state.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.accepted_sections = [{ section_index: 1, source_kind: 'user_confirmed', user_confirmed: true }];
fs.writeFileSync(file, JSON.stringify(value));
NODE
  perl -0pi -e 's/承接上节：空车间的直播画面逼主角追问生产现场。/承接上节：主角忽然收到一封与直播无关的匿名情书。/' "$BOOK/小节大纲.md"

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and (.findings[] | select(.code == "section_hook_handoff_disconnected" and .section == 2 and .previous_hook_anchor == "H001"))'
}

@test "protected sections still block on narrative gaps without authorizing overwrite" {
  node - "$BOOK/追踪/private-short-extension/project-state.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.accepted_sections = [{ section_index: 1, source_kind: 'user_confirmed', user_confirmed: true }];
fs.writeFileSync(file, JSON.stringify(value));
NODE
  perl -0pi -e 's/- 场景动作：[^\n]*\n//; s/- 开篇钩子：[^\n]*\n//; s/- 故事承诺：[^\n]*\n//' "$BOOK/小节大纲.md"

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and .user_confirmed_sections == [1] and (.findings[] | select(.code == "section_narrative_engine_underfilled" and .section == 1 and .protected_user_confirmed == true))'
}

@test "short plan contract preserves only explicitly user-confirmed legacy sections" {
  node - "$BOOK/追踪/private-short-extension/project-state.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
value.accepted_sections = [
  { section_index: 1, source_kind: 'user_confirmed', user_confirmed: true },
  { section_index: 2, source_kind: 'legacy', user_confirmed: false },
];
fs.writeFileSync(file, JSON.stringify(value));
NODE
  perl -0pi -e 's/- 场景动作：[^\n]*\n//; s/- 开篇钩子：[^\n]*\n//; s/- 故事承诺：[^\n]*\n//' "$BOOK/小节大纲.md"
  run node "$SCRIPT" check --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked" and .user_confirmed_sections == [1] and (.findings[] | select(.section == 1 and .protected_user_confirmed == true))'
}

@test "short prose entry guard allows a fresh brief backed by a complete plan" {
  printf '# 写作 Brief：第001节\n依据小节大纲第1节。\n' > "$BOOK/写作Brief_第001节.md"
  node "$BRIEF_FRESHNESS" snapshot --project-root "$BOOK" --brief 写作Brief_第001节.md --section-index 1 --write --json >/dev/null

  run node "$ENTRY_GUARD" check --project-root "$BOOK" --brief 写作Brief_第001节.md --section-index 1 --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "pass" and .plan.status == "current" and .brief.status == "current"'
}

@test "short prose entry guard blocks a brief after the whole-story outline changes" {
  printf '# 写作 Brief：第001节\n依据小节大纲第1节。\n' > "$BOOK/写作Brief_第001节.md"
  node "$BRIEF_FRESHNESS" snapshot --project-root "$BOOK" --brief 写作Brief_第001节.md --section-index 1 --write --json >/dev/null
  printf '\n- 新增反转：直播事故由主动揭露改为误切。\n' >> "$BOOK/小节大纲.md"

  run node "$ENTRY_GUARD" check --project-root "$BOOK" --brief 写作Brief_第001节.md --section-index 1 --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked_short_brief_stale" and (.brief.stale_dependencies | index("小节大纲.md")) != null'
}
