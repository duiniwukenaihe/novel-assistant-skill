#!/bin/bash
# stability-repair-dispatch.sh — turn daily stability audit JSON into an ordered repair queue.
set -u

usage() {
  echo "Usage: $0 [--write] [--json] [--volume 第1卷] <book-dir> <start-chapter-id> <end-chapter-id>" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
audit_script="$script_dir/longform-daily-stability-audit.sh"
json_file="$(mktemp)"
repair_file="$(mktemp)"
dispatch_json_file="$(mktemp)"
cleanup() {
  rm -f "$json_file" "$repair_file" "$dispatch_json_file"
}
trap cleanup EXIT

write_mode=0
json_mode=0
volume=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --write)
      write_mode=1
      shift
      ;;
    --json)
      json_mode=1
      shift
      ;;
    --volume)
      volume="${2:-}"
      [ -n "$volume" ] || fail "--volume requires a value"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi

[ -d "$1" ] || fail "book dir not found: $1"
[ -x "$audit_script" ] || fail "daily stability audit missing: $audit_script"
command -v node >/dev/null 2>&1 || fail "node is required to parse stability audit JSON"

book_dir="$(cd "$1" && pwd)"
start_chapter="$(printf '%03d' "$((10#$2))")"
end_chapter="$(printf '%03d' "$((10#$3))")"
repair_rel_path=""
if [ "$write_mode" -eq 1 ]; then
  if [ -n "$volume" ]; then
    repair_rel_path="追踪/稳定性审计/${volume}/修复清单_第${start_chapter}章_to_第${end_chapter}章.md"
  else
    repair_rel_path="追踪/稳定性审计/修复清单_第${start_chapter}章_to_第${end_chapter}章.md"
  fi
fi

set +e
if [ -n "$volume" ]; then
  audit_output="$(bash "$audit_script" --write --json --volume "$volume" "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
else
  audit_output="$(bash "$audit_script" --write --json "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
fi
audit_status="$?"
set -e
printf '%s\n' "$audit_output" > "$json_file"

node - "$json_file" "$repair_file" "$dispatch_json_file" "$repair_rel_path" "$volume" <<'NODE'
const fs = require('fs');

const jsonPath = process.argv[2];
const repairPath = process.argv[3];
const dispatchJsonPath = process.argv[4];
const repairReportPath = process.argv[5] || null;
const volume = process.argv[6] || '';
let data;
try {
  data = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
} catch (error) {
  console.error('FAIL: could not parse daily stability audit JSON');
  console.error(fs.readFileSync(jsonPath, 'utf8'));
  process.exit(2);
}

function targetChapter(scope) {
  const matches = [...scope.matchAll(/第 ([0-9]{3}) 章/g)].map((match) => match[1]);
  return matches.length > 0 ? matches[matches.length - 1] : '';
}

function priorityFor(code) {
  const priorities = {
    Canon_Conflict: 'P0',
    Knowledge_Leak: 'P0',
    Plot_Drift: 'P1',
    Motivation_Drift: 'P1',
    Continuity_Missing: 'P1',
    Beat_Missing: 'P1',
    Foreshadow_Early_Payoff: 'P1',
    State_Not_Updated: 'P2',
    Untracked_Addition: 'P2',
    Beat_Compressed: 'P2',
    Stability_Check_Failed: 'P2',
  };
  return priorities[code] || 'P2';
}

function ownerFor(code) {
  const owners = {
    Knowledge_Leak: 'character-designer',
    Motivation_Drift: 'character-designer',
    Plot_Drift: 'story-architect',
    Beat_Missing: 'story-architect',
    Beat_Compressed: 'story-architect',
    Foreshadow_Early_Payoff: 'story-architect',
    Continuity_Missing: 'narrative-writer',
    Canon_Conflict: 'consistency-checker',
    State_Not_Updated: 'narrative-writer',
    Untracked_Addition: 'narrative-writer',
    Stability_Check_Failed: 'consistency-checker',
  };
  return owners[code] || 'consistency-checker';
}

function repairSteps(code, scope, checkName) {
  const chapter = targetChapter(scope);
  const chapterLabel = chapter ? `第 ${chapter} 章` : scope;
  switch (code) {
    case 'Continuity_Missing':
      return [
        `先修${chapterLabel} Chapter Contract，补入上一章交接包继承项。`,
        `再修${chapterLabel}正文，把继承项写成可见行动、线索或反馈。`,
        '重跑 Plot Drift Gate、State Delta Ledger、Chapter Handoff Pack。',
        '重跑 Cross Chapter Continuity Audit，确认契约和正文都继承成功。',
      ];
    case 'Beat_Missing':
      return [
        `对照${chapterLabel} Chapter Contract 找出缺失 beat。`,
        '优先补写正文场景；若确需改契约，必须说明原因并同步细纲。',
        '重跑 Plot Drift Gate 和单章稳定性检查。',
      ];
    case 'Plot_Drift':
      return [
        `回到${chapterLabel} Chapter Contract，标出偏离当前卷目标或本章核心事件的段落。`,
        '删除、改写或后移偏离内容，保留本章必须交付。',
        '重跑 Plot Drift Gate。',
      ];
    case 'State_Not_Updated':
      return [
        `抽取${chapterLabel}正文造成的角色、伏笔、时间线或资源变化。`,
        '补写 State Delta Ledger，并同步对应追踪文件。',
        '重跑单章稳定性检查。',
      ];
    case 'Untracked_Addition':
      return [
        `定位${chapterLabel}新增人物、设定、支线、势力、规则或重要物件。`,
        '写入对应设定/追踪文件，再补 State Delta。',
        '重跑 Plot Drift Gate。',
      ];
    case 'Canon_Conflict':
      return [
        `统一${chapterLabel}正文、设定、时间线和角色状态中的冲突事实。`,
        '以既有 canon 为准；若要改 canon，先做 Revision Impact Analysis。',
        '重跑单章稳定性检查和受影响相邻章节连续性审计。',
      ];
    case 'Motivation_Drift':
      return [
        `调用 character-designer 对${chapterLabel}做角色裁决。`,
        '角色裁决范围限定为：补动机链 / 改行动 / 更新角色不变量 / 需要用户确认。',
        '若裁决为补动机链或改行动，再交给 narrative-writer 只改当前 checkpoint。',
        '重跑 Plot Drift Gate。',
      ];
    case 'Knowledge_Leak':
      return [
        `调用 character-designer 对${chapterLabel}做角色裁决。`,
        '角色裁决范围限定为：补获知过程 / 删除越界认知 / 更新角色不变量 / 需要用户确认。',
        '若裁决为补获知过程或删除越界认知，再交给 narrative-writer 只改当前 checkpoint。',
        '重跑 Plot Drift Gate。',
      ];
    case 'Foreshadow_Early_Payoff':
      return [
        `检查${chapterLabel}提前兑现或泄底的伏笔。`,
        '改为推进、误导、半兑现或延迟兑现，保留后续期待。',
        '同步伏笔追踪并重跑稳定性检查。',
      ];
    case 'Beat_Compressed':
      return [
        `把${chapterLabel}被摘要带过的重要 beat 拆成可感场景。`,
        '补行动、阻碍、代价和反馈。',
        '重跑 Plot Drift Gate。',
      ];
    default:
      return [
        `先对照审计报告 Diagnostics 定位${scope}的失败证据。`,
        `按 ${checkName} 的输入文件逐项修复，不要只改表面文本。`,
        '重跑 Longform Daily Stability Audit。',
      ];
  }
}

const lines = [];
const actions = [];
lines.push('## Stability Repair Dispatch');
lines.push('');
lines.push(`- 审计状态：${data.status}`);
lines.push(`- 失败数：${data.failures}`);
lines.push(`- 章节范围：第 ${data.start_chapter} 章 - 第 ${data.end_chapter} 章`);
lines.push(`- 审计报告：${data.report_path || '未落盘'}`);
lines.push('');

if (data.status === 'PASS') {
  lines.push('### 结论');
  lines.push('- No repair actions required.');
  fs.writeFileSync(repairPath, `${lines.join('\n')}\n`);
  fs.writeFileSync(dispatchJsonPath, `${JSON.stringify({
    status: data.status,
    volume: volume || null,
    failures: data.failures,
    start_chapter: data.start_chapter,
    end_chapter: data.end_chapter,
    audit_report_path: data.report_path || null,
    repair_report_path: repairReportPath || null,
    actions,
  })}\n`);
  process.exit(0);
}

const failed = (data.checks || []).filter((check) => check.result === 'FAIL');
lines.push('### 修复队列');
lines.push('| priority | owner | scope | check | code | next action |');
lines.push('|---|---|---|---|---|---|');

const expanded = [];
for (const check of failed) {
  const codes = check.error_codes && check.error_codes.length > 0
    ? check.error_codes
    : ['Stability_Check_Failed'];
  for (const code of codes) {
    const steps = repairSteps(code, check.scope, check.check);
    const action = {
      id: `R${expanded.length + 1}`,
      priority: priorityFor(code),
      owner: ownerFor(code),
      scope: check.scope,
      check: check.check,
      code,
      target_chapter: targetChapter(check.scope) || null,
      steps,
    };
    actions.push(action);
    expanded.push({ check, code, priority: action.priority, owner: action.owner, steps });
    lines.push(`| ${priorityFor(code)} | ${ownerFor(code)} | ${check.scope} | ${check.check} | ${code} | ${steps[0]} |`);
  }
}

lines.push('');
lines.push('### 修复步骤');
expanded.forEach((item, index) => {
  lines.push(`#### R${index + 1} ${item.check.scope} / ${item.code}`);
  item.steps.forEach((step, stepIndex) => {
    lines.push(`${stepIndex + 1}. ${step}`);
  });
  lines.push('');
});

fs.writeFileSync(repairPath, `${lines.join('\n').replace(/\n{3,}/g, '\n\n')}\n`);
fs.writeFileSync(dispatchJsonPath, `${JSON.stringify({
  status: data.status,
  volume: volume || null,
  failures: data.failures,
  start_chapter: data.start_chapter,
  end_chapter: data.end_chapter,
  audit_report_path: data.report_path || null,
  repair_report_path: repairReportPath || null,
  actions,
})}\n`);
NODE
node_status="$?"
[ "$node_status" -eq 0 ] || exit "$node_status"

if [ "$write_mode" -eq 1 ]; then
  out_dir="$(dirname "$book_dir/$repair_rel_path")"
  mkdir -p "$out_dir"
  out_file="$book_dir/$repair_rel_path"
  cp "$repair_file" "$out_file"
fi

if [ "$json_mode" -eq 1 ]; then
  cat "$dispatch_json_file"
elif [ "$write_mode" -eq 1 ]; then
  echo "WROTE: $repair_rel_path"
else
  cat "$repair_file"
fi

if [ "$audit_status" -eq 0 ]; then
  exit 0
fi
exit 1
