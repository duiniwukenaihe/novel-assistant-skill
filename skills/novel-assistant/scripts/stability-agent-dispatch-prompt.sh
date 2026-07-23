#!/bin/bash
# stability-agent-dispatch-prompt.sh — generate the Agent call for the current repair checkpoint.
set -u

usage() {
  echo "Usage: $0 [--json] [--volume 第1卷] <book-dir> <start-chapter-id> <end-chapter-id>" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
loop_script="$script_dir/stability-repair-loop.sh"
loop_json_file="$(mktemp)"
prompt_file="$(mktemp)"
prompt_json_file="$(mktemp)"
cleanup() {
  rm -f "$loop_json_file" "$prompt_file" "$prompt_json_file"
}
trap cleanup EXIT

json_mode=0
volume=""
while [ "$#" -gt 0 ]; do
  case "$1" in
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
[ -x "$loop_script" ] || fail "repair loop missing: $loop_script"
command -v node >/dev/null 2>&1 || fail "node is required to generate agent dispatch prompt"

book_dir="$(cd "$1" && pwd)"
start_chapter="$(printf '%03d' "$((10#$2))")"
end_chapter="$(printf '%03d' "$((10#$3))")"

set +e
if [ -n "$volume" ]; then
  loop_output="$(bash "$loop_script" --write --json --volume "$volume" "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
else
  loop_output="$(bash "$loop_script" --write --json "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
fi
loop_status="$?"
set -e
printf '%s\n' "$loop_output" > "$loop_json_file"

node - "$loop_json_file" "$prompt_file" "$prompt_json_file" "$book_dir" "$volume" <<'NODE'
const fs = require('fs');

const loopJsonPath = process.argv[2];
const promptPath = process.argv[3];
const promptJsonPath = process.argv[4];
const bookDir = process.argv[5];
const volume = process.argv[6] || '';

let data;
try {
  data = JSON.parse(fs.readFileSync(loopJsonPath, 'utf8'));
} catch (error) {
  console.error('FAIL: could not parse stability repair loop JSON');
  console.error(fs.readFileSync(loopJsonPath, 'utf8'));
  process.exit(2);
}

const ownerToAgent = {
  'character-designer': 'character-designer',
  'story-architect': 'story-architect',
  'narrative-writer': 'narrative-writer',
  'consistency-checker': 'consistency-checker',
};

function commandsText(commands) {
  return (commands || []).map((command) => `- ${command}`).join('\n');
}

function currentActionJson(action) {
  return JSON.stringify(action || null);
}

function taskType(owner) {
  switch (owner) {
    case 'character-designer':
      return 'Stability Repair Loop 角色裁决';
    case 'story-architect':
      return 'Stability Repair Loop 结构裁决';
    case 'narrative-writer':
      return 'Stability Repair Loop 局部修复';
    case 'consistency-checker':
      return 'Stability Repair Loop checkpoint 审查';
    default:
      return 'Stability Repair Loop checkpoint';
  }
}

function ownerInstructions(owner) {
  switch (owner) {
    case 'character-designer':
      return [
        '请只做角色裁决，不直接重写正文。',
        '必须读取涉及角色的 设定/角色/{角色名}.md、设定/角色不变量/{角色名}.md、追踪/角色状态.md，以及 target_chapter 对应正文、Chapter Contract、细纲。',
        '角色裁决只能从以下范围选择：',
        '补动机链 / 改行动 / 补获知过程 / 删除越界认知 / 更新角色不变量 / 需要用户确认',
        '',
        '输出：',
        '1. current_action 复述',
        '2. 角色裁决',
        '3. 裁决理由',
        '4. 修改边界',
        '5. 是否需要 narrative-writer 做局部正文修补',
        '6. verification_commands',
      ].join('\n');
    case 'story-architect':
      return [
        '请只做结构裁决，不直接重写正文。',
        '必须读取 target_chapter 对应卷纲、细纲、Chapter Contract、正文、伏笔追踪和审计报告。',
        '结构裁决只能从以下范围选择：',
        '改正文 / 改契约 / 改细纲 / 后移伏笔 / 需要用户确认',
        '',
        '输出：',
        '1. current_action 复述',
        '2. 结构裁决',
        '3. 裁决理由',
        '4. 修改边界',
        '5. 是否需要 narrative-writer 做局部正文修补',
        '6. verification_commands',
      ].join('\n');
    case 'narrative-writer':
      return [
        '只改当前 checkpoint，只改 target_chapter 或 current_action.steps 明确要求的文件。',
        '禁止整章重写。',
        '必须保留 Chapter Contract 的必须 beat，不得新增未追踪设定。',
        '',
        '输出：',
        '1. current_action 复述',
        '2. 实际修改文件',
        '3. 修改范围',
        '4. 是否仍需 consistency-checker 审查',
        '5. verification_commands',
      ].join('\n');
    case 'consistency-checker':
      return [
        '只审查当前 checkpoint，不做全书泛审。',
        '请对照审计报告、修复清单、修复后的目标文件，判断 current_action 是否已经解决。',
        '',
        '输出：',
        '1. current_action 复述',
        '2. checkpoint 审查结果：PASS / FAIL',
        '3. 仍失败时的错误码和证据',
        '4. 是否需要重跑 stability-repair-loop.sh',
        '5. verification_commands',
      ].join('\n');
    default:
      return '只处理当前 checkpoint，并输出 verification_commands。';
  }
}

const currentOwner = data.current_owner || (data.current_action && data.current_action.owner) || null;
const subagentType = ownerToAgent[currentOwner] || null;
const status = data.status;

let prompt = '';
let agentCall = '';
if (status !== 'PASS' && data.current_action && subagentType) {
  prompt = [
    `项目目录：${bookDir}`,
    `任务类型：${taskType(currentOwner)}`,
    `current_owner：${currentOwner}`,
    `current_action：${currentActionJson(data.current_action)}`,
    `audit_report_path：${data.audit_report_path || ''}`,
    `repair_report_path：${data.repair_report_path || ''}`,
    `loop_report_path：${data.loop_report_path || ''}`,
    'verification_commands：',
    commandsText(data.verification_commands),
    '',
    '硬约束：',
    '- 只处理 current_action.id 指定的当前 checkpoint。',
    '- 不处理 remaining_actions 中的其他问题。',
    '- 不整章重写；除非 current_action.steps 明确要求，也不改其他章节。',
    '- 输出必须保留 current_action、修改边界、后续 verification_commands。',
    '',
    ownerInstructions(currentOwner),
  ].join('\n');
  agentCall = `Agent(subagent_type: "${subagentType}", prompt: ${JSON.stringify(prompt)})`;
}

const lines = [];
lines.push('## Stability Agent Dispatch Prompt');
lines.push('');
lines.push(`- 状态：${status}`);
if (volume) lines.push(`- volume：${volume}`);
lines.push(`- current_owner：${currentOwner || 'none'}`);
lines.push(`- subagent_type：${subagentType || 'none'}`);
lines.push('');
if (!agentCall) {
  lines.push('No pending agent prompt.');
} else {
  lines.push('### Agent Call');
  lines.push(agentCall);
}

fs.writeFileSync(promptPath, `${lines.join('\n')}\n`);
fs.writeFileSync(promptJsonPath, `${JSON.stringify({
  status,
  volume: volume || null,
  current_owner: currentOwner,
  subagent_type: subagentType,
  current_action: data.current_action || null,
  audit_report_path: data.audit_report_path || null,
  repair_report_path: data.repair_report_path || null,
  loop_report_path: data.loop_report_path || null,
  verification_commands: data.verification_commands || [],
  prompt,
  agent_call: agentCall,
})}\n`);
NODE
node_status="$?"
[ "$node_status" -eq 0 ] || exit "$node_status"

if [ "$json_mode" -eq 1 ]; then
  cat "$prompt_json_file"
else
  cat "$prompt_file"
fi

if [ "$loop_status" -eq 0 ]; then
  exit 0
fi
exit 1
