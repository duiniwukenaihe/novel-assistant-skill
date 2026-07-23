#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  POLICY="$REPO_ROOT/scripts/lib/short-section-acceptance-policy.js"
}

@test "single accepted candidate skips comparison" {
  node - "$POLICY" <<'NODE'
const { resolveShortQualityNext } = require(process.argv[2]);
const next = resolveShortQualityNext({
  stageId: 'quality_gate',
  result: { step_status: 'completed', verification_result: 'pass', candidate_count: 1 },
  allowedNext: ['feedback_impact_sync', 'section_accept_anchor', 'section_candidate_compare'],
});
if (next !== 'section_accept_anchor') throw new Error(next);
NODE
}

@test "multiple candidates enter comparison" {
  node - "$POLICY" <<'NODE'
const { resolveShortQualityNext } = require(process.argv[2]);
const next = resolveShortQualityNext({
  stageId: 'quality_gate',
  result: { step_status: 'completed', verification_result: 'pass', candidate_count: 2 },
  allowedNext: ['feedback_impact_sync', 'section_accept_anchor', 'section_candidate_compare'],
});
if (next !== 'section_candidate_compare') throw new Error(next);
NODE
}

@test "explicit comparison request enters comparison even with one candidate" {
  node - "$POLICY" <<'NODE'
const { resolveShortQualityNext } = require(process.argv[2]);
const next = resolveShortQualityNext({
  stageId: 'quality_gate',
  result: { step_status: 'completed', verification_result: 'pass', candidate_count: 1, comparison_requested: true },
  allowedNext: ['feedback_impact_sync', 'section_accept_anchor', 'section_candidate_compare'],
});
if (next !== 'section_candidate_compare') throw new Error(next);
NODE
}

@test "accepted section enters next brief unless all planned sections are complete" {
  node - "$POLICY" <<'NODE'
const { resolveShortAnchorNext } = require(process.argv[2]);
const allowed = ['next_section_brief', 'full_story_assembly'];
if (resolveShortAnchorNext({ result: { remaining_sections: [2,3] }, allowedNext: allowed }) !== 'next_section_brief') throw new Error('must continue with next brief');
if (resolveShortAnchorNext({ result: { remaining_sections: [] }, allowedNext: allowed }) !== 'full_story_assembly') throw new Error('must assemble completed story');
if (resolveShortAnchorNext({ result: { all_sections_completed: false, remaining_sections: [] }, allowedNext: allowed }) !== 'next_section_brief') throw new Error('explicit incomplete result must not be overridden by stale remaining sections');
if (resolveShortAnchorNext({ result: { all_sections_completed: true, remaining_sections: [9] }, allowedNext: allowed }) !== 'full_story_assembly') throw new Error('explicit completed result must win over stale remaining sections');
NODE
}
