#!/usr/bin/env bats
# tests/test-oh-story-bundle.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    BUNDLE="$REPO/skills/novel-assistant"
    SOURCE_ROOT="$REPO/src/internal-skills"
    README="$REPO/README.md"
    README_EN="$REPO/README_EN.md"
}

@test "novel-assistant is the default single installable skill directory" {
    test -f "$BUNDLE/SKILL.md"
    grep -q "^name: novel-assistant" "$BUNDLE/SKILL.md"
    grep -q "/novel-assistant" "$BUNDLE/SKILL.md"
    test -f "$BUNDLE/references/internal-skills/story/SKILL.md"
    test -x "$BUNDLE/scripts/story-project-migrate.js"
    test -x "$BUNDLE/scripts/story-expansion-plan.js"
    test -x "$BUNDLE/scripts/story-progress-status.js"
    test -x "$BUNDLE/scripts/story-domain-profile.js"
    test -x "$BUNDLE/scripts/novel-assistant-project-smoke.js"
    test -x "$BUNDLE/scripts/chapter-assets-build.js"
    test -x "$BUNDLE/scripts/cross-volume-handoff-pack.sh"
    test -x "$BUNDLE/scripts/cross-volume-continuity-audit.sh"
    test -x "$BUNDLE/scripts/publish-export.js"
    test -x "$BUNDLE/scripts/novel-assistant-update-check.js"
    test -x "$BUNDLE/scripts/write-failure-triage.js"
    test -x "$BUNDLE/scripts/context-assembler.js"
    test -x "$BUNDLE/scripts/memory-recommender.js"
    test -x "$BUNDLE/scripts/word-count-tolerance.js"
    test -x "$BUNDLE/scripts/prose-quality-benchmark.js"
    test -x "$BUNDLE/scripts/detail-outline-quality-check.js"
    test -f "$BUNDLE/scripts/lib/detail-outline-quality.js"
    test -f "$BUNDLE/scripts/lib/detail-outline-quality-projection.js"
    test -f "$BUNDLE/references/internal-skills/story-long-write/references/detail-outline-quality-gate.md"
    test -f "$BUNDLE/novel-assistant-manifest.json"
}

@test "novel-assistant contains every source module as an internal subset" {
    for module in \
        story \
        story-workflow \
        story-memory \
        story-long-write \
        story-short-write \
        story-long-analyze \
        story-short-analyze \
        story-long-scan \
        story-short-scan \
        story-deslop \
        story-cover \
        story-import \
        story-review \
        story-setup \
        browser-cdp
    do
        test -f "$BUNDLE/references/internal-skills/$module/SKILL.md"
        test -f "$SOURCE_ROOT/$module/SKILL.md"
    done
}

@test "novel-assistant bundle carries progressive workflow protocols and size budgets" {
    source_workflow="$SOURCE_ROOT/story-workflow/SKILL.md"
    bundle_workflow="$BUNDLE/references/internal-skills/story-workflow/SKILL.md"

    [ "$(wc -l < "$source_workflow")" -lt 800 ]
    [ "$(wc -l < "$bundle_workflow")" -lt 800 ]
    [ "$(wc -l < "$BUNDLE/SKILL.md")" -lt 260 ]

    for protocol in \
        task-inbox-protocol.md \
        runner-execution-protocol.md \
        canonical-write-protocol.md \
        completion-evidence-protocol.md
    do
        source_protocol="$SOURCE_ROOT/story-workflow/references/$protocol"
        bundle_protocol="$BUNDLE/references/internal-skills/story-workflow/references/$protocol"

        grep -q "$protocol" "$source_workflow"
        grep -q "$protocol" "$bundle_workflow"
        test -f "$source_protocol"
        test -f "$bundle_protocol"
        cmp -s "$source_protocol" "$bundle_protocol"
    done

    grep -q "chapter-commit.js prepare" "$BUNDLE/references/internal-skills/story-workflow/references/canonical-write-protocol.md"
    grep -q "短篇单节写作" "$BUNDLE/references/internal-skills/story-workflow/references/canonical-write-protocol.md"
    grep -q "workflow-task-inbox.js" "$BUNDLE/references/internal-skills/story-workflow/references/task-inbox-protocol.md"
    grep -q "workflow-runner.js" "$BUNDLE/references/internal-skills/story-workflow/references/runner-execution-protocol.md"
    grep -q "可信产物、预期产物与恢复" "$BUNDLE/references/internal-skills/story-workflow/references/completion-evidence-protocol.md"
}

