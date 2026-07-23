#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/review-agent-dispatch-plan.js"
    REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    BUNDLE_MANIFEST="$REPO/config/novel-assistant-bundle-files.json"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "review agent dispatch planner selects deterministic lean and risk-driven roles" {
    node - "$REPO" <<'NODE'
const path = require('path');
const { planReviewRoles } = require(path.join(process.argv[2], 'scripts/lib/review-role-policy.js'));

const available = ['story-explorer', 'character-designer', 'narrative-writer', 'consistency-checker'];
const roleNames = (plan) => plan.roles.map((role) => role.subagent_type);

const lean = planReviewRoles({
  requiredDimensions: ['plot', 'canon'], evidenceSignals: [], availableAgents: available, budgetPolicy: {},
});
if (lean.mode !== 'agent_dispatch') throw new Error(lean.mode);
if (JSON.stringify(roleNames(lean)) !== JSON.stringify(['story-explorer', 'consistency-checker'])) throw new Error(JSON.stringify(lean));
if (lean.deferredDimensions.length !== 0) throw new Error(JSON.stringify(lean.deferredDimensions));

const character = planReviewRoles({
  requiredDimensions: ['plot', 'canon', 'character'], evidenceSignals: ['character_drift'], availableAgents: available, budgetPolicy: {},
});
if (!roleNames(character).includes('character-designer')) throw new Error(JSON.stringify(character));

const prose = planReviewRoles({
  requiredDimensions: ['plot', 'canon', 'prose'], evidenceSignals: ['prose'], availableAgents: available, budgetPolicy: {},
});
if (!roleNames(prose).includes('narrative-writer')) throw new Error(JSON.stringify(prose));

const conflict = planReviewRoles({
  requiredDimensions: ['plot', 'canon', 'prose'], evidenceSignals: ['high_conflict'], availableAgents: available, budgetPolicy: {},
});
if (JSON.stringify(roleNames(conflict)) !== JSON.stringify(['story-explorer', 'narrative-writer', 'consistency-checker'])) throw new Error(JSON.stringify(conflict));
if (conflict.retryPolicy !== 'missing_dimension_once') throw new Error(conflict.retryPolicy);
NODE
}

@test "review agent dispatch planner retains valid roles when an optional agent is missing" {
    node "$SCRIPT" --scope "1-3" --batch "1-3" --dimensions plot,canon,character --risk character_drift --agents-available story-explorer,consistency-checker --json > "$TMP_DIR/out-review-agent-plan.json"

    node - "$TMP_DIR/out-review-agent-plan.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'ok') throw new Error(out.status);
if (out.user_decision_required !== false) throw new Error('should not ask user to choose agent mode');
if (out.parent_scope !== '1-3') throw new Error(`parent scope lost: ${out.parent_scope}`);
if (out.batch_scope !== '1-3') throw new Error(`batch scope lost: ${out.batch_scope}`);
if (out.execution_plan.mode !== 'agent_dispatch') throw new Error(`wrong mode: ${out.execution_plan.mode}`);
const agents = out.execution_plan.agents.map(a => a.subagent_type).sort();
for (const required of ['story-explorer', 'consistency-checker']) {
  if (!agents.includes(required)) throw new Error(`missing ${required}`);
}
if (agents.includes('character-designer')) throw new Error(`unavailable optional agent was dispatched: ${agents}`);
if (!out.execution_plan.deferred_dimensions.includes('character')) throw new Error(JSON.stringify(out.execution_plan));
if (out.execution_plan.retry_policy !== 'missing_dimension_once') throw new Error(out.execution_plan.retry_policy);
if (out.visible_options.some(x => /full|lean/i.test(x.label))) throw new Error('visible options leak full/lean internals');
if (!out.visible_options[0].label.includes('继续审阅 1-3')) throw new Error('first option should continue current batch');
if (!out.visible_options[0].description.includes('自动分派')) throw new Error('first option should mention automatic dispatch');
if (!out.next_state.parent_scope_preserved) throw new Error('parent scope not preserved');
NODE
}

@test "review agent dispatch planner only uses roles in a persisted dispatch plan" {
    cat > "$TMP_DIR/dispatch-plan.json" <<'JSON'
{"mode":"agent_dispatch","roles":[{"subagent_type":"story-explorer","dimensions":["plot"]},{"subagent_type":"consistency-checker","dimensions":["canon"]}],"deferredDimensions":["prose"],"retryPolicy":"missing_dimension_once"}
JSON
    node "$SCRIPT" --scope "1-3" --batch "1-3" --agents-available story-explorer,consistency-checker,narrative-writer --dispatch-plan "$TMP_DIR/dispatch-plan.json" --json > "$TMP_DIR/out-review-agent-persisted.json"

    node - "$TMP_DIR/out-review-agent-persisted.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const agents = out.execution_plan.agents.map((agent) => agent.subagent_type).sort();
if (JSON.stringify(agents) !== JSON.stringify(['consistency-checker', 'story-explorer'])) throw new Error(JSON.stringify(out.execution_plan));
if (agents.includes('narrative-writer')) throw new Error('dispatcher invented an unplanned role');
if (!out.execution_plan.deferred_dimensions.includes('prose')) throw new Error(JSON.stringify(out.execution_plan));
NODE
}

@test "story review documents automatic agent dispatch instead of asking user to choose full lean" {
    grep -q "自动 agent 调度" "$REVIEW"
    grep -q "review-agent-dispatch-plan.js" "$REVIEW"
    grep -q "用户不需要选择 full/lean" "$REVIEW"
    grep -q "旧报告只能作为证据输入" "$REVIEW"
    grep -q "parent_scope" "$REVIEW"
    grep -q "batch_scope" "$REVIEW"
    grep -q "story-architect.*结构" "$REVIEW"
    grep -q "character-designer.*人物" "$REVIEW"
    grep -q "narrative-writer.*AI" "$REVIEW"
    grep -q "consistency-checker.*一致性" "$REVIEW"
    grep -q "自动分派" "$WORKFLOW"
    grep -q "不要把 full/lean 暴露成用户必须理解的选择" "$WORKFLOW"
}

@test "review agent dispatch planner is bundled" {
    node -e 'const m=require(process.argv[1]); if(!m.scriptFiles.includes("review-agent-dispatch-plan.js")) process.exit(1)' "$BUNDLE_MANIFEST"
    test -f "$REPO/skills/novel-assistant/scripts/review-agent-dispatch-plan.js"
}
