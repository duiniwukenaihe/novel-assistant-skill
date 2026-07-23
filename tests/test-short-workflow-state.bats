#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STATE="$REPO/scripts/lib/short-workflow-state.js"
}

@test "short workflow infers the next section from accepted anchors" {
  run node - "$STATE" <<'NODE'
const { inferShortSectionIndex } = require(process.argv[2]);
const next = inferShortSectionIndex({
  projectState: { accepted_sections: [{ section_index: 1 }] },
  stageId: 'next_section_brief',
  scope: '',
});
if (next !== 2) throw new Error(String(next));
NODE
  [ "$status" -eq 0 ]
}

@test "short workflow respects explicit current section and first-section stages" {
  run node - "$STATE" <<'NODE'
const { inferShortSectionIndex } = require(process.argv[2]);
const explicit = inferShortSectionIndex({ projectState: { current_section_index: 4, accepted_sections: [{}, {}] }, stageId: 'next_section_brief' });
const first = inferShortSectionIndex({ projectState: { current_section_index: 4 }, stageId: 'first_section_brief' });
if (explicit !== 4 || first !== 1) throw new Error(JSON.stringify({ explicit, first }));
NODE
  [ "$status" -eq 0 ]
}

@test "next brief advances beyond an already accepted explicit current section" {
  run node - "$STATE" <<'NODE'
const { inferShortSectionIndex } = require(process.argv[2]);
const next = inferShortSectionIndex({
  projectState: { current_section_index: 6, accepted_sections: Array.from({length:6},(_,i)=>({section_index:i+1})) },
  stageId: 'next_section_brief',
  scope: '第6节',
});
if (next !== 7) throw new Error(String(next));
NODE
  [ "$status" -eq 0 ]
}

@test "short plan resolves nested narrative count and stops after the final accepted section" {
  run node - "$STATE" <<'NODE'
const { resolvePlannedSectionCount, resolveShortPlanProgress } = require(process.argv[2]);
const plan = resolvePlannedSectionCount({
  projectState: { narrative: { planned_sections: 9 } },
  titleLock: { sections: Array.from({ length: 9 }, (_, index) => ({ section_index: index + 1 })) },
  outlineText: '- 总小节数：9节。\n\n## 第9节：结尾',
});
if (plan.status !== 'locked' || plan.count !== 9) throw new Error(JSON.stringify(plan));
const progress = resolveShortPlanProgress({
  plannedCount: plan.count,
  acceptedSections: Array.from({ length: 9 }, (_, index) => ({ section_index: index + 1 })),
  currentSection: 9,
});
if (!progress.completed || progress.next_section !== 0) throw new Error(JSON.stringify(progress));
NODE
  [ "$status" -eq 0 ]
}

@test "short plan reports conflicting totals instead of guessing a next section" {
  run node - "$STATE" <<'NODE'
const { resolvePlannedSectionCount } = require(process.argv[2]);
const plan = resolvePlannedSectionCount({
  projectState: { narrative: { planned_sections: 9 } },
  titleLock: { sections: Array.from({ length: 10 }, (_, index) => ({ section_index: index + 1 })) },
  outlineText: '- 总小节数：9节。',
});
if (plan.status !== 'conflict' || plan.count !== 0) throw new Error(JSON.stringify(plan));
NODE
  [ "$status" -eq 0 ]
}
