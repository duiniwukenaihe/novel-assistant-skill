#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ENTRY="$REPO/skills/novel-assistant/SKILL.md"
    RUNTIME="$REPO/skills/novel-assistant/references/entry-runtime-contract.md"
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    EDGE_CASES="$REPO/src/internal-skills/story/references/router-edge-cases.md"
}

@test "single entry preserves public routing coverage" {
    grep -Fq '读取 `references/internal-skills/story/SKILL.md`' "$ENTRY"

    for anchor in \
        '开书引导路由' \
        '已有书门禁' \
        '短篇写作路由补充' \
        '更新确认优先于工作流编排' \
        '迁移章节结构' \
        'story-review' \
        'story-long-scan' \
        'story-long-analyze' \
        'story-deslop' \
        '改自然'; do
        grep -Fq "$anchor" "$ROUTER"
    done
}

@test "entry defers runtime details to its conditional contract" {
    [ -f "$RUNTIME" ]
    grep -Fq 'references/entry-runtime-contract.md' "$ENTRY"
    grep -Fq '仅当需要解释启动自检、更新确认、两层更新或宿主执行能力时' "$ENTRY"
    grep -Fq 'expected_reply_set' "$RUNTIME"
    ! grep -Fq 'expected_reply_set' "$ENTRY"
    [ "$(wc -l < "$ENTRY")" -le 100 ]
}

@test "router defers accumulated intent exceptions to its conditional reference" {
    [ -f "$EDGE_CASES" ]
    grep -Fq 'references/router-edge-cases.md' "$ROUTER"
    grep -Fq '仅当短回复、裸更新、单字母阶段续跑、短篇去 AI 味或低置信度纠偏命中时' "$ROUTER"
    grep -Fq '裸更新歧义' "$EDGE_CASES"
    ! grep -Fq '## 裸更新歧义' "$ROUTER"
    [ "$(wc -l < "$ROUTER")" -le 260 ]
}

@test "router maps every edge-sensitive intent to its required reference" {
    node - "$ROUTER" "$EDGE_CASES" <<'NODE'
const fs = require('fs');
const [routerPath, edgeCasesPath] = process.argv.slice(2);
const router = fs.readFileSync(routerPath, 'utf8');
const edgeCases = fs.readFileSync(edgeCasesPath, 'utf8');
function contract(text, name) {
  const match = text.match(new RegExp(`<!-- ${name}\\n([\\s\\S]*?)\\n${name} -->`));
  if (!match) throw new Error(`missing structured contract: ${name}`);
  return JSON.parse(match[1]);
}
const routeContract = contract(router, 'route-reference-contract');
const edgeContract = contract(edgeCases, 'edge-reference-contract');
const edgeByIntent = new Map(edgeContract.routes.map(route => [route.intent, route]));
for (const edge of edgeContract.routes) {
  if (!Array.isArray(edge.trigger_samples) || edge.trigger_samples.length === 0) throw new Error(`missing edge trigger samples: ${edge.intent}`);
  if (!edgeCases.includes(`## ${edge.contract_anchor}`)) throw new Error(`unreachable edge contract anchor: ${edge.contract_anchor}`);
  if (!router.includes(`| ${edge.intent} | \`references/router-edge-cases.md\` |`)) throw new Error(`missing human route mapping: ${edge.intent}`);
}
for (const route of routeContract.routes.filter(item => item.edge_intent)) {
  const edge = edgeByIntent.get(route.edge_intent);
  if (!edge) throw new Error(`missing edge trigger mapping: ${route.edge_intent}`);
}
NODE
}

@test "route reference resolver selects contracts from real user intent" {
    node - "$REPO" <<'NODE'
const childProcess = require('child_process');
const path = require('path');

const repo = process.argv[2];
const expectations = [
  { intent: '审阅 1-200 章', selectedRoute: 'review', references: ['story-workflow/SKILL.md', 'story/references/router-edge-cases.md', 'story-review/SKILL.md'] },
  { intent: '对当前完整短篇做只读生产验收', selectedRoute: 'short_review', references: ['story-workflow/SKILL.md', 'story-review/SKILL.md'] },
  { intent: '继续写下一章', selectedRoute: 'long_write', references: ['story-workflow/SKILL.md', 'story/references/router-edge-cases.md', 'story-long-write/SKILL.md'] },
  { intent: '短篇精修这一稿', selectedRoute: 'short_write', references: ['story-workflow/SKILL.md', 'story-short-write/SKILL.md'] },
  { intent: '更新写作协作环境', selectedRoute: 'update_check', references: ['references/entry-runtime-contract.md', 'story-setup/SKILL.md'] },
  { intent: '帮我概括这个故事的主题', selectedRoute: 'fallback_question', references: ['internal-skills/story/SKILL.md'] },
];

for (const [script, extraArgs] of [
  ['scripts/production-smoke-matrix.js', []],
  ['skills/novel-assistant/scripts/production-smoke-matrix.js', ['--bundle']],
]) {
  for (const expected of expectations) {
    const result = childProcess.spawnSync(process.execPath, [
      path.join(repo, script), '--repo-root', repo, '--route-reference', expected.intent, '--json', ...extraArgs,
    ], { encoding: 'utf8' });
    if (result.status !== 0) throw new Error(`${script}: ${result.stderr || result.stdout}`);
    const route = JSON.parse(result.stdout);
    if (route.selectedRoute !== expected.selectedRoute) throw new Error(`${script}: ${expected.intent} -> ${route.selectedRoute}`);
    if (JSON.stringify(route.selectedReferences) !== JSON.stringify(expected.references)) throw new Error(`${script}: ${expected.intent} -> ${JSON.stringify(route.selectedReferences)}`);
  }
}
NODE
}

@test "structured progressive references are reachable in source and bundle" {
    node - "$REPO" <<'NODE'
const fs = require('fs');
const path = require('path');
const repo = process.argv[2];
function contract(text, name) {
  const match = text.match(new RegExp(`<!-- ${name}\\n([\\s\\S]*?)\\n${name} -->`));
  if (!match) throw new Error(`missing structured contract: ${name}`);
  return JSON.parse(match[1]);
}
for (const layer of ['source', 'bundle']) {
  const base = layer === 'source' ? path.join(repo, 'src/internal-skills') : path.join(repo, 'skills/novel-assistant/references/internal-skills');
  const routerFile = path.join(base, 'story/SKILL.md');
  const edgeFile = path.join(base, 'story/references/router-edge-cases.md');
  const routes = contract(fs.readFileSync(routerFile, 'utf8'), 'route-reference-contract');
  const edges = contract(fs.readFileSync(edgeFile, 'utf8'), 'edge-reference-contract');
  const edgeIntents = new Set(edges.routes.map(route => route.intent));
  for (const route of [...routes.routes, routes.fallback]) {
    for (const reference of route.references) {
      let file;
      if (reference.startsWith('references/')) file = path.join(repo, 'skills/novel-assistant', reference);
      else if (reference.startsWith('internal-skills/')) {
        file = layer === 'source'
          ? path.join(repo, 'src', reference)
          : path.join(repo, 'skills/novel-assistant/references', reference);
      } else file = path.join(base, reference);
      if (!fs.existsSync(file)) throw new Error(`${layer}: unreachable reference ${reference}`);
    }
    if (route.edge_intent && !edgeIntents.has(route.edge_intent)) throw new Error(`${layer}: unmapped edge intent ${route.edge_intent}`);
  }
}
NODE
}
