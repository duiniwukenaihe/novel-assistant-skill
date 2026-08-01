#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$(mktemp -d)/book"
  mkdir -p "$BOOK/追踪/workflow" "$BOOK/追踪/private-short-extension"
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$BOOK" --scope "测试短篇" --user-goal "测试控制台契约" --json >/dev/null
  WORKFLOW_ID="$(node -e 'const fs=require("fs"),path=require("path");const x=JSON.parse(fs.readFileSync(path.join(process.argv[1],"追踪/workflow/current-task.json"),"utf8"));process.stdout.write(x.workflow_id)' "$BOOK")"
}

teardown() {
  rm -rf "$(dirname "$BOOK")"
}

@test "all managed short section scripts expose help without Exit code 2" {
  for script in \
    short-section-accept-finalize.js \
    short-section-machine-gate.js \
    short-section-quality-gate.js \
    short-section-draft-finalize.js \
    short-section-brief-finalize.js \
    short-section-repair-finalize.js \
    short-section-title-lock.js; do
    run node "$REPO/scripts/$script" --help
    [ "$status" -eq 0 ]
    [[ "$output" == Usage:* ]]
  done
}

@test "stale short stage commands return handled business states without console errors" {
  for script in \
    short-section-accept-finalize.js \
    short-section-machine-gate.js \
    short-section-quality-gate.js \
    short-section-draft-finalize.js \
    short-section-brief-finalize.js \
    short-section-repair-finalize.js; do
    run node "$REPO/scripts/$script" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    [[ "$output" != *'Exit code'* ]]
  done
}

@test "missing short title inputs are recoverable business states" {
  run node "$REPO/scripts/short-section-title-lock.js" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"short_outline_missing"'* ]]
}

@test "workflow inbox accepts cwd defaults aliases and numeric selection without usage errors" {
  run bash -c 'cd "$1" && node "$2/scripts/workflow-task-inbox.js" --action show_current_run --selection 1 --json' -- "$BOOK" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown argument"* ]]
  [[ "$output" != *"missing --project-root"* ]]
}

@test "workflow state machine defaults to current candidates when command name is omitted" {
  run node "$REPO/scripts/workflow-state-machine.js" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"missing or invalid command"* ]]
}

@test "expected menu-handled blocks return exit 0 not console program error" {
  # P1.2 验证点：预期阻断（由菜单/工作流承接）不得显示为控制台程序错误。
  # blocked_longform_lifecycle_migration_required 属于 isConsoleErrorStatus 的
  # 白名单（menu-handled）状态——它应在 JSON 中保留结构化 status，但 exit 0。
  book="$(dirname "$BOOK")/legacy-menu"
  mkdir -p "$book/正文"
  printf 'legacy asset\n' > "$book/正文/legacy.md"
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type long_write --project-root "$book" --user-goal "续写旧项目" --json >/dev/null
  # 抹掉 lifecycle_graph，强制进入 migration-required 预期阻断。
  node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
for(const file of fs.readdirSync(path.join(root,'追踪/workflow/tasks')).map(id=>path.join(root,'追踪/workflow/tasks',id,'task.json'))) {
  const task=JSON.parse(fs.readFileSync(file,'utf8'));
  delete task.lifecycle_graph;
  fs.writeFileSync(file,JSON.stringify(task,null,2));
}
NODE

  run node "$REPO/scripts/workflow-state-machine.js" next-candidates --project-root "$book" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"blocked_longform_lifecycle_migration_required"'* ]]
  # 结构化 status 保留在 stdout JSON 中，不得依赖 stderr 报程序错误。
  [[ "$output" != *'Exit code'* ]]
}

@test "real protocol errors still surface non-zero while expected blocks stay exit 0" {
  # P1.2 验证点：只有真实异常（脚本错误、协议不可解析等）才返回非零；
  # 预期阻断仍是 exit 0。这里用同一个 book 对比两类状态。
  # 真实错误：apply-result 指向不存在的工作流 -> blocked_task_authority_missing（非白名单，exit 2）。
  printf '{"workflow_id":"nonexistent-p1-2-probe"}' > "$BOOK/garbage.json"
  run node "$REPO/scripts/workflow-state-machine.js" apply-result --project-root "$BOOK" --result "$BOOK/garbage.json" --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"status":"blocked_task_authority_missing"'* ]]

  # 对照：预期阻断（白名单）仍 exit 0。重置一个能进入 menu-handled 状态的命令路径。
  run node "$REPO/scripts/workflow-state-machine.js" next-candidates --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
}
