#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  IMPACT="$REPO/scripts/lib/lifecycle-impact.js"
}

@test "classifies feedback into the five lifecycle impact levels" {
  run node - "$IMPACT" <<'NODE'
const impact = require(process.argv[2]);
const cases = [
  [{ target: 'prose' }, 'prose'],
  [{ target: 'chapter_brief' }, 'brief'],
  [{ target: 'stage_detail_outline' }, 'detail_outline'],
  [{ target: 'volume_outline' }, 'volume_outline'],
  [{ target: 'master_outline' }, 'master_outline'],
];
for (const [feedback, expected] of cases) {
  const actual = impact.classifyFeedbackImpact(feedback);
  if (actual !== expected) throw new Error(`${JSON.stringify(feedback)} => ${actual}`);
}
NODE
  [ "$status" -eq 0 ]
}

@test "classifies natural-language feedback at the highest affected planning layer" {
  run node - "$IMPACT" <<'NODE'
const impact = require(process.argv[2]);
const cases = [
  ['只润色这一章正文，不改变事实', 'prose'],
  ['调整本章 Brief 的场景目标', 'brief'],
  ['前期太快，需要插章并重排阶段细纲', 'detail_outline'],
  ['调整本卷目标和卷内节奏', 'volume_outline'],
  ['改变全书主线和总纲结局', 'master_outline'],
];
for (const [feedback, expected] of cases) {
  const actual = impact.classifyFeedbackImpact(feedback);
  if (actual !== expected) throw new Error(`${feedback} => ${actual}`);
}
NODE
  [ "$status" -eq 0 ]
}

@test "master outline change marks dependent plans without discarding accepted prose" {
  run node - "$IMPACT" <<'NODE'
const impact = require(process.argv[2]);
const graph = { assets: [
  { id: 'master', kind: 'master_outline', status: 'accepted' },
  { id: 'volume-1', kind: 'volume_outline', depends_on: ['master'], status: 'accepted' },
  { id: 'detail-1', kind: 'detail_outline', depends_on: ['volume-1'], status: 'draft' },
  { id: 'chapter-v01-c001', kind: 'prose', depends_on: ['detail-1'], status: 'accepted', content: 'accepted prose' },
] };
const before = JSON.stringify(graph);
const result = impact.invalidateDownstream(graph, { kind: 'master_outline', id: 'master' });
if (!result.needs_recheck.includes('volume-1')) throw new Error(JSON.stringify(result));
if (!result.invalidated.includes('detail-1')) throw new Error(JSON.stringify(result));
if (!result.preserve_until_proven_invalid.includes('chapter-v01-c001')) throw new Error(JSON.stringify(result));
if (result.delete_assets.length || result.overwrite_assets.length) throw new Error('accepted assets must not be deleted or overwritten');
if (JSON.stringify(graph) !== before) throw new Error('input graph was mutated');
NODE
  [ "$status" -eq 0 ]
}

@test "accepted prose remains preserved even when it directly depends on the changed asset" {
  run node - "$IMPACT" <<'NODE'
const impact = require(process.argv[2]);
const result = impact.invalidateDownstream({ assets: [
  { id: 'brief-1', kind: 'brief', status: 'accepted' },
  { id: 'chapter-1', kind: 'prose', depends_on: ['brief-1'], status: 'accepted' },
] }, { kind: 'brief', id: 'brief-1' });
if (result.invalidated.includes('chapter-1')) throw new Error(JSON.stringify(result));
if (!result.preserve_until_proven_invalid.includes('chapter-1')) throw new Error(JSON.stringify(result));
NODE
  [ "$status" -eq 0 ]
}

@test "all chapter structure changes return to planning with preservation actions" {
  run node - "$IMPACT" <<'NODE'
const impact = require(process.argv[2]);
for (const change_type of ['expand', 'contract', 'insert_chapter', 'merge_chapters', 'delete_chapter']) {
  const result = impact.buildReplanActions({ change_type, impact_level: 'detail_outline' });
  if (result.return_to !== 'stage_detail_outline') throw new Error(`${change_type}: ${JSON.stringify(result)}`);
  if (!result.requires_impact_analysis) throw new Error(`${change_type}: impact analysis missing`);
  if (!result.preserve_chapter_names) throw new Error(`${change_type}: chapter names not preserved`);
  if (!result.preserve_reusable_content) throw new Error(`${change_type}: reusable content not preserved`);
  if (result.allow_prose_delete || result.allow_prose_overwrite) throw new Error(`${change_type}: unsafe prose action`);
}
NODE
  [ "$status" -eq 0 ]
}

@test "chapter structure changes infer the planning layer without an explicit impact level" {
  run node - "$IMPACT" <<'NODE'
const impact = require(process.argv[2]);
for (const change_type of ['insert', 'merge', 'delete', 'expand', 'shrink']) {
  const result = impact.buildReplanActions({ change_type });
  if (result.impact_level !== 'detail_outline') throw new Error(`${change_type}: ${JSON.stringify(result)}`);
  if (result.return_to !== 'stage_detail_outline') throw new Error(`${change_type}: ${JSON.stringify(result)}`);
  if (!result.preserve_chapter_names) throw new Error(`${change_type}: chapter names not preserved`);
  if (!result.downstream_effects || result.downstream_effects.requires_impact_analysis !== true) {
    throw new Error(`${change_type}: downstream effects missing: ${JSON.stringify(result)}`);
  }
}
NODE
  [ "$status" -eq 0 ]
}

@test "feedback impact returns to its matching lifecycle planning node" {
  run node - "$IMPACT" <<'NODE'
const impact = require(process.argv[2]);
const expected = {
  prose: 'prose',
  brief: 'chapter_brief',
  detail_outline: 'stage_detail_outline',
  volume_outline: 'volume_outline',
  master_outline: 'master_outline',
};
for (const [impact_level, return_to] of Object.entries(expected)) {
  const result = impact.buildReplanActions({ impact_level });
  if (result.return_to !== return_to) throw new Error(JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ]
}
