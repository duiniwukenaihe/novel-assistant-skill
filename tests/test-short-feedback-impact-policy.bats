#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  POLICY="$REPO/scripts/lib/short-feedback-impact-policy.js"
}

@test "short feedback keeps expression-only changes inside the current section" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const result = policy.resolveShortFeedbackPatch({
  result: { impact_level: 'expression_only', changed_assets: ['正文.md'] },
  allowedNext: ['section_repair_loop', 'first_section_brief', 'next_section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (result.status !== 'ok' || result.next_stage_id !== 'section_repair_loop' || result.invalidates_brief) {
  throw new Error(JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ]
}

@test "short feedback rebuilds the current brief for local story changes" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const result = policy.resolveShortFeedbackPatch({
  result: { impact_level: 'current_brief', changed_assets: [], brief_invalidated: true },
  allowedNext: ['section_repair_loop', 'first_section_brief', 'next_section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (result.status !== 'ok' || result.next_stage_id !== 'next_section_brief' || !result.invalidates_brief || !result.invalidates_draft) {
  throw new Error(JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ]
}

@test "public and private short workflows resolve the same current brief semantics" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const shared = {
  result: { impact_level: 'current_brief', changed_assets: [], brief_invalidated: true },
  sectionIndex: 2,
};
const publicResult = policy.resolveShortFeedbackPatch({
  ...shared,
  allowedNext: ['section_repair_loop', 'section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
});
const privateResult = policy.resolveShortFeedbackPatch({
  ...shared,
  allowedNext: ['section_repair_loop', 'first_section_brief', 'next_section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
});
if (publicResult.status !== 'ok' || publicResult.next_stage_id !== 'section_brief') throw new Error(JSON.stringify(publicResult));
if (privateResult.status !== 'ok' || privateResult.next_stage_id !== 'next_section_brief') throw new Error(JSON.stringify(privateResult));
NODE
  [ "$status" -eq 0 ]
}

@test "short feedback cannot bypass upstream planning when setting or outline changes" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const blocked = policy.resolveShortFeedbackPatch({
  result: {
    impact_level: 'planning',
    changed_assets: ['设定.md', '小节大纲.md'],
    brief_invalidated: false,
    next_stage_id: 'section_repair_loop',
  },
  allowedNext: ['section_repair_loop', 'first_section_brief', 'next_section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (blocked.status !== 'blocked_feedback_impact_contract') throw new Error(JSON.stringify(blocked));

const accepted = policy.resolveShortFeedbackPatch({
  result: {
    impact_level: 'planning',
    changed_assets: ['设定.md', '小节大纲.md'],
    brief_invalidated: true,
  },
  allowedNext: ['section_repair_loop', 'first_section_brief', 'next_section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (accepted.status !== 'ok' || accepted.next_stage_id !== 'section_plan_lock' || !accepted.invalidates_brief) {
  throw new Error(JSON.stringify(accepted));
}
NODE
  [ "$status" -eq 0 ]
}

@test "expression-only feedback cannot disguise planning changes" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const result = policy.resolveShortFeedbackPatch({
  result: { impact_level: 'expression_only', changed_assets: ['正文.md', '小节大纲.md'] },
  allowedNext: ['section_repair_loop', 'section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (result.status !== 'blocked_feedback_impact_contract') throw new Error(JSON.stringify(result));
NODE
  [ "$status" -eq 0 ]
}

@test "manual prose remains a candidate until semantic impact is accepted" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const blocked = policy.resolveShortFeedbackPatch({
  result: {
    impact_level: 'expression_only',
    changed_assets: ['正文.md'],
    source_kind: 'user_manual_edit',
  },
  allowedNext: ['section_repair_loop', 'section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (blocked.status !== 'blocked_feedback_impact_contract') throw new Error(JSON.stringify(blocked));
const accepted = policy.resolveShortFeedbackPatch({
  result: {
    impact_level: 'expression_only',
    changed_assets: ['正文.md'],
    source_kind: 'user_manual_edit',
    preserve_user_text: true,
  },
  allowedNext: ['section_repair_loop', 'section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (accepted.status !== 'ok' || accepted.user_text_status !== 'candidate_preserved') throw new Error(JSON.stringify(accepted));
NODE
  [ "$status" -eq 0 ]
}

@test "short structure feedback must return to section plan lock" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const result = policy.resolveShortFeedbackPatch({
  result: {
    impact_level: 'structure',
    changed_assets: ['设定.md', '小节大纲.md'],
    brief_invalidated: true,
    downstream_impact: { invalidated: ['写作Brief_第002节.md'] },
  },
  allowedNext: ['section_repair_loop', 'first_section_brief', 'next_section_brief', 'short_setting', 'section_outline', 'section_plan_lock'],
  sectionIndex: 2,
});
if (result.status !== 'ok' || result.next_stage_id !== 'section_plan_lock' || !result.requires_structure_audit) {
  throw new Error(JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ]
}

@test "cross-section planning feedback requires a downstream invalidation map" {
  run node - "$POLICY" <<'NODE'
const policy = require(process.argv[2]);
const base = {
  impact_level: 'planning',
  changed_assets: ['小节大纲.md'],
  brief_invalidated: true,
  affected_sections: [4, 5, 6, 7, 8, 9],
};
const allowedNext = ['section_repair_loop', 'section_brief', 'short_setting', 'section_outline', 'section_plan_lock'];
const blocked = policy.resolveShortFeedbackPatch({ result: base, allowedNext, sectionIndex: 4 });
if (blocked.status !== 'blocked_feedback_impact_contract') throw new Error(JSON.stringify(blocked));
const accepted = policy.resolveShortFeedbackPatch({
  result: { ...base, downstream_impact: { invalidated: ['写作Brief_第004节.md', '写作Brief_第005节.md'], revalidate_prose: [4,5,6,7,8,9] } },
  allowedNext,
  sectionIndex: 4,
});
if (accepted.status !== 'ok' || accepted.next_stage_id !== 'section_plan_lock' || !accepted.requires_structure_audit || !accepted.cross_section_impact) {
  throw new Error(JSON.stringify(accepted));
}
NODE
  [ "$status" -eq 0 ]
}
