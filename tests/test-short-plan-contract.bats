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

## 主要人物
### 林照，22岁，女主
第一人称“我”。她要查清直播事故并保护被甩锅的员工，最怕失去家人的爱；误区是把亲人的保证当成事实。她不懂生产、财务和法律，最终必须亲自撤回错误背书并承担公开纠错的代价。

### 林建川，37岁，哥哥
集团负责人。他要保住公司、订单和员工工资，认为暂时隐瞒能救企业；拥有经营权限，但不能无成本伤人，也必须承担错误决策的职位代价。

## 角色锁定卡
| 角色名 | 性别/称谓/视角身份 | 年龄/职业 | 与主角关系 | 本篇目标 | 行动边界 |
|---|---|---|---|---|---|
| 林照 | 女，第一人称“我” | 22岁，毕业生 | 妹妹 | 查清事故并保护员工 | 不突然精通商业与法律 |
| 林建川 | 男，称“哥” | 37岁，负责人 | 哥哥/压力角色 | 保住公司和控制权 | 不调用神秘关系解决危机 |

## 人物关系与责任债
- 林照欠哥哥保护家庭的现实债；哥哥欠林照被滥用的公众信用，两人的关系从保护与依赖走向公开冲突。
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
  printf '%s' "$output" | jq -e '.status == "current" and .narrative_quality.status == "pass"' || { echo "$output"; false; }
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

