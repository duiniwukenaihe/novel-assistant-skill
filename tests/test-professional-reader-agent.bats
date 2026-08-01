#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AGENT="$REPO/src/internal-skills/story-setup/references/templates/agents/professional-reader.md"
  OPENCODE_AGENT="$REPO/src/internal-skills/story-setup/references/opencode/agents/professional-reader.md"
  REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
  CONTRACT="$REPO/src/internal-skills/story-review/references/professional-reader-contract.md"
}

@test "professional reader is a blind read-only reaction agent" {
  [ -f "$AGENT" ]
  grep -q '^name: professional-reader$' "$AGENT"
  grep -q 'disallowedTools:.*Write.*Edit.*Bash' "$AGENT"
  grep -q '第一遍禁止读取大纲' "$AGENT"
  grep -q '不得直接给修复方案' "$AGENT"
  grep -q '掉线点' "$AGENT"
  grep -q '人物印象' "$AGENT"
  grep -q '身份连续性' "$AGENT"
  grep -q '配角真实感' "$AGENT"
  grep -q '揭示余震' "$AGENT"
  grep -q 'style_lens' "$AGENT"
  grep -q 'profile_basis' "$AGENT"
  grep -q 'target_platform.*未确认.*general_fiction' "$AGENT"
  grep -q '身份连续性' "$OPENCODE_AGENT"
  grep -q '配角真实感' "$OPENCODE_AGENT"
  grep -q '揭示余震' "$OPENCODE_AGENT"
}

@test "story review consumes reader reaction as evidence rather than canon" {
  [ -f "$CONTRACT" ]
  grep -q '读者反应证据层' "$CONTRACT"
  grep -q '不得直接写入长期记忆' "$CONTRACT"
  grep -q '用户确认后的修订方案' "$CONTRACT"
  grep -q '身份连续性' "$CONTRACT"
  grep -q '配角真实感' "$CONTRACT"
  grep -q '揭示余震' "$CONTRACT"
  grep -q '用户本轮确认 > 项目设定/投稿配置' "$CONTRACT"
  grep -q 'professional-reader' "$REVIEW"
  grep -q 'professional-reader-contract.md' "$REVIEW"
}

@test "short reader milestones escalate opening reversal ending and explicit rework only" {
  run node - "$REPO/scripts/lib/short-reader-milestone-policy.js" <<'NODE'
const {resolveShortReaderMilestone}=require(process.argv[2]);
const opening=resolveShortReaderMilestone({sectionIndex:1,outlineContract:{section_role:'opening'}});
const ordinary=resolveShortReaderMilestone({sectionIndex:4,outlineContract:{section_role:'normal'}});
const reversal=resolveShortReaderMilestone({sectionIndex:5,outlineContract:{section_role:'major_reversal'}});
const ending=resolveShortReaderMilestone({sectionIndex:9,outlineContract:{section_role:'ending'}});
const rework=resolveShortReaderMilestone({sectionIndex:3,outlineContract:{section_role:'normal'},task:{feedback_revision_queue:{status:'running',current_section_index:3}}});
if(!opening.required||opening.kind!=='golden_opening') throw new Error(JSON.stringify(opening));
if(ordinary.required) throw new Error(JSON.stringify(ordinary));
if(!reversal.required||reversal.kind!=='major_reversal') throw new Error(JSON.stringify(reversal));
if(!ending.required||ending.kind!=='ending_payoff') throw new Error(JSON.stringify(ending));
if(!rework.required||rework.kind!=='user_rework') throw new Error(JSON.stringify(rework));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
