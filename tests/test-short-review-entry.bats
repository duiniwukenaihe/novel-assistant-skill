#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/short-review-entry.js"
  STATE="$REPO/scripts/workflow-state-machine.js"
  BOOK="$(mktemp -d)/book"
  mkdir -p "$BOOK/追踪/private-short-extension"
  printf '# 素材卡\n\n故事核：直播翻车。\n' > "$BOOK/素材卡.md"
  printf '# 设定\n\n目标长度 3000 字，共 2 节。\n- 叙事方式：第一人称女主有限视角。\n- 主节奏：公开翻车 -> 查证 -> 承担后果。\n' > "$BOOK/设定.md"
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：谎言露馅
- 结构功能：开篇
- 场景动作：主角直播时镜头扫到空车间。
- 角色选择：她拒绝关播。
- 开篇钩子：现榨工厂没有水果。
- 故事承诺：她要查清家族生意的真相。
- 子事件：
  1. 她开播背书。
  2. 空车间暴露。
- 情绪目标：自信到惊疑。
- 因果链：背书 -> 开播 -> 露馅。
- 节尾钩子：哥哥命令她关播。
## 第2节：承担后果
- 结构功能：高潮与结尾
- 承接上节：哥哥逼她关播，她选择继续追问。
- 场景动作：她公开证据并启动召回。
- 角色选择：她承认自己的传播责任。
- 现实后果：停产、召回、退还报酬。
- 关系收束：她与家人决裂但不虚假和解。
- 主题回扣：只为自己核实过的事实背书。
- 子事件：
  1. 她公布证据。
  2. 召回真正落地。
- 情绪目标：恐惧到承担。
- 因果链：追问 -> 查证 -> 公开承担。
- 节尾钩子：责任落地。
EOF
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'EOF'
{"current_section_index":1,"narrative":{"planned_sections":2},"remaining_sections":[1,2]}
EOF
  printf '## 第1节\n正文一。\n\n## 第2节\n正文二。\n' > "$BOOK/正文.md"
}

teardown() {
  rm -rf "$(dirname "$BOOK")"
}

@test "short review entry binds professional review owner and allows prose only after plan contract" {
  run node "$SCRIPT" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "ready_for_professional_review" and .route_receipt.workflow_type == "short_review" and .route_receipt.owner_module == "story-review" and .full_prose_scan_allowed == true'
}

@test "short review entry continues read-only prose review when only the plan contract is risky" {
  perl -0pi -e 's/- 主题回扣：[^\n]*\n//' "$BOOK/小节大纲.md"
  run node "$SCRIPT" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .status == "ready_for_professional_review_with_plan_risk" and
    .next_action == "build_compact_review_plan" and
    .full_prose_scan_allowed == true and
    .plan_repair_checklist.blocking_for_drafting == true and
    .plan_repair_checklist.blocking_for_read_only_review == false and
    (.plan_repair_checklist.sections[] | select(.section == 2) | (.unresolved_signals | index("theme_callback")) != null)'
}

@test "short review entry blocks only when no reviewable prose exists" {
  rm "$BOOK/正文.md"
  run node "$SCRIPT" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "blocked_review_source_missing" and .full_prose_scan_allowed == false and .next_action == "locate_reviewable_prose"'
}

@test "short review workflow keeps professional review ownership" {
  run node "$STATE" templates --no-private-registry --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .templateCount == 15 and
    (.templates[] | select(.workflow_type == "short_review") | .stages
      | map(select(.owner_module == "story-review") | .stage_id)
      | index("plan_contract") != null and index("review_execute") != null and index("review_report") != null)'
}

@test "short review entry preserves private overlay identity from project sentinel" {
  printf 'novel_assistant_private_overlay: true\n' > "$BOOK/.story-deployed"
  run node "$SCRIPT" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.route_receipt.writing_context == "private_enhanced"'
}

@test "short review entry identifies legacy section tables instead of reporting zero sections" {
  cat > "$BOOK/设定.md" <<'EOF'
# 旧版短篇设定
体量：10000-13000 字，8 节连续故事。
EOF
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 旧版小节大纲
| 节 | 标题 | 功能 |
|---:|---|---|
| 1 | 开局 | 羞辱 |
| 2 | 升级 | 反查 |
| 3 | 反制 | 证据 |
| 4 | 交锋 | 压力 |
| 5 | 报价 | 爆点 |
| 6 | 破防 | 转折 |
| 7 | 清算 | 高潮 |
  | 8 | 收束 | 结尾 |
EOF
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'EOF'
{"current_section_index":1,"remaining_sections":[]}
EOF
  run node "$SCRIPT" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .status == "ready_for_professional_review_with_plan_risk" and
    .next_action == "build_compact_review_plan" and
    .review_scope.planned_sections == 8 and
    .review_scope.outlined_sections == [1,2,3,4,5,6,7,8] and
    .full_prose_scan_allowed == true and
    .plan_contract.findings[0].code == "legacy_plan_migration_required"'
}

@test "top-level skill documents deterministic short review fast path" {
  grep -q "短篇完整验收快速路径" "$REPO/skills/novel-assistant/SKILL.md"
  grep -q "ready_for_professional_review_with_plan_risk" "$REPO/skills/novel-assistant/SKILL.md"
  grep -q "不得为了确认路由先加载全部内部 Skill" "$REPO/skills/novel-assistant/SKILL.md"
}

@test "public skill and workflow share risk-mode review policy" {
  grep -q "ready_for_professional_review_with_plan_risk" "$REPO/src/internal-skills/story-short-write/SKILL.md"
  grep -q "规划格式或内容风险逐节记录，但不阻止只读正文审阅" "$REPO/scripts/lib/workflow-template-registry.js"
  ! grep -q "合同阻断时停止全文扫描" "$REPO/scripts/lib/workflow-template-registry.js"
}

@test "short review compact receipt aggregates repeated section findings" {
  perl -0pi -e 's/- 情绪目标：[^\n]*\n//g' "$BOOK/小节大纲.md"
  run node "$SCRIPT" --project-root "$BOOK" --json --compact
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    (.plan_contract.findings | map(select(.code == "section_blueprint_underfilled")) | length) == 1 and
    (.plan_contract.findings[] | select(.code == "section_blueprint_underfilled") | .sections) == [1,2] and
    (.plan_contract.findings[] | select(.code == "section_blueprint_underfilled") | .section_findings | map(.section)) == [1,2] and
    (.plan_repair_checklist.sections | map(.section)) == [1,2] and
    (.plan_contract | has("narrative_quality")) == false'
}