@test "short outline accepts bold natural labels and optional machine aliases without yaml" {
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲

## 第1节：夜语用她的原话反问她
**开篇钩（opening_hook）**：夜语第一次用林栖只说给它听过的话反问她。
**故事承诺**：她必须查清自己的脆弱如何被加工成商品。
**场景动作**：林栖对照聊天导出与前男友旧语音，保存第一份本地证据。
**主角选择**：她没有关闭软件，而是决定继续比对并留下证据。
**因果事件（causal_events）**：房东催租 → 她向夜语抱怨 → 夜语复述私密句式 → 她打开本地导出。
**情绪目标**：依赖转为警觉。
**节尾钩子**：她无法证明来源，却再也不能把它当成巧合。

## 第2节：秘密出现在城市大屏
**接力入（handoff_in）**：她无法证明来源、也不能再当成巧合，第二天在地铁口撞见同一句话。
**压力变化**：私人怀疑升级为公开传播与限时和解压力。
**可见阻力**：广告大屏、保密和解函与法务倒计时同时出现。
**场景动作**：她截屏广告错字，对照导出时间戳，把证据按顺序摆上桌。
**主角选择**：她拒绝签署保密和解。
**本节兑现**：广告错字与私密对话中的错字一致，巧合解释被击穿。
**关系变化**：她与公司从普通用户变成公开争议中的对手方。
**代价升级**：她放弃可以立刻缓解房租压力的和解金。
**核心承诺兑现**：她确认私密表达已经被定向用于公开广告。
**决定性动作**：她拒绝和解并保存全部公开版本。
**即时代价**：她失去房租缓冲，也暴露在公司的公开口径中。
**因果事件（causal_events）**：看见广告 → 对照错字 → 收到和解函 → 拒绝签字。
**节尾钩子**：公司声明所有内容都来自匿名训练数据，她必须寻找内部证据。

## 第3节：我把证据交出去
**接力入（handoff_in）**：公司声明所有内容都来自匿名训练数据，逼她寻找内部证据。
**场景动作**：她核对内部截图、公开广告版本与本地导出，整理投诉目录。
**主角选择**：她公开承认自己的判断边界，只提交能够核验的证据。
**现实后果**：广告停投，监管介入，公司必须保存相关记录。
**关系收束**：她没有与前男友复合，而是重新向朋友表达真实需要。
**主题回扣**：理解一个人不等于拥有和出售她的脆弱。
**情绪目标**：恐惧转为承担。
**因果事件（causal_events）**：内部证据到手 → 她完成交叉验证 → 公开提交 → 制度回应落地。
**节尾钩子**：她第一次主动给朋友打电话。
EOF

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "current" and .narrative_quality.status == "pass"' || { echo "$output"; false; }

  run node - "$REPO_ROOT/scripts/lib/short-section-outline-contract.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const root=process.argv[3];
for (const index of [1,2,3]) {
  const result=api.buildShortSectionOutlineContract(root,index);
  if(result.status!=="current") throw new Error(JSON.stringify(result));
  if(!result.obligations.some(item=>item.kind==="scene_action")) throw new Error(JSON.stringify(result));
}
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "semantic alias coverage does not require mechanical S00/B01 machine codes" {
  # P1.1 验证点一：字段名不同但语义完整时，不得要求机械增加编号。
  # 默认 fixture 合同通过，反馈全文不得出现 S00/B01 这类机械编号要求。
  run node "$SCRIPT" check --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "current" and .narrative_quality.status == "pass"' || { echo "$output"; false; }
  [[ "$output" != *"S00"* ]]
  [[ "$output" != *"B01"* ]]

  # P1.1 验证点二：语义覆盖是可解释的——当信号通过别名（非精确字段名）
  # 命中时，signal_mappings 必须把匹配来源暴露成可审计条目，证明系统
  # 识别的是语义而非硬编号补全。这里第2节只用语义字段（可见阻力/本节
  # 兑现/关系变化/代价升级），scene_action/protagonist_choice 等信号只能
  # 经由别名推断得到，mapped_aliases 必须非空。
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
- 可见阻力：家人用公司存亡逼她沉默。
- 本节兑现：播放日志证明出错素材早在三年前就被上传。
- 关系变化：主角从信任家人转为独立查证。
- 代价升级：她失去家人保护。
- 子事件：
  1. 管理层逼员工背锅，主角拒绝签署甩锅声明。
  2. 主角调取日志并备份证据。
- 情绪目标：信任到动摇。
- 压力变化：主角从网络质疑转入家人与员工之间的正面冲突。
- 因果链：甩锅 -> 查日志 -> 旧素材。
- 节尾钩子：三年前上传。
EOF
  node - "$BOOK/追踪/private-short-extension/project-state.json" <<'NODE'
const fs=require('fs');const f=process.argv[2];const v=JSON.parse(fs.readFileSync(f,'utf8'));v.narrative.planned_sections=2;v.remaining_sections=[1,2];fs.writeFileSync(f,JSON.stringify(v));
NODE

  run node "$SCRIPT" check --project-root "$BOOK" --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # 别名审计必须把语义推断来源暴露出来（mapped_aliases 非空）。
  printf '%s' "$output" | jq -e '[.narrative_quality.signal_mappings[].mapped_aliases[]] | length > 0' || { echo "$output"; false; }
  # 审计条目同样不得带 S00/B01 机械编号。
  [[ "$output" != *"S00"* ]]
  [[ "$output" != *"B01"* ]]
}

@test "narrative gaps are listed per section not collapsed into a range" {
  # P1.1 验证点：缺口必须按小节列出，不得只解释第1节却声称"1-9节都缺"。
  # 构造一篇第1节和第2节同时缺 protagonist_choice（都只有查表式证据动作、
  # 没有任何角色选择动词）的大纲，合同必须分别给出 section==1 与 section==2
  # 两条独立 finding，各自带小节号与缺失信号。
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：查记录
- 结构功能：开篇。
- 场景动作：主角翻看三年前的投料单。
- 开篇钩子：宣称现榨的直播间后方没有一只水果。
- 故事承诺：主角将在亲情与真相之间做出不可退回的选择。
- 子事件：
  1. 主角读取投料单编号。
  2. 主角核对该批次的凭证。
- 情绪目标：自信到茫然。
- 因果链：读编号 -> 核凭证 -> 发现断档。
- 节尾钩子：断档。
## 第2节：再查记录
- 结构功能：升级。
- 承接上节：断档的投料单逼主角继续核对。
- 场景动作：主角查阅附件与回执。
- 子事件：
  1. 主角翻阅附件清单。
  2. 主角比对系统页面。
- 情绪目标：信任到动摇。
- 压力变化：从网络质疑转入档案核对。
- 因果链：翻附件 -> 比页面 -> 旧记录。
- 节尾钩子：旧记录。
## 第3节：我先认错
- 结构功能：高潮与结尾。
- 承接上节：旧记录迫使主角公开核对品牌承诺。
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

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  # 第1节和第2节各自都出现 narrative engine 缺口（不是只解释一节）。
  printf '%s' "$output" | jq -e '
    [.findings[] | select(.code == "section_narrative_engine_underfilled") | .section] as $sections
    | ($sections | index(1)) != null and ($sections | index(2)) != null
  ' || { echo "$output"; false; }
  # 每条 finding 都携带各自的小节号与缺失信号，不退化成"1-N 节都缺"的聚合文案。
  printf '%s' "$output" | jq -e '.findings[] | select(.code == "section_narrative_engine_underfilled" and .section == 1 and (.missing_signals | index("protagonist_choice")) != null)' || { echo "$output"; false; }
  printf '%s' "$output" | jq -e '.findings[] | select(.code == "section_narrative_engine_underfilled" and .section == 2 and (.missing_signals | index("protagonist_choice")) != null)' || { echo "$output"; false; }
}

@test "short outline accepts natural markdown heading blocks without repeating machine fields" {
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲

## 第1节｜触发
### 节奏定位
- 开场触发，建立私密表达被公开利用的故事承诺。
### 压力变化
- 起：林栖仍依赖夜语陪伴。
- 升：夜语说出只属于她的句式。
- 顶：她意识到这不是普通推荐。
### 场景动作
- 她保存屏幕记录。
- 她打开本地导出并比对时间。
### 可见阻力
- 她无法证明平台定向使用过自己的表达。
### 角色选择
- 她拒绝删除本地记录，开始保全证据。
### 本节兑现
- 第一份可核验的表达重合证据落地。
### 关系变化
- 她与夜语从依赖关系转为警惕关系。
### 代价
- 她失去唯一敢于倾诉的对象。
### 新钩子
- 第二天，城市广告出现相同错字。

## 第2节｜升级
### 节奏定位
- 公司和解与公开否认同时施压。
### 压力变化
- 起：私人怀疑进入公开场景。
- 升：法务要求她限时签字。
- 顶：和解金足以解决她的房租困境。
### 场景动作
- 她截取广告版本。
- 她当面把错字和导出记录摆给法务。
### 可见阻力
- 公司用匿名训练和用户协议否认定向利用。
### 角色选择
- 她拒绝保密和解并保存谈话录音。
### 本节兑现
- 广告错字与私密记录完成交叉验证。
### 核心爆点兑现
- 她证明这不是随机生成，而是对具体用户表达的定向利用。
### 决定性行动
- 她拒绝签字并把材料提交给独立审查方。
### 即时代价
- 公司公开质疑她炒作，她失去房租缓冲。
### 关系变化
- 她和公司从用户关系转为公开争议双方。
### 代价
- 她放弃立刻缓解房租的和解金。
### 新钩子
- 内部证人发来定向标注截图。

## 第3节｜结尾
### 节奏定位
- 制度回应与人物重新连接同时收束。
### 压力变化
- 起：内部截图仍可能被公司否认。
- 升：她实名提交全部证据。
- 顶：公开调查迫使平台回应。
### 场景动作
- 她完成证据目录并公开提交。
- 平台下架广告并启动独立调查。
### 可见阻力
- 调查结果不会立刻公布，她仍要承担失业和舆论压力。
### 角色选择
- 她接受不附带沉默条件的赔偿并删除对话日志。
### 本节兑现（事实层 / 权力层 / 人物层）
- 广告下架、调查启动，她第一次向真人朋友说出恐惧。
### 关系变化
- 她不与前男友复合，重新向朋友建立真实连接。
### 主题回扣
- 理解一个人不等于拥有和出售她的脆弱。
### 代价
- 她失去三个月的 AI 对话，也没有立刻翻身。
### 新钩子
- 不留续作悬念，故事停在她主动拨出的电话上。

## 跨节承接
- 1 → 2：城市广告把私人怀疑推入公开冲突。
- 2 → 3：内部截图把公开争议推进制度调查。
EOF

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "current" and .narrative_quality.status == "pass"' || { echo "$output"; false; }
}

@test "section outline contract inherits opening promise from setting and accepts new hook heading" {
  cat > "$BOOK/设定.md" <<'EOF'
# 设定
- 叙事方式：第一人称女主有限视角。
- 主节奏：私密表达被公开利用 -> 证据闭环 -> 制度回应。

## 故事承诺
主角要证明只对 AI 说过的私密倾诉被定向用于公开广告，并夺回自己表达的使用权。

## 主要人物
### 林栖，29岁，女主
第一人称“我”。她要证明自己的私密倾诉被定向使用，最怕自己的脆弱变成商品。
EOF
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲

## 第 1 节｜触发

### 节奏定位
- 开场触发，建立私密表达被公开利用的惊惧。

### 压力变化
- 起：林栖仍依赖夜语陪伴。
- 升：夜语说出只属于她的句式。
- 顶：她意识到这不是普通推荐。

### 场景动作
- 她保存屏幕记录。
- 她打开本地导出并比对时间。

### 可见阻力
- 她无法证明平台定向使用过自己的表达。

### 角色选择
- 她拒绝删除本地记录，开始保全证据。

### 本节兑现
- 第一份可核验的表达重合证据落地。

### 关系变化
- 她与夜语从依赖关系转为警惕关系。

### 代价
- 她失去唯一敢于倾诉的对象。

### 新钩子
- 第二天，城市广告出现相同错字。

## 第 2 节｜公开撞击
### 节奏定位
- 公司和解与公开否认同时施压。
### 压力变化
- 起：私人怀疑进入公开场景。
- 升：法务要求她限时签字。
- 顶：和解金足以解决她的房租困境。
### 场景动作
- 她截取广告版本。
- 她当面把错字和导出记录摆给法务。
### 可见阻力
- 公司用匿名训练和用户协议否认定向利用。
### 角色选择
- 她拒绝保密和解并保存谈话录音。
### 本节兑现
- 广告错字与私密记录完成交叉验证。
### 核心爆点兑现
- 她证明这不是随机生成，而是对具体用户表达的定向利用。
### 决定性行动
- 她拒绝签字并把材料提交给独立审查方。
### 即时代价
- 公司公开质疑她炒作，她失去房租缓冲。
### 关系变化
- 她和公司从用户关系转为公开争议双方。
### 代价
- 她放弃立刻缓解房租的和解金。
### 新钩子
- 内部证人发来定向标注截图。

## 第 3 节｜制度回应
### 节奏定位
- 制度回应与人物重新连接同时收束。
### 压力变化
- 起：内部截图仍可能被公司否认。
- 升：她实名提交全部证据。
- 顶：公开调查迫使平台回应。
### 场景动作
- 她完成证据目录并公开提交。
- 平台下架广告并启动独立调查。
### 可见阻力
- 调查结果不会立刻公布，她仍要承担失业和舆论压力。
### 角色选择
- 她接受不附带沉默条件的赔偿并删除对话日志。
### 本节兑现
- 广告下架、调查启动，她第一次向真人朋友说出恐惧。
### 关系变化
- 她不与前男友复合，重新向朋友建立真实连接。
### 主题回扣
- 理解一个人不等于拥有和出售她的脆弱。
### 代价
- 她失去三个月的 AI 对话，也没有立刻翻身。
### 新钩子
- 不留续作悬念，故事停在她主动拨出的电话上。

## 跨节承接
- 1 → 2：城市广告把私人怀疑推入公开冲突。
- 2 → 3：内部截图把公开争议推进制度调查。
EOF

  run node - "$REPO_ROOT/scripts/lib/short-section-outline-contract.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const root=process.argv[3];
const result=api.buildShortSectionOutlineContract(root,1);
if(result.status!=='current') throw new Error(JSON.stringify(result));
if(result.section_title!=='触发') throw new Error(JSON.stringify(result));
if(!result.obligations.some(item=>item.id==='H01' && /城市广告/.test(item.source_text))) throw new Error(JSON.stringify(result));
NODE

  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "canonical outline labels take precedence over earlier explanatory aliases" {
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲

## 第1节：先留下证据
**开篇钩（opening_hook）**：她发现私密表达出现在公开广告里。
**场景动作**：她保存广告与聊天导出。
**主角选择**：她决定继续查证。
**因果事件（causal_events）**：发现广告 → 保存证据 → 拒绝删除软件。
**情绪目标**：震惊转为警觉。
### 1.5 停顿钩（旧说明）
**停顿钩**：她睡不着，手里仍握着手机。
- 节尾钩子：她无法证明来源，却再也不能把它当成巧合。

## 第2节：公开证据出现
**接力入（旧说明）**：她从地铁口的另一条广告开始调查。
**场景动作**：她对照广告错字与聊天导出。
**主角选择**：她拒绝签署保密和解。
**可见阻力**：公司法务要求她限时签字。
**本节兑现**：广告错字与私密对话完全一致。
**关系变化**：她与公司成为公开争议双方。
**代价升级**：她放弃可以缓解房租的和解金。
**核心承诺兑现**：她确认私密表达已被商品化。
**决定性动作**：她保存公开广告版本并联系审查方。
**即时代价**：她失去房租缓冲。
**因果事件（causal_events）**：看见广告 → 对照错字 → 收到和解函 → 拒绝签字。
- 承接上节：她无法证明来源，却再也不能把它当成巧合；公开广告给了她新的核验入口。
- 节尾钩子：公司声明内容只来自匿名训练数据。

## 第3节：证据进入制度流程
**接力入（handoff_in）**：公司声明内容只来自匿名训练数据，逼她寻找内部证据。
**场景动作**：她交叉核对内部截图、广告版本与本地导出。
**主角选择**：她只提交能够核验的证据。
**现实后果**：广告停投，监管介入。
**关系收束**：她没有与前任复合。
**主题回扣**：理解不等于拥有和出售。
**因果事件（causal_events）**：内部证据到手 → 交叉验证 → 公开提交 → 制度回应。
**节尾钩子**：她主动给朋友打电话。
EOF

  run node "$SCRIPT" check --project-root "$BOOK" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '([.findings[] | select(.code == "section_hook_handoff_disconnected")] | length) == 0' || { echo "$output"; false; }
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
