#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
}

@test "visible review summary uses Chinese business labels instead of internal dispatch fields" {
    [ -f "$REVIEW" ]

    REVIEW="$REVIEW" node <<'NODE'
const fs = require('fs');
const review = fs.readFileSync(process.env.REVIEW, 'utf8');
const start = review.indexOf('## 用户可见审阅摘要');
const end = review.indexOf('\n## ', start + 1);
if (start < 0) throw new Error('missing visible review summary schema');
const visible = review.slice(start, end < 0 ? undefined : end);
for (const forbidden of [
  'Requested Mode',
  'Effective Mode',
  'agent_dispatch',
  'story-architect',
  'character-designer',
  'narrative-writer',
  'consistency-checker',
  'blocked_missing_source',
  'blocked_output_pollution',
]) {
  if (visible.includes(forbidden)) throw new Error(`visible summary leaks ${forbidden}`);
}
for (const required of ['审阅范围', '本轮结论', '需要处理的问题', '下一步建议']) {
  if (!visible.includes(required)) throw new Error(`visible summary missing ${required}`);
}
NODE
}

@test "review keeps machine dispatch fields in its JSON result packet schema" {
    grep -q '## 机器审阅结果包' "$REVIEW"
    grep -q '"requested_mode"' "$REVIEW"
    grep -q '"effective_mode"' "$REVIEW"
    grep -q '"execution_mode"' "$REVIEW"
    grep -q '"raw_status"' "$REVIEW"
}