@test "novel-assistant bundles private internal modules for internal installs" {
    private_source=""
    for private_dir in "$SOURCE_ROOT"/../private-internal-skills/*; do
        if [ -f "$private_dir/SKILL.md" ]; then
            private_source="$private_dir"
            break
        fi
    done
    [ -n "$private_source" ]
    private_name="$(basename "$private_source")"
    test -f "$private_source/SKILL.md"
    test -f "$BUNDLE/references/private-internal-skills/$private_name/SKILL.md"
    count="$(node -e "console.log(require('$BUNDLE/novel-assistant-manifest.json').privateInternalSkillCount || 0)")"
    [ "$count" -ge 1 ]
}

@test "novel-assistant bundles short planning and brief runtime guards" {
    for script in short-brief-freshness.js short-plan-contract.js short-review-entry.js short-prose-entry-guard.js; do
        test -f "$BUNDLE/scripts/$script"
    done
}

@test "private shortform extension owns broad short writing startup route" {
    private_source="$SOURCE_ROOT/../private-internal-skills/private-short-extension"
    private_name="$(basename "$private_source")"
    source_route="$private_source/references/novel-assistant-private-route.md"
    bundle_route="$BUNDLE/references/private-internal-skills/$private_name/references/novel-assistant-private-route.md"

    test -f "$source_route"
    test -f "$bundle_route"

    for route_file in "$source_route" "$bundle_route"; do
        grep -q "开始短篇写作" "$route_file"
        grep -q "开短篇" "$route_file"
        grep -q "写短篇" "$route_file"
        grep -q "短篇写作启动菜单" "$route_file"
        grep -q "新项目启动菜单" "$route_file"
        grep -q "有可恢复短篇时" "$route_file"
        grep -q "没有可恢复短篇时" "$route_file"
        grep -q "不得显示.*检查未完成短篇项目" "$route_file"
        grep -q "抓取或学习新鲜素材" "$route_file"
        grep -q "从已有素材开写" "$route_file"
        grep -q "审阅或回炉已有短篇" "$route_file"
        grep -q "独立短篇项目" "$route_file"
        grep -q "不覆盖" "$route_file"
        grep -q "同名冲突" "$route_file"
        grep -q "无需二次确认" "$route_file"
        grep -q "不要再次询问" "$route_file"
        grep -q "脑洞卡片" "$route_file"
        grep -q "6-10" "$route_file"
        grep -q "Evidence Gate" "$route_file"
        grep -q "workflow-registry.json" "$route_file"
        grep -q "owner_module=private-short-extension" "$route_file"
        grep -q "migration-only legacy name" "$route_file"
        grep -q "brainstorm_card_pool" "$route_file"
        grep -q "short_draft_editor" "$route_file"
        grep -q "不要凭记忆" "$route_file"
        grep -q "短篇正文修订分流" "$route_file"
        grep -q "人物反应不真实" "$route_file"
        grep -q "不要把这类问题说成普通精修" "$route_file"
    done

    # The public router must not send a local/private short-form request through
    # the public writer or scanner before checking the private registry.
    router="$SOURCE_ROOT/story/SKILL.md"
    grep -q "不得先执行或推荐.*story-short-write.*story-short-scan" "$router"
    grep -q "短篇素材学习/脑洞/精修" "$router"
    grep -q "先获取并学习近期公开资讯" "$router"
    grep -q "直接进入.*info_source_pool" "$router"

    for registry in \
        "$private_source/workflow-registry.json" \
        "$BUNDLE/references/private-internal-skills/$private_name/workflow-registry.json"
    do
        grep -q '"workflow_type": "short_write"' "$registry"
        grep -q '"target_workflow_type": "short_write"' "$registry"
        grep -q '"stage_id": "startup_scan"' "$registry"
        grep -q '"stage_id": "material_learning"' "$registry"
        grep -q '"stage_id": "project_seed"' "$registry"
        grep -q '"stage_id": "short_setting"' "$registry"
        grep -q '"stage_id": "platform_genre_lock"' "$registry"
        grep -q '"stage_id": "rhythm_pattern_selection"' "$registry"
        grep -q '"stage_id": "section_outline"' "$registry"
        grep -q '"stage_id": "hook_retention_gate"' "$registry"
        grep -q '"stage_id": "first_section_brief"' "$registry"
        grep -q '"stage_id": "draft_first_section"' "$registry"
        grep -q '"stage_id": "next_section_brief"' "$registry"
        grep -q '"frontend_surface": "brainstorm_card_pool"' "$registry"
        grep -q '"frontend_surface": "short_quality_panel"' "$registry"
        grep -q '"frontend_surface": "short_brief_view"' "$registry"
        grep -q '"frontend_surface": "short_draft_editor"' "$registry"
    done
}

@test "private shortform material learning stops at card selection gate" {
    private_source="$SOURCE_ROOT/../private-internal-skills/private-short-extension"
    private_name="$(basename "$private_source")"
    source_route="$private_source/references/novel-assistant-private-route.md"
    bundle_route="$BUNDLE/references/private-internal-skills/$private_name/references/novel-assistant-private-route.md"

    for registry in \
        "$private_source/workflow-registry.json" \
        "$BUNDLE/references/private-internal-skills/$private_name/workflow-registry.json"
    do
        node - "$registry" <<'NODE'
const fs = require('fs');
const registry = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const tmpl = registry.workflow_templates.find(t => t.workflow_type === 'short_write');
const stage = id => tmpl.stages.find(s => s.stage_id === id);
	const material = stage('material_learning');
	const project = stage('project_seed');
	const setting = stage('short_setting');
	const platformGenreLock = stage('platform_genre_lock');
	const rhythm = stage('rhythm_pattern_selection');
const outline = stage('section_outline');
const planLock = stage('section_plan_lock');
const impactAudit = stage('short_structure_impact_audit');
const hook = stage('hook_retention_gate');
const firstBrief = stage('first_section_brief');
const draft = stage('draft_first_section');
const machineGate = stage('section_machine_gate');
const repairLoop = stage('section_repair_loop');
const gate = stage('quality_gate');
const compare = stage('section_candidate_compare');
const anchor = stage('section_accept_anchor');
const nextBrief = stage('next_section_brief');
const nextDraft = stage('draft_next_section');
	if (!material || !project || !setting || !platformGenreLock || !rhythm || !outline || !planLock || !impactAudit || !hook || !firstBrief || !draft || !machineGate || !repairLoop || !gate || !compare || !anchor || !nextBrief || !nextDraft) process.exit(1);
if (material.requires_user_confirm !== true) process.exit(2);
if (JSON.stringify(material.allowed_next) !== JSON.stringify(['project_seed'])) process.exit(3);
	if (project.requires_user_confirm !== true) process.exit(4);
	if (!setting.required_inputs.includes('project_seed')) process.exit(5);
	if (!setting.allowed_next.includes('platform_genre_lock')) process.exit(6);
	if (!platformGenreLock.required_inputs.includes('short_setting')) process.exit(38);
	if (!platformGenreLock.allowed_next.includes('rhythm_pattern_selection')) process.exit(39);
	if (platformGenreLock.requires_user_confirm !== true) process.exit(40);
	if (!rhythm.required_inputs.includes('platform_genre_lock')) process.exit(28);
	if (!rhythm.allowed_next.includes('section_outline')) process.exit(29);
	if (rhythm.requires_user_confirm !== true) process.exit(30);
	if (!rhythm.description.includes('节奏') || !rhythm.description.includes('爽点') || !rhythm.description.includes('打脸') || !rhythm.description.includes('反转') || !rhythm.description.includes('火葬场')) process.exit(31);
	if (!outline.required_inputs.includes('rhythm_pattern_selection')) process.exit(32);
	if (!outline.allowed_next.includes('section_plan_lock')) process.exit(33);
	if (!planLock.required_inputs.includes('section_outline')) process.exit(34);
	if (!planLock.allowed_next.includes('short_structure_impact_audit')) process.exit(35);
	if (!impactAudit.required_inputs.includes('section_plan_lock')) process.exit(36);
	if (!impactAudit.allowed_next.includes('hook_retention_gate')) process.exit(37);
	if (!hook.required_inputs.includes('short_structure_impact_audit')) process.exit(7);
if (!hook.allowed_next.includes('first_section_brief')) process.exit(8);
if (!firstBrief.required_inputs.includes('hook_retention_gate')) process.exit(9);
if (!draft.required_inputs.includes('first_section_brief')) process.exit(10);
if (!draft.allowed_next.includes('section_machine_gate')) process.exit(11);
if (!machineGate.required_inputs.includes('current_section_draft')) process.exit(12);
if (!machineGate.description.includes('short-section-machine-gate.js') || !machineGate.description.includes('统一门检') || !machineGate.description.includes('不得拆开调用检查器')) process.exit(13);
if (!machineGate.allowed_next.includes('quality_gate')) process.exit(14);
if (!machineGate.allowed_next.includes('section_repair_loop')) process.exit(15);
if (!repairLoop.required_inputs.includes('section_machine_gate')) process.exit(16);
if (!repairLoop.allowed_next.includes('section_machine_gate')) process.exit(17);
if (!gate.required_inputs.includes('section_machine_gate')) process.exit(18);
if (gate.allowed_next.includes('next_section_brief')) process.exit(19);
if (!gate.allowed_next.includes('section_candidate_compare')) process.exit(20);
if (!compare.required_inputs.includes('quality_gate')) process.exit(21);
if (!compare.allowed_next.includes('section_accept_anchor')) process.exit(22);
if (!anchor.required_inputs.includes('quality_gate')) process.exit(23);
if (!anchor.allowed_next.includes('next_section_brief')) process.exit(24);
if (!nextBrief.required_inputs.includes('section_accept_anchor')) process.exit(25);
if (!nextDraft.required_inputs.includes('next_section_brief')) process.exit(26);
if (!nextDraft.allowed_next.includes('section_machine_gate')) process.exit(27);
NODE
    done

    for route_file in "$source_route" "$bundle_route"; do
        grep -q "卡片选择门禁" "$route_file"
        grep -q "停在脑洞卡池" "$route_file"
        grep -q "卡池分析" "$route_file"
        grep -q "横向对比" "$route_file"
        grep -q "推荐排序" "$route_file"
        grep -q "选择单张卡片" "$route_file"
        grep -q "回复选 N" "$route_file"
        grep -q "未选择脑洞卡" "$route_file"
        grep -q "不得进入设定" "$route_file"
        grep -q "不得进入小节大纲" "$route_file"
        grep -q "不得进入正文" "$route_file"
        grep -q "只显示卡片选择候选" "$route_file"
        grep -q "多选" "$route_file"
        ! grep -q "选第 1 张" "$route_file"
    done
}

@test "private shortform extension absorbs public short writer craft references" {
    private_source="$SOURCE_ROOT/../private-internal-skills/private-short-extension"
    private_name="$(basename "$private_source")"
    source_absorbed="$private_source/references/absorbed-story-short-write"
    bundle_absorbed="$BUNDLE/references/private-internal-skills/$private_name/references/absorbed-story-short-write"
    source_skill="$private_source/SKILL.md"
    bundle_skill="$BUNDLE/references/private-internal-skills/$private_name/SKILL.md"
    source_bridge="$private_source/references/story-short-write-bridge.md"
    bundle_bridge="$BUNDLE/references/private-internal-skills/$private_name/references/story-short-write-bridge.md"

	    for absorbed_dir in "$source_absorbed" "$bundle_absorbed"; do
	        test -f "$absorbed_dir/short-format.md"
	        test -f "$absorbed_dir/short-craft.md"
	        test -f "$absorbed_dir/short-rhythm-patterns.md"
	        test -f "$absorbed_dir/short-deslop.md"
        test -f "$absorbed_dir/human-resonance-gate.md"
        test -f "$absorbed_dir/writing-workflow.md"
        test -f "$absorbed_dir/quality-checklist.md"
        test -f "$absorbed_dir/genre-writing-formulas.md"
        test -f "$absorbed_dir/genre-styles/复仇打脸.md"
        test -f "$absorbed_dir/genre-styles/追妻火葬场.md"
        grep -q "连续短段" "$absorbed_dir/writing-workflow.md"
        grep -q "short-paragraph-fragmentation" "$absorbed_dir/writing-workflow.md"
        grep -q "短段有呼吸" "$absorbed_dir/short-deslop.md"
        grep -q "当前小节重写" "$absorbed_dir/short-deslop.md"
    done

    for bridge_file in "$source_bridge" "$bundle_bridge"; do
        grep -q "absorbed-story-short-write" "$bridge_file"
	        grep -q "short-format.md" "$bridge_file"
	        grep -q "short-craft.md" "$bridge_file"
	        grep -q "short-rhythm-patterns.md" "$bridge_file"
	        grep -q "short-deslop.md" "$bridge_file"
        grep -q "不再依赖公开 story-short-write 运行时" "$bridge_file"
    done

    for skill_file in "$source_skill" "$bundle_skill"; do
        grep -q "absorbed-story-short-write" "$skill_file"
	        grep -q "short-format" "$skill_file"
	        grep -q "short-rhythm-patterns" "$skill_file"
	        grep -q "short-deslop" "$skill_file"
        grep -q "human-resonance" "$skill_file"
        grep -q "genre styles" "$skill_file"
    done
}

@test "shortform writing requires character lock and plot feasibility gates" {
    public_source="$SOURCE_ROOT/story-short-write"
    public_bundle="$BUNDLE/references/internal-skills/story-short-write"
    private_source="$SOURCE_ROOT/../private-internal-skills/private-short-extension"
    private_name="$(basename "$private_source")"
    private_absorbed="$private_source/references/absorbed-story-short-write"
    bundle_absorbed="$BUNDLE/references/private-internal-skills/$private_name/references/absorbed-story-short-write"
    source_bridge="$private_source/references/story-short-write-bridge.md"
    bundle_bridge="$BUNDLE/references/private-internal-skills/$private_name/references/story-short-write-bridge.md"

    for dir in "$public_source/references" "$public_bundle/references" "$private_absorbed" "$bundle_absorbed"; do
        test -f "$dir/short-logic-gate.md"
        test -f "$dir/human-resonance-gate.md"
        grep -q "角色锁定卡" "$dir/short-logic-gate.md"
        grep -q "性别/称谓/视角身份" "$dir/short-logic-gate.md"
        grep -q "情节可行性门" "$dir/short-logic-gate.md"
        grep -q "巧合预算" "$dir/short-logic-gate.md"
        grep -q "主题防漂移" "$dir/short-logic-gate.md"
        grep -q "丰满度门" "$dir/short-logic-gate.md"
        grep -q "人性共鸣" "$dir/human-resonance-gate.md"
        grep -q "关系压力" "$dir/human-resonance-gate.md"
        grep -q "生活物件" "$dir/human-resonance-gate.md"
        grep -q "选择代价" "$dir/human-resonance-gate.md"
    done

    for skill_file in "$public_source/SKILL.md" "$public_bundle/SKILL.md"; do
        grep -q "short-logic-gate.md" "$skill_file"
        grep -q "角色锁定卡" "$skill_file"
        grep -q "情节可行性门" "$skill_file"
    done

    for bridge_file in "$source_bridge" "$bundle_bridge"; do
        grep -q "short-logic-gate.md" "$bridge_file"
        grep -q "角色锁定卡" "$bridge_file"
        grep -q "情节可行性门" "$bridge_file"
    done
}

@test "private shortform absorption is maintained by sync script" {
    script="$REPO/scripts/sync-private-short-write-absorption.js"
    out="$(mktemp)"

    test -x "$script"
    node "$script" --repo-root "$REPO" --check --json > "$out"
    grep -q '"status":"ok"' "$out"
    grep -q '"mode":"public_and_private_short_write_sync"' "$out"
    grep -q '"publicTarget"' "$out"
    grep -q '"bundlePublicTarget"' "$out"
    grep -q '"privateTarget"' "$out"
    grep -q 'absorbed-story-short-write' "$out"
}

@test "platform profile and six clean-room cards stay aligned across public and private bundles" {
    public_source="$SOURCE_ROOT/story-short-write/references"
    public_bundle="$BUNDLE/references/internal-skills/story-short-write/references"
    private_source="$SOURCE_ROOT/../private-internal-skills/private-short-extension/references/absorbed-story-short-write"
    private_bundle="$BUNDLE/references/private-internal-skills/private-short-extension/references/absorbed-story-short-write"

    for root in "$public_source" "$public_bundle" "$private_source" "$private_bundle"; do
        test -f "$root/submission-profile.md"
        for name in 世情打脸 民俗怪谈 悬疑 甜宠 双男主 沙雕脑洞; do
            test -f "$root/genre-styles/$name.md"
            cmp "$public_source/genre-styles/$name.md" "$root/genre-styles/$name.md"
        done
        cmp "$public_source/submission-profile.md" "$root/submission-profile.md"
    done
}

@test "short write upstream sync updates public module and private absorption" {
    script="$REPO/scripts/sync-private-short-write-absorption.js"
    upstream="$(mktemp -d)"
    sandbox="$(mktemp -d)"

    mkdir -p "$upstream/src/internal-skills/story-short-write/references" "$upstream/src/internal-skills/story-short-write/scripts"
    cat > "$upstream/src/internal-skills/story-short-write/SKILL.md" <<'MD'
---
name: story-short-write
description: upstream short write sentinel
---
# upstream story-short-write sentinel
MD
    echo "upstream craft sentinel" > "$upstream/src/internal-skills/story-short-write/references/upstream-craft.md"
    echo "console.log('upstream tool sentinel')" > "$upstream/src/internal-skills/story-short-write/scripts/upstream-tool.js"
    git -C "$upstream" init -q -b main
    git -C "$upstream" config user.email "test@example.com"
    git -C "$upstream" config user.name "Test"
    git -C "$upstream" add .
    git -C "$upstream" commit -q -m "fixture upstream short write"

    mkdir -p \
        "$sandbox/src/internal-skills/story-short-write/references" \
        "$sandbox/skills/novel-assistant/references/internal-skills/story-short-write/references" \
        "$sandbox/src/private-internal-skills/private-short-extension/references/absorbed-story-short-write" \
        "$sandbox/skills/novel-assistant/references/private-internal-skills/private-short-extension/references/absorbed-story-short-write"
    echo "old public" > "$sandbox/src/internal-skills/story-short-write/SKILL.md"
    echo "old bundle public" > "$sandbox/skills/novel-assistant/references/internal-skills/story-short-write/SKILL.md"
    echo "local public extension" > "$sandbox/src/internal-skills/story-short-write/references/local-extension.md"
    echo "private" > "$sandbox/src/private-internal-skills/private-short-extension/SKILL.md"
    echo "local private extension" > "$sandbox/src/private-internal-skills/private-short-extension/references/absorbed-story-short-write/local-private-extension.md"
    echo "private bundle" > "$sandbox/skills/novel-assistant/references/private-internal-skills/private-short-extension/SKILL.md"

    node "$script" --repo-root "$sandbox" --upstream-repo "$upstream" --upstream-ref main --json > "$sandbox/out.json"

    grep -q '"status":"synced"' "$sandbox/out.json"
    grep -q "upstream story-short-write sentinel" "$sandbox/src/internal-skills/story-short-write/SKILL.md"
    grep -q "upstream story-short-write sentinel" "$sandbox/skills/novel-assistant/references/internal-skills/story-short-write/SKILL.md"
    grep -q "upstream craft sentinel" "$sandbox/src/internal-skills/story-short-write/references/upstream-craft.md"
    grep -q "upstream craft sentinel" "$sandbox/skills/novel-assistant/references/internal-skills/story-short-write/references/upstream-craft.md"
    grep -q "upstream craft sentinel" "$sandbox/src/private-internal-skills/private-short-extension/references/absorbed-story-short-write/upstream-craft.md"
    grep -q "upstream craft sentinel" "$sandbox/skills/novel-assistant/references/private-internal-skills/private-short-extension/references/absorbed-story-short-write/upstream-craft.md"
    test -f "$sandbox/src/internal-skills/story-short-write/references/local-extension.md"
    test -f "$sandbox/src/private-internal-skills/private-short-extension/references/absorbed-story-short-write/local-private-extension.md"
    test -f "$sandbox/src/internal-skills/story-short-write/scripts/upstream-tool.js"
    test -f "$sandbox/skills/novel-assistant/references/internal-skills/story-short-write/scripts/upstream-tool.js"
    ! test -f "$sandbox/src/private-internal-skills/private-short-extension/references/absorbed-story-short-write/scripts/upstream-tool.js"
}

@test "short write upstream sync writes readable drift report" {
    script="$REPO/scripts/sync-private-short-write-absorption.js"
    upstream="$(mktemp -d)"
    sandbox="$(mktemp -d)"
    report_dir="$sandbox/reports"

    mkdir -p "$upstream/src/internal-skills/story-short-write/references"
    cat > "$upstream/src/internal-skills/story-short-write/SKILL.md" <<'MD'
---
name: story-short-write
description: upstream report sentinel
---
# upstream report sentinel
MD
    echo "upstream report craft" > "$upstream/src/internal-skills/story-short-write/references/report-craft.md"
    git -C "$upstream" init -q -b main
    git -C "$upstream" config user.email "test@example.com"
    git -C "$upstream" config user.name "Test"
    git -C "$upstream" add .
    git -C "$upstream" commit -q -m "fixture upstream report"

    mkdir -p \
        "$sandbox/src/internal-skills/story-short-write/references" \
        "$sandbox/skills/novel-assistant/references/internal-skills/story-short-write/references" \
        "$sandbox/src/private-internal-skills/private-short-extension/references/absorbed-story-short-write" \
        "$sandbox/skills/novel-assistant/references/private-internal-skills/private-short-extension/references/absorbed-story-short-write"
    echo "old public" > "$sandbox/src/internal-skills/story-short-write/SKILL.md"
    echo "old bundle public" > "$sandbox/skills/novel-assistant/references/internal-skills/story-short-write/SKILL.md"
    echo "local public extension" > "$sandbox/src/internal-skills/story-short-write/references/local-extension.md"
    echo "private" > "$sandbox/src/private-internal-skills/private-short-extension/SKILL.md"
    echo "local private extension" > "$sandbox/src/private-internal-skills/private-short-extension/references/absorbed-story-short-write/local-private-extension.md"
    echo "private bundle" > "$sandbox/skills/novel-assistant/references/private-internal-skills/private-short-extension/SKILL.md"

    set +e
    node "$script" --repo-root "$sandbox" --upstream-repo "$upstream" --upstream-ref main --check --report-dir "$report_dir" --json > "$sandbox/out.json"
    status="$?"
    set -e
    [ "$status" -eq 1 ]

    report="$(find "$report_dir" -type f -name '*short-write-sync.md' | head -1)"
    [ -n "$report" ]
    grep -q "Short Write Upstream Sync Report" "$report"
    grep -q "publicTarget" "$report"
    grep -q "privateTarget" "$report"
    grep -q "report-craft.md" "$report"
    grep -q "local-extension.md" "$report"
    grep -q "local-private-extension.md" "$report"
    grep -q "默认保留本地 extra" "$report"
}

@test "private novel download extension is bundled only for internal installs" {
    private_source="$SOURCE_ROOT/../private-internal-skills/private-download-extension"
    source_route="$private_source/references/novel-assistant-private-route.md"
    bundle_private="$BUNDLE/references/private-internal-skills/private-download-extension"
    bundle_route="$bundle_private/references/novel-assistant-private-route.md"

    test -f "$private_source/SKILL.md"
    test -f "$private_source/scripts/novel_download.py"
    test -f "$private_source/references/workflow.md"
    test -f "$source_route"

    test -f "$bundle_private/SKILL.md"
    test -f "$bundle_private/scripts/novel_download.py"
    test -f "$bundle_private/references/workflow.md"
    test -f "$bundle_route"

    for route_file in "$source_route" "$bundle_route"; do
        grep -q "搜小说" "$route_file"
        grep -q "小说下载" "$route_file"
        grep -q "续更" "$route_file"
        grep -q "private-download-extension" "$route_file"
        grep -q "Do not publish" "$route_file"
    done
}

@test "novel-assistant bundles longform stability scripts" {
    for script in \
        chapter-index-build.sh \
        chapter-stability-check.sh \
        cross-chapter-continuity-audit.sh \
        cross-volume-handoff-pack.sh \
        cross-volume-continuity-audit.sh \
        longform-daily-stability-audit.sh \
        revision-impact-scan.sh \
        revision-stability-recheck.sh \
        story-progress-status.js \
        story-domain-profile.js \
        novel-assistant-project-smoke.js \
        long-analyze-plan.js \
        long-analyze-recovery-state.js \
        stage2-summary-quality-check.js \
        stage2-grounding-check.js \
        novel-assistant-update-check.js \
        novel-assistant-sync-runtime.js \
        write-failure-triage.js \
        normalize-punctuation.js \
        prose-quality-benchmark.js \
        check-ai-patterns.js \
        check-degeneration.js \
        stability-repair-loop.sh
    do
        test -x "$BUNDLE/scripts/$script"
    done
}

@test "novel-assistant bundles v0.8 protocol references and validators" {
    test -f "$BUNDLE/references/internal-skills/story-long-scan/references/v0-8-scan-data-protocol.md"
    test -f "$BUNDLE/references/internal-skills/story-short-scan/references/v0-8-scan-data-protocol.md"
    test -f "$BUNDLE/references/internal-skills/story-long-write/references/v0-8-story-schema.md"
    test -x "$BUNDLE/scripts/scan-json-validate.js"
    test -x "$BUNDLE/scripts/story-schema-validate.js"
}

@test "novel-assistant bundle carries startup routing workflow" {
    grep -q "开书引导路由" "$BUNDLE/references/internal-skills/story/SKILL.md"
    grep -q "workflow-startup.md" "$BUNDLE/references/internal-skills/story/SKILL.md"
    test -f "$BUNDLE/references/internal-skills/story-long-write/references/workflow-startup.md"
}

@test "novel-assistant internal module copies stay synced with source modules" {
    for module in \
        story \
        story-workflow \
        story-long-write \
        story-short-write \
        story-long-analyze \
        story-short-analyze \
        story-long-scan \
        story-short-scan \
        story-deslop \
        story-cover \
        story-import \
        story-review \
        story-setup \
        browser-cdp
    do
        cmp -s "$SOURCE_ROOT/$module/SKILL.md" "$BUNDLE/references/internal-skills/$module/SKILL.md"
    done
}

@test "short analyze teaches human resonance mechanisms to short write" {
    short_analyze="$SOURCE_ROOT/story-short-analyze"
    short_write="$SOURCE_ROOT/story-short-write"
    bundle_analyze="$BUNDLE/references/internal-skills/story-short-analyze"
    bundle_write="$BUNDLE/references/internal-skills/story-short-write"
    private_absorbed="$SOURCE_ROOT/../private-internal-skills/private-short-extension/references/absorbed-story-short-write"
    bundle_private_absorbed="$BUNDLE/references/private-internal-skills/private-short-extension/references/absorbed-story-short-write"

    for file in \
        "$short_analyze/SKILL.md" \
        "$bundle_analyze/SKILL.md" \
        "$short_analyze/references/output-templates.md" \
        "$bundle_analyze/references/output-templates.md"
    do
        grep -q "人性共鸣学习卡" "$file"
        grep -q "人物软肋" "$file"
        grep -q "关系压力" "$file"
        grep -q "生活物件" "$file"
        grep -q "选择代价" "$file"
    done

    for file in \
        "$short_analyze/references/output-contract.md" \
        "$short_write/references/output-contract.md" \
        "$bundle_analyze/references/output-contract.md" \
        "$bundle_write/references/output-contract.md" \
        "$private_absorbed/output-contract.md" \
        "$bundle_private_absorbed/output-contract.md"
    do
        grep -q "共鸣机制回收" "$file"
        grep -q "人性共鸣学习卡" "$file"
        grep -q "只迁移人物软肋、关系压力、生活物件、选择代价和情绪债的机制" "$file"
    done
}

@test "README documents single-directory installation" {
    grep -q "单目录安装" "$README"
    grep -q "skills/novel-assistant" "$README"
    grep -q "src/internal-skills" "$README"
    grep -q "~/.codex/skills/novel-assistant" "$README"
    grep -q ".claude/skills/novel-assistant" "$README"
    grep -q "https://github.com/duiniwukenaihe/novel-assistant-skill.git" "$README"
    ! grep -q "npx skills add worldwonderer/oh-story-claudecode" "$README"
    ! grep -q "更新时重新执行同一条命令即可" "$README"
}

@test "README explains upstream differences, production rationale, and correct usage" {
    grep -q "novel-assistant" "$README"
    grep -q "本项目更偏生产写作工作台" "$README"
    grep -q "上游只作为输入源" "$README"
    grep -q "长篇拆书中途等待继续" "$README"
    grep -q "source-grounding" "$README"
    grep -q "Trellis 启发的任务持久化" "$README"
    grep -q "任务需求与读者承诺文档" "$README"
    grep -q "spec / task / workspace journal" "$README"
    grep -q "Trellis-Inspired Task Persistence" "$README_EN"
    grep -q "Requirement and Reader Promise Document" "$README_EN"
    grep -q "正确使用方式" "$README"
    grep -q "/novel-assistant 准备写书" "$README"
    grep -q "/novel-assistant 继续拆" "$README"
    grep -q "不要直接调用 /story-long-write" "$README"
    ! grep -q "Star History" "$README"
    ! grep -q "Telegram 群" "$README"
    ! grep -q "GitHub Discussions" "$README"
    ! grep -q "这套 skill 现在能让我度过找工作的过渡期" "$README"
}
