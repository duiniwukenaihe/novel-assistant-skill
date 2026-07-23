#!/bin/bash
# stability-repair-loop.sh — produce the next repair checkpoint until stability audit passes.
set -u

usage() {
  echo "Usage: $0 [--write] [--json] [--volume 第1卷] <book-dir> <start-chapter-id> <end-chapter-id>" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
dispatch_script="$script_dir/stability-repair-dispatch.sh"
dispatch_json_file="$(mktemp)"
loop_file="$(mktemp)"
loop_json_file="$(mktemp)"
cleanup() {
  rm -f "$dispatch_json_file" "$loop_file" "$loop_json_file"
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
[ -x "$dispatch_script" ] || fail "repair dispatcher missing: $dispatch_script"
command -v node >/dev/null 2>&1 || fail "node is required to parse repair dispatch JSON"

book_dir="$(cd "$1" && pwd)"
start_chapter="$(printf '%03d' "$((10#$2))")"
end_chapter="$(printf '%03d' "$((10#$3))")"
loop_rel_path=""
if [ "$write_mode" -eq 1 ]; then
  if [ -n "$volume" ]; then
    loop_rel_path="追踪/稳定性审计/${volume}/修复闭环_第${start_chapter}章_to_第${end_chapter}章.md"
  else
    loop_rel_path="追踪/稳定性审计/修复闭环_第${start_chapter}章_to_第${end_chapter}章.md"
  fi
fi

set +e
if [ -n "$volume" ]; then
  dispatch_output="$(bash "$dispatch_script" --write --json --volume "$volume" "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
else
  dispatch_output="$(bash "$dispatch_script" --write --json "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
fi
dispatch_status="$?"
set -e
printf '%s\n' "$dispatch_output" > "$dispatch_json_file"

node - "$dispatch_json_file" "$loop_file" "$loop_json_file" "$loop_rel_path" "$volume" <<'NODE'
const fs = require('fs');

const dispatchJsonPath = process.argv[2];
const loopPath = process.argv[3];
const loopJsonPath = process.argv[4];
const loopReportPath = process.argv[5] || null;
const volume = process.argv[6] || '';

let data;
try {
  data = JSON.parse(fs.readFileSync(dispatchJsonPath, 'utf8'));
} catch (error) {
  console.error('FAIL: could not parse repair dispatch JSON');
  console.error(fs.readFileSync(dispatchJsonPath, 'utf8'));
  process.exit(2);
}

function commandPlan(action, startChapter, endChapter) {
  if (!action) return [];
  const target = action.target_chapter || startChapter;
  const prev = String(Math.max(1, Number(target) - 1)).padStart(3, '0');
  const commands = [];
  const volumeFlag = volume ? `--volume ${volume} ` : '';
  switch (action.code) {
    case 'Continuity_Missing':
      commands.push(`bash scripts/cross-chapter-continuity-audit.sh ${volumeFlag}<book-dir> ${prev} ${target}`);
      commands.push(`bash scripts/chapter-handoff-pack.sh --write ${volumeFlag}<book-dir> ${prev}`);
      break;
    case 'Beat_Missing':
    case 'Plot_Drift':
    case 'Motivation_Drift':
    case 'Knowledge_Leak':
    case 'Foreshadow_Early_Payoff':
    case 'Beat_Compressed':
      commands.push(`bash scripts/chapter-stability-check.sh ${volumeFlag}<book-dir> ${target}`);
      break;
    case 'State_Not_Updated':
    case 'Untracked_Addition':
      commands.push(`bash scripts/chapter-stability-check.sh ${volumeFlag}<book-dir> ${target}`);
      commands.push(`bash scripts/chapter-handoff-pack.sh --write ${volumeFlag}<book-dir> ${target}`);
      break;
    default:
      commands.push(`bash scripts/longform-daily-stability-audit.sh --write ${volumeFlag}<book-dir> ${startChapter} ${endChapter}`);
      break;
  }
  commands.push(`bash scripts/stability-repair-loop.sh --write ${volumeFlag}<book-dir> ${startChapter} ${endChapter}`);
  return [...new Set(commands)];
}

const actions = Array.isArray(data.actions) ? data.actions : [];
const currentAction = actions[0] || null;
const status = data.status === 'PASS' || actions.length === 0 ? 'PASS' : 'NEEDS_REPAIR';
const currentOwner = currentAction ? currentAction.owner || null : null;
const verificationCommands = commandPlan(currentAction, data.start_chapter, data.end_chapter);

const lines = [];
lines.push('## Stability Repair Loop');
lines.push('');
lines.push(`- 闭环状态：${status}`);
lines.push(`- 章节范围：第 ${data.start_chapter} 章 - 第 ${data.end_chapter} 章`);
lines.push(`- 审计报告：${data.audit_report_path || '未落盘'}`);
lines.push(`- 修复清单：${data.repair_report_path || '未落盘'}`);
lines.push('');

if (status === 'PASS') {
  lines.push('### 结论');
  lines.push('- No pending repair actions.');
} else {
  lines.push('### 当前 checkpoint');
  lines.push(`- 当前 checkpoint：${currentAction.id}`);
  lines.push(`- priority: ${currentAction.priority}`);
  lines.push(`- owner: ${currentOwner || 'unknown'}`);
  lines.push(`- code: ${currentAction.code}`);
  lines.push(`- target_chapter: ${currentAction.target_chapter || 'unknown'}`);
  lines.push(`- scope: ${currentAction.scope}`);
  lines.push('');
  lines.push('### 本轮修复步骤');
  currentAction.steps.forEach((step, index) => {
    lines.push(`${index + 1}. ${step}`);
  });
  lines.push('');
  lines.push('### 修完后运行');
  verificationCommands.forEach((command) => {
    lines.push(`- ${command}`);
  });
}

fs.writeFileSync(loopPath, `${lines.join('\n')}\n`);
fs.writeFileSync(loopJsonPath, `${JSON.stringify({
  status,
  volume: volume || null,
  start_chapter: data.start_chapter,
  end_chapter: data.end_chapter,
  audit_report_path: data.audit_report_path || null,
  repair_report_path: data.repair_report_path || null,
  loop_report_path: loopReportPath || null,
  current_owner: currentOwner,
  current_action: currentAction,
  remaining_actions: actions,
  verification_commands: verificationCommands,
})}\n`);
NODE
node_status="$?"
[ "$node_status" -eq 0 ] || exit "$node_status"

if [ "$write_mode" -eq 1 ]; then
  out_dir="$(dirname "$book_dir/$loop_rel_path")"
  mkdir -p "$out_dir"
  out_file="$book_dir/$loop_rel_path"
  cp "$loop_file" "$out_file"
fi

if [ "$json_mode" -eq 1 ]; then
  cat "$loop_json_file"
elif [ "$write_mode" -eq 1 ]; then
  echo "WROTE: $loop_rel_path"
else
  cat "$loop_file"
fi

if [ "$dispatch_status" -eq 0 ]; then
  exit 0
fi
exit 1
