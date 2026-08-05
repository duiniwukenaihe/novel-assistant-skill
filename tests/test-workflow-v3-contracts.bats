#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "V3 stage results reject visible output and accept four explicit kinds" {
  run node - "$REPO/scripts/lib/workflow-v3/contracts.js" <<'NODE'
const api = require(process.argv[2]);
for (const kind of ['completed','retryable_internal','blocked']) {
  const value = api.stageResult({ kind, code: `case_${kind}`, stage_id: 'planning' });
  if (value.kind !== kind) process.exit(1);
}
const choice = api.stageResult({
  kind: 'needs_author_choice', code: 'case_needs_author_choice', stage_id: 'planning', question: '选择方案',
  options: [{ action_id:'accept', label:'采用方案' }, { action_id:'chat', label:'进入 Chat 修改' }],
});
if (choice.kind !== 'needs_author_choice' || choice.options.some((option) => 'number' in option)) process.exit(2);
try {
  api.stageResult({ kind:'blocked', code:'bad', stage_id:'planning', visible_response:{text:'bad'} });
  process.exit(3);
} catch (error) {
  if (!/visible_response_forbidden/.test(error.message)) process.exit(4);
}
try {
  api.stageResult({ kind:'needs_author_choice', code:'bad_choice', stage_id:'planning' });
  process.exit(5);
} catch (error) {
  if (!/author_choice_count_invalid/.test(error.message)) process.exit(6);
}
NODE
  [ "$status" -eq 0 ]
}

@test "V3 validated author-choice options are frozen and cannot be pushed to" {
  run node - "$REPO/scripts/lib/workflow-v3/contracts.js" <<'NODE'
const api = require(process.argv[2]);
const choice = api.stageResult({
  kind: 'needs_author_choice', code: 'frozen_options', stage_id: 'planning',
  options: [
    { action_id:'accept', label:'采用方案' },
    { action_id:'chat', label:'进入 Chat 修改' },
  ],
});
if (!Object.isFrozen(choice.options)) process.exit(1);
let threw = false;
try {
  choice.options.push({ action_id:'extra', label:'额外' });
} catch (error) {
  threw = true;
}
if (!threw) process.exit(2);
if (choice.options.length !== 2) process.exit(3);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 author choice with exactly 1 option rejects with author_choice_count_invalid" {
  run node - "$REPO/scripts/lib/workflow-v3/contracts.js" <<'NODE'
const api = require(process.argv[2]);
let threw = false;
try {
  api.stageResult({
    kind: 'needs_author_choice', code: 'one_option', stage_id: 'planning',
    options: [{ action_id:'accept', label:'采用方案' }],
  });
} catch (error) {
  threw = true;
  if (!/author_choice_count_invalid/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 author choice with exactly 5 options rejects with author_choice_count_invalid" {
  run node - "$REPO/scripts/lib/workflow-v3/contracts.js" <<'NODE'
const api = require(process.argv[2]);
let threw = false;
try {
  api.stageResult({
    kind: 'needs_author_choice', code: 'five_options', stage_id: 'planning',
    options: [
      { action_id:'one', label:'一' },
      { action_id:'two', label:'二' },
      { action_id:'three', label:'三' },
      { action_id:'four', label:'四' },
      { action_id:'five', label:'五' },
    ],
  });
} catch (error) {
  threw = true;
  if (!/author_choice_count_invalid/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 professional-stage author choice option containing a number key rejects with author_choice_number_forbidden" {
  run node - "$REPO/scripts/lib/workflow-v3/contracts.js" <<'NODE'
const api = require(process.argv[2]);
let threw = false;
try {
  api.stageResult({
    kind: 'needs_author_choice', code: 'numbered_option', stage_id: 'planning',
    options: [
      { action_id:'accept', label:'采用方案', number: 1 },
      { action_id:'chat', label:'进入 Chat 修改' },
    ],
  });
} catch (error) {
  threw = true;
  if (!/author_choice_number_forbidden/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);
NODE
  [ "$status" -eq 0 ]
}
