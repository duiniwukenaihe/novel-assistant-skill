#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/context-assembler.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/memory" "$PROJECT/追踪/context-pack" "$PROJECT/追踪/交接包" "$PROJECT/追踪/章节契约/第1卷" "$PROJECT/正文/第1卷" "$PROJECT/大纲/第1卷" "$PROJECT/设定/作者风格"
    cat > "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"char.shen-qi","type":"character","title":"沈七","aliases":["男主","沈七"],"triggers":["沈七","蛋炒饭"],"scope":{"book":"current","volume":"第1卷","chapterRange":"第001-010章"},"priority":90,"tokenBudget":160,"content":"沈七用做饭和读心术破局，当前不能暴露系统真相。","constraints":["系统真相不得在第010章前直说。"],"sourceRefs":[{"path":"设定/人物/沈七.md","hash":"sha256:a","note":"confirmed"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
{"id":"hook.f025","type":"hook","title":"绿珠读心空白","aliases":["F025"],"triggers":["绿珠","读心空白"],"scope":{"book":"current","volume":"第1卷","chapterRange":"第003-008章"},"priority":80,"tokenBudget":120,"content":"绿珠被读心时出现空白，暗示精神力异常。","constraints":["第003章只能铺垫，不得解释血脉来源。"],"sourceRefs":[{"path":"追踪/伏笔.md","hash":"sha256:b","note":"confirmed"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
{"id":"loc.unrelated","type":"location","title":"远海仙岛","aliases":["远海仙岛"],"triggers":["海","仙岛"],"scope":{"book":"current","volume":"第9卷","chapterRange":"第701-750章"},"priority":10,"tokenBudget":120,"content":"后期地图，不应在第一卷激活。","constraints":[],"sourceRefs":[{"path":"设定/世界观/远海仙岛.md","hash":"sha256:c","note":"future"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL
    cat > "$PROJECT/追踪/memory/active-cast.json" <<'JSON'
{"range":"第1卷/第003章","presentCharacters":["沈七","绿珠"],"offstageCharacters":["莫青山"],"knowledgeBoundaries":[{"character":"绿珠","knows":["沈七会做饭"],"doesNotKnow":["沈七系统真相"]}],"activeHooks":["F025"],"blockedReveals":["系统真相"]}
JSON
    cat > "$PROJECT/追踪/章节契约/第1卷/第003章.md" <<'MD'
# 第003章契约
- 必须写沈七用蛋炒饭稳住局面。
- 绿珠出现读心空白。
MD
    cat > "$PROJECT/追踪/交接包/第002章_to_第003章.md" <<'MD'
# 交接
- 沈七刚发现绿珠读心有异常。
MD
    cat > "$PROJECT/设定/作者风格/禁用表达.md" <<'MD'
# 禁用表达
- 不要写总结式“他终于明白”。
MD
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "context assembler reports missing durable authority for an existing focus pointer" {
    mkdir -p "$PROJECT/追踪/workflow"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-missing","task_dir":"追踪/workflow/tasks/wf-missing","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_task_authority_missing') throw new Error(JSON.stringify(out));
NODE
}

@test "context assembler selects relevant entries and writes compact packets" {
    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node -e '
      const fs = require("fs");
      const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const expectedProjectRoot = process.argv[2];
      const expectedTask = process.argv[3];
      const expectedTarget = process.argv[4];
      if (out.status !== "ok") process.exit(1);
      if (out.projectRoot !== expectedProjectRoot) process.exit(2);
      if (out.task !== expectedTask) process.exit(3);
      if (out.target !== expectedTarget) process.exit(4);
      if (!out.packetJson || !fs.existsSync(out.packetJson)) process.exit(5);
      if (!out.packetMd || !fs.existsSync(out.packetMd)) process.exit(6);
      const ids = out.selectedEntries.map(x => x.id).sort();
      if (!ids.includes("char.shen-qi")) process.exit(7);
      if (!ids.includes("hook.f025")) process.exit(8);
      if (ids.includes("loc.unrelated")) process.exit(9);
      if (!out.omittedEntries.some(x => x.id === "loc.unrelated")) process.exit(10);
      const packet = JSON.parse(fs.readFileSync(out.packetJson, "utf8"));
      for (const key of ["workflow_id", "estimated_total_tokens", "selected", "omitted", "stale", "quarantined", "conflicts"]) {
        if (!(key in packet)) process.exit(11);
      }
    ' "$TMP_DIR/out.json" "$PROJECT" "write_chapter" "第1卷/第003章"

    grep -q "hard_constraints" "$PROJECT/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context.md"
    grep -q "active_cast" "$PROJECT/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context.md"
    grep -q "沈七" "$PROJECT/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context.md"
    grep -q "绿珠" "$PROJECT/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context.md"
    ! grep -q "远海仙岛" "$PROJECT/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context.md"
}

@test "context assembler filters chapter range memory to the target chapter" {
    cat > "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"chapter.current","type":"story_context","title":"当前章节记忆","triggers":[],"scope":{"book":"current","volume":"第1卷","chapterRange":"第002章"},"priority":90,"tokenBudget":100,"content":"只应在第002章注入。","constraints":[],"sourceRefs":[],"status":"active"}
{"id":"chapter.previous","type":"story_context","title":"上一章节记忆","triggers":[],"scope":{"book":"current","volume":"第1卷","chapterRange":"第001章"},"priority":90,"tokenBudget":100,"content":"不得泄漏到第002章。","constraints":[],"sourceRefs":[],"status":"active"}
{"id":"volume.legacy","type":"story_context","title":"遗留卷级记忆","triggers":[],"scope":{"book":"current","volume":"第1卷"},"priority":90,"tokenBudget":100,"content":"无章节范围的遗留卷级记忆仍应可用。","constraints":[],"sourceRefs":[],"status":"active"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第002章" --budget 1200 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(JSON.stringify(out));
const ids=out.selectedEntries.map(item=>item.id);
if(!ids.includes('chapter.current')) throw new Error(JSON.stringify(ids));
if(ids.includes('chapter.previous')) throw new Error(JSON.stringify(ids));
if(!ids.includes('volume.legacy')) throw new Error(JSON.stringify(ids));
NODE
}

@test "context assembler blocks contradictory active entries" {
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"char.shen-qi.conflict","type":"character","title":"沈七冲突","aliases":["沈七"],"triggers":["沈七"],"scope":{"book":"current","volume":"第1卷","chapterRange":"第003章"},"priority":95,"tokenBudget":100,"content":"沈七必须在第003章公开系统真相。","constraints":["第003章必须公开系统真相。"],"sourceRefs":[{"path":"设定/冲突.md","hash":"sha256:d","note":"conflict"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node -e '
      const fs = require("fs");
      const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const expectedProjectRoot = process.argv[2];
      const expectedTask = process.argv[3];
      const expectedTarget = process.argv[4];
      if (out.status !== "blocked_memory_conflict") process.exit(1);
      if (out.projectRoot !== expectedProjectRoot) process.exit(2);
      if (out.task !== expectedTask) process.exit(3);
      if (out.target !== expectedTarget) process.exit(4);
      if (!out.conflicts || out.conflicts.length === 0) process.exit(5);
      if (!out.conflicts[0].entryIds.includes("char.shen-qi")) process.exit(6);
    ' "$TMP_DIR/out.json" "$PROJECT" "write_chapter" "第1卷/第003章"
}

@test "context assembler quarantines irrelevant polluted lore without blocking relevant packet" {
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"bad.loop","type":"rule","title":"污染条目","aliases":["污染"],"triggers":["沈七"],"scope":{"book":"current","volume":"第9卷","chapterRange":"第001章"},"priority":99,"tokenBudget":300,"content":"成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则。","constraints":[],"sourceRefs":[{"path":"设定/污染.md","hash":"sha256:z","note":"bad"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node -e "
      const fs = require('fs');
      const out = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      if (out.status !== 'ok') process.exit(1);
      const packet = JSON.parse(fs.readFileSync(out.packetJson, 'utf8'));
      if (!packet.quarantined.some(x => x.id === 'bad.loop')) process.exit(2);
      if (packet.relevant_lore.some(x => x.id === 'bad.loop')) process.exit(3);
      if (!packet.omitted.some(x => x.id === 'bad.loop' && x.reason === 'polluted')) process.exit(4);
    " "$TMP_DIR/out.json"
}

@test "context assembler blocks relevant polluted lore without injecting it" {
    cat > "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"bad.loop","type":"rule","title":"污染条目","aliases":["污染"],"triggers":["沈七"],"scope":{"book":"current","volume":"第1卷","chapterRange":"第003章"},"priority":99,"tokenBudget":300,"content":"成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则。","constraints":[],"sourceRefs":[{"path":"设定/污染.md","hash":"sha256:z","note":"bad"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node -e "
      const fs = require('fs');
      const out = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      if (out.status !== 'blocked_output_pollution') process.exit(1);
      if (!out.quarantined.some(x => x.id === 'bad.loop')) process.exit(2);
      if (!out.omitted.some(x => x.id === 'bad.loop' && x.reason === 'polluted')) process.exit(3);
      if (out.packetJson || out.packetMd) process.exit(4);
    " "$TMP_DIR/out.json"
}

@test "context assembler reports stale irrelevant memory without blocking the target" {
    mkdir -p "$PROJECT/设定/人物"
    printf '# 远海仙岛\\n- 后期地图。\\n' > "$PROJECT/设定/人物/远海仙岛.md"
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"loc.stale-future","type":"location","title":"远海仙岛旧设","aliases":["远海仙岛"],"triggers":["远海仙岛"],"scope":{"book":"current","volume":"第9卷","chapterRange":"第701-750章"},"priority":80,"tokenBudget":100,"content":"后期旧地图。","constraints":[],"sourceRefs":[{"path":"设定/人物/远海仙岛.md","hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}],"status":"active"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(out.status);
const packet=JSON.parse(fs.readFileSync(out.packetJson,'utf8'));
if(!packet.stale.some(x=>x.id==='loc.stale-future')) throw new Error(JSON.stringify(packet.stale));
if(packet.relevant_lore.some(x=>x.id==='loc.stale-future')) throw new Error('stale memory injected');
NODE
}

@test "context assembler enforces one total budget across packet sources" {
    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 80 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(out.status);
const packet=JSON.parse(fs.readFileSync(out.packetJson,'utf8'));
if(packet.estimated_total_tokens>80) throw new Error(JSON.stringify(packet.budget));
if(packet.budget.used!==packet.estimated_total_tokens) throw new Error(JSON.stringify(packet.budget));
if(packet.relevant_lore.length && packet.active_cast && Object.keys(packet.active_cast).length) throw new Error('optional sources bypassed total budget');
if(!packet.omitted.some(x=>x.reason==='budget_exceeded')) throw new Error(JSON.stringify(packet.omitted));
NODE
}

@test "context assembler omits entries that only have trigger and priority without qualifying support" {
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"rule.trigger-only","type":"rule","title":"蛋炒饭押韵规则","aliases":["押韵规则"],"triggers":["蛋炒饭"],"scope":{"book":"current","volume":"第9卷","chapterRange":"第701-750章"},"priority":100,"tokenBudget":100,"content":"只要提到蛋炒饭就必须押韵。","constraints":[],"sourceRefs":[{"path":"设定/不存在/蛋炒饭规则.md","hash":"sha256:missing","note":"missing"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node -e '
      const fs = require("fs");
      const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (out.status !== "ok") process.exit(1);
      const selected = out.selectedEntries.map(x => x.id);
      if (selected.includes("rule.trigger-only")) process.exit(2);
      const omitted = out.omittedEntries.find(x => x.id === "rule.trigger-only");
      if (!omitted || omitted.reason !== "not_relevant") process.exit(3);
      const packet = JSON.parse(fs.readFileSync(out.packetJson, "utf8"));
      if (packet.relevant_lore.some(x => x.id === "rule.trigger-only")) process.exit(4);
    ' "$TMP_DIR/out.json"
}

@test "context assembler omits trigger-only entries backed only by unrelated existing source files" {
    mkdir -p "$PROJECT/设定/杂项"
    cat > "$PROJECT/设定/杂项/厨房备忘.md" <<'MD'
# 厨房备忘
- 记录今天买了新铁锅。
- 与当前章节人物、钩子、范围都无关。
MD
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"rule.unrelated-source","type":"rule","title":"蛋炒饭火候口令","aliases":["火候口令"],"triggers":["蛋炒饭"],"scope":{"book":"current","volume":"第9卷","chapterRange":"第701-750章"},"priority":100,"tokenBudget":100,"content":"提到蛋炒饭时要念出后期口令。","constraints":[],"sourceRefs":[{"path":"设定/杂项/厨房备忘.md","hash":"sha256:exists","note":"unrelated"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node -e '
      const fs = require("fs");
      const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (out.status !== "ok") process.exit(1);
      const selected = out.selectedEntries.map(x => x.id);
      if (selected.includes("rule.unrelated-source")) process.exit(2);
      const omitted = out.omittedEntries.find(x => x.id === "rule.unrelated-source");
      if (!omitted || omitted.reason !== "not_relevant") process.exit(3);
      const packet = JSON.parse(fs.readFileSync(out.packetJson, "utf8"));
      if (packet.relevant_lore.some(x => x.id === "rule.unrelated-source")) process.exit(4);
    ' "$TMP_DIR/out.json"
}

@test "context assembler blocks polluted assembled packet inputs before writing packet" {
    cat > "$PROJECT/设定/作者风格/禁用表达.md" <<'MD'
# 禁用表达
成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则成长规则。
MD

    rm -f "$PROJECT/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context.json" "$PROJECT/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context.md"
    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node -e '
      const fs = require("fs");
      const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const project = process.argv[2];
      if (out.status !== "blocked_output_pollution") process.exit(1);
      if (!Array.isArray(out.findings) || out.findings.length === 0) process.exit(2);
      if (!out.findings.some(f => f.path === "packet.author_voice")) process.exit(3);
      const base = project + "/追踪/context-pack/write_chapter-第1卷-第003章.assembled-context";
      if (fs.existsSync(base + ".json")) process.exit(4);
      if (fs.existsSync(base + ".md")) process.exit(5);
    ' "$TMP_DIR/out.json" "$PROJECT"
}

@test "context assembler injects active workflow RPD and explicit task context files" {
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-short-001" "$PROJECT/短篇/480万红本"
    cat > "$PROJECT/追踪/workflow/tasks/wf-short-001/task.json" <<'JSON'
{
  "workflow_id": "wf-short-001",
  "workflow_type": "short_write",
  "user_goal": "重写短篇第一节",
  "scope": "短篇/480万红本/第001节",
  "task_dir": "追踪/workflow/tasks/wf-short-001",
  "context_paths": {
    "rpd": "追踪/workflow/tasks/wf-short-001/rpd.md",
    "context_jsonl": "追踪/workflow/tasks/wf-short-001/context.jsonl"
  }
}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-short-001","task_dir":"追踪/workflow/tasks/wf-short-001","focused_at":"2026-07-12T00:00:00.000Z","state_version":0}
JSON
    cat > "$PROJECT/追踪/workflow/tasks/wf-short-001/rpd.md" <<'MD'
# RPD：480万红本第一节
- 读者承诺：现实公园相亲角质感，先委屈后反击。
- 边界：保留用户改过的第一节精华，不整篇覆盖。
MD
    cat > "$PROJECT/短篇/480万红本/素材卡.md" <<'MD'
# 素材卡
- 核心因子：28 万标价反转到 280 万。
- 吴淑芬：刻薄、好面子，抱着小黑板炫耀字好。
MD
    cat > "$PROJECT/短篇/480万红本/小节Brief_第001节.md" <<'MD'
# 第001节 Brief
- 必须写真实公园相亲角，不写虚假半人高黑板。
- 电话在吴淑芬手机上，不能凭空跳到主角手机。
MD
    cat > "$PROJECT/追踪/workflow/tasks/wf-short-001/context.jsonl" <<'JSONL'
{"kind":"material_card","path":"短篇/480万红本/素材卡.md","reason":"当前短篇素材卡"}
{"kind":"section_brief","path":"短篇/480万红本/小节Brief_第001节.md","reason":"当前小节 Brief"}
{"kind":"unsafe","path":"../outside.md","reason":"越界路径必须跳过"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task short_write --target "短篇/480万红本/第001节" --budget 1600 --json > "$TMP_DIR/out.json"

    node -e '
      const fs = require("fs");
      const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (out.status !== "ok") process.exit(1);
      if (!out.taskContext || out.taskContext.workflow_id !== "wf-short-001") process.exit(2);
      if (!out.taskContext.loadedPaths.includes("追踪/workflow/tasks/wf-short-001/rpd.md")) process.exit(3);
      if (!out.taskContext.loadedPaths.includes("短篇/480万红本/素材卡.md")) process.exit(4);
      if (!out.taskContext.loadedPaths.includes("短篇/480万红本/小节Brief_第001节.md")) process.exit(5);
      if (!out.taskContext.warnings.some(x => x.code === "unsafe_path")) process.exit(6);
      const packet = JSON.parse(fs.readFileSync(out.packetJson, "utf8"));
      if (!packet.task_context) process.exit(7);
      if (!packet.task_context.rpd.includes("现实公园相亲角质感")) process.exit(8);
      if (!packet.task_context.entries.some(x => x.kind === "material_card" && x.content.includes("28 万标价"))) process.exit(9);
      if (!packet.task_context.entries.some(x => x.kind === "section_brief" && x.content.includes("电话在吴淑芬手机上"))) process.exit(10);
    ' "$TMP_DIR/out.json"

    PACKET_MD="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).packetMd)' "$TMP_DIR/out.json")"
    grep -q "## task_context" "$PACKET_MD"
    grep -q "现实公园相亲角质感" "$PACKET_MD"
    grep -q "28 万标价" "$PACKET_MD"
    grep -q "电话在吴淑芬手机上" "$PACKET_MD"
    ! grep -q "outside" "$PACKET_MD"
}

@test "context assembler blocks relevant memory whose source hash is stale" {
    mkdir -p "$PROJECT/设定/人物"
    printf '# 沈七\n- 当前仍未公开系统。\n' > "$PROJECT/设定/人物/沈七.md"
    cat > "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"char.stale","type":"character","title":"沈七","aliases":["沈七"],"triggers":["沈七"],"scope":{"book":"current","volume":"第1卷","chapterRange":"第001-010章"},"priority":99,"tokenBudget":120,"content":"沈七已经公开系统真相。","constraints":[],"sourceRefs":[{"path":"设定/人物/沈七.md","hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","note":"old"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_memory_stale') throw new Error(out.status);
if(!out.staleEntryIds.includes('char.stale')) throw new Error(JSON.stringify(out));
NODE
}

@test "context assembler blocks stale migrated memory until the explicit migration command refreshes it" {
    MIGRATE="$REPO/scripts/memory-migrate.js"
    printf '# 伏笔\n- F025：绿珠读心空白，当前只铺垫。\n' > "$PROJECT/追踪/伏笔.md"
    node "$MIGRATE" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json > "$TMP_DIR/migrate.json"
    printf '# 伏笔\n- F025：绿珠读心空白，仍只铺垫；第008章前不得解释血脉来源。\n' > "$PROJECT/追踪/伏笔.md"

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_memory_stale') throw new Error(JSON.stringify(out));
if(!out.memoryRefresh || out.memoryRefresh.status!=='blocked_untrusted_legacy_migration') throw new Error(JSON.stringify(out.memoryRefresh));
NODE
}

@test "context assembler excludes memory projected by a non-head task branch" {
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-head" "$PROJECT/追踪/workflow/families/tf-write"
    cat > "$PROJECT/追踪/workflow/tasks/wf-head/task.json" <<'JSON'
{"workflow_id":"wf-head","workflow_type":"long_write","task_family_id":"tf-write","task_dir":"追踪/workflow/tasks/wf-head","scope":"第1卷第003章"}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-head","task_dir":"追踪/workflow/tasks/wf-head","focused_at":"2026-07-12T00:00:00.000Z","state_version":0}
JSON
    cat > "$PROJECT/追踪/workflow/families/tf-write/family.json" <<'JSON'
{"task_family_id":"tf-write","head_workflow_id":"wf-head","branches":[{"workflow_id":"wf-old","status":"paused"},{"workflow_id":"wf-head","status":"active","is_head":true}]}
JSON
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"hook.branch-old","type":"hook","title":"绿珠旧分支","triggers":["绿珠"],"scope":{"book":"current","volume":"第1卷","chapterRange":"第003章"},"priority":99,"tokenBudget":100,"content":"旧分支要求立即公开血脉来源。","constraints":[],"sourceRefs":[],"status":"active","provenance":{"task_family_id":"tf-write","workflow_id":"wf-old","branch_id":"wf-old","stage_attempt_id":"sa-old","acceptance_status":"accepted"}}
{"id":"hook.branch-head","type":"hook","title":"绿珠主分支","triggers":["绿珠"],"scope":{"book":"current","volume":"第1卷","chapterRange":"第003章"},"priority":99,"tokenBudget":100,"content":"当前主分支只铺垫读心空白。","constraints":[],"sourceRefs":[],"status":"active","provenance":{"task_family_id":"tf-write","workflow_id":"wf-head","branch_id":"wf-head","stage_attempt_id":"sa-head","acceptance_status":"accepted"}}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1400 --json > "$TMP_DIR/out.json"
    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(JSON.stringify(out));
const ids=out.selectedEntries.map(item=>item.id);
if(!ids.includes('hook.branch-head')||ids.includes('hook.branch-old')) throw new Error(JSON.stringify({ids,omitted:out.omittedEntries}));
if(!out.omittedEntries.some(item=>item.id==='hook.branch-old'&&item.reason==='non_head_branch')) throw new Error(JSON.stringify(out.omittedEntries));
NODE
}

@test "volume outline review receives book and volume memory but not unrelated chapter drafts" {
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"book.promise","type":"story_context","title":"全书承诺","triggers":[],"memoryLayer":"book","scope":{"book":"book-001"},"priority":99,"tokenBudget":100,"content":"全书承诺是经营成长与身份反转。","constraints":[],"sourceRefs":[],"status":"active"}
{"id":"volume.two","type":"story_context","title":"第二卷方向","triggers":[],"memoryLayer":"volume","scope":{"book":"book-001","volume":"第2卷"},"priority":98,"tokenBudget":100,"content":"第二卷围绕新店扩张。","constraints":[],"sourceRefs":[],"status":"active"}
{"id":"chapter.one.draft","type":"story_context","title":"第一卷章节正文","triggers":[],"memoryLayer":"chapter","scope":{"book":"book-001","volume":"第1卷","chapterRange":"第001章"},"priority":100,"tokenBudget":100,"content":"第1卷/第001章正文不应进入第二卷卷纲审阅。","constraints":[],"sourceRefs":[{"path":"正文/第1卷/第001章_起点.md"}],"status":"active"}
{"id":"pending.volume","type":"story_context","title":"未接受卷记忆","triggers":[],"memoryLayer":"volume","scope":{"book":"book-001","volume":"第2卷"},"priority":100,"tokenBudget":100,"content":"未接受内容不得激活。","constraints":[],"sourceRefs":[],"status":"active","acceptanceStatus":"pending"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --workflow-id wf-volume-review --lifecycle-node volume_outline_review --book-id book-001 --volume 第2卷 --budget 1200 --json > "$TMP_DIR/lifecycle.json"

    node - "$TMP_DIR/lifecycle.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(JSON.stringify(out));
const expected={node:'volume_outline_review',book_id:'book-001',volume_id:'第2卷',stage_id:'',chapter_id:'',task_family_id:'',workflow_id:'wf-volume-review'};
if(JSON.stringify(out.lifecycle_context)!==JSON.stringify(expected)) throw new Error(JSON.stringify(out.lifecycle_context));
if(out.memory_sources.map(group=>group.layer).join(',')!=='book,volume,task') throw new Error(JSON.stringify(out.memory_sources));
const ids=out.memory_sources.flatMap(group=>group.entries.map(entry=>entry.id));
if(!ids.includes('book.promise')||!ids.includes('volume.two')) throw new Error(JSON.stringify(ids));
if(ids.includes('chapter.one.draft')||ids.includes('pending.volume')) throw new Error(JSON.stringify(ids));
if(!out.omittedEntries.some(item=>item.id==='chapter.one.draft'&&item.reason==='lifecycle_layer_excluded')) throw new Error(JSON.stringify(out.omittedEntries));
if(!out.omittedEntries.some(item=>item.id==='pending.volume'&&item.reason==='unaccepted_source')) throw new Error(JSON.stringify(out.omittedEntries));
const packet=JSON.parse(fs.readFileSync(out.packetJson,'utf8'));
if(JSON.stringify(packet.memory_sources)!==JSON.stringify(out.memory_sources)) throw new Error('packet lost layered sources');
NODE

    ! grep -q '第1卷/第001章正文' "$PROJECT/追踪/context-pack/wf-volume-review-volume_outline_review-第2卷.assembled-context.md"
}

@test "context assembler uses the durable workflow snapshot instead of the UI focus" {
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-background" "$PROJECT/追踪/workflow/tasks/wf-focus"
    cat > "$PROJECT/追踪/workflow/tasks/wf-background/task.json" <<'JSON'
{"workflow_id":"wf-background","workflow_type":"long_write","task_dir":"追踪/workflow/tasks/wf-background","state_version":2,"scope":"第1卷/第003章","context_paths":{"rpd":"追踪/workflow/tasks/wf-background/rpd.md","context_jsonl":"追踪/workflow/tasks/wf-background/context.jsonl"},"lifecycle_context":{"workflow_id":"wf-background","node":"chapter_brief","volume_id":"第1卷","chapter_id":"第003章"}}
JSON
    cat > "$PROJECT/追踪/workflow/tasks/wf-focus/task.json" <<'JSON'
{"workflow_id":"wf-focus","workflow_type":"review_repair","task_dir":"追踪/workflow/tasks/wf-focus","state_version":7,"scope":"第9卷/第701章","context_paths":{"rpd":"追踪/workflow/tasks/wf-focus/rpd.md","context_jsonl":"追踪/workflow/tasks/wf-focus/context.jsonl"},"lifecycle_context":{"workflow_id":"wf-focus","node":"review_batch","volume_id":"第9卷","chapter_id":"第701章"}}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-focus","task_dir":"追踪/workflow/tasks/wf-focus","focused_at":"2026-07-15T00:00:00.000Z","state_version":7}
JSON
    printf 'BACKGROUND_RPD: 只为第003章生成章节 Brief。\n' > "$PROJECT/追踪/workflow/tasks/wf-background/rpd.md"
    printf 'FOCUS_RPD: 这是第九卷审阅任务，不能注入后台写作。\n' > "$PROJECT/追踪/workflow/tasks/wf-focus/rpd.md"
    : > "$PROJECT/追踪/workflow/tasks/wf-background/context.jsonl"
    : > "$PROJECT/追踪/workflow/tasks/wf-focus/context.jsonl"

    node "$SCRIPT" --project-root "$PROJECT" --task long_write:chapter_brief --target "第1卷/第003章" --workflow-id wf-background --task-dir "追踪/workflow/tasks/wf-background" --budget 1200 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(JSON.stringify(out));
if(out.workflowId!=='wf-background') throw new Error(JSON.stringify(out));
if(out.taskContext.workflow_id!=='wf-background') throw new Error(JSON.stringify(out.taskContext));
const packet=JSON.parse(fs.readFileSync(out.packetJson,'utf8'));
if(!packet.task_context.rpd.includes('BACKGROUND_RPD')) throw new Error(JSON.stringify(packet.task_context));
if(packet.task_context.rpd.includes('FOCUS_RPD')) throw new Error(JSON.stringify(packet.task_context));
if(packet.lifecycle_context.workflow_id!=='wf-background') throw new Error(JSON.stringify(packet.lifecycle_context));
NODE
}

@test "context assembler rejects an explicit task directory that does not belong to the workflow" {
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-background" "$PROJECT/追踪/workflow/tasks/wf-focus"
    cat > "$PROJECT/追踪/workflow/tasks/wf-background/task.json" <<'JSON'
{"workflow_id":"wf-background","workflow_type":"long_write","task_dir":"追踪/workflow/tasks/wf-background","state_version":2,"scope":"第1卷/第003章"}
JSON
    cat > "$PROJECT/追踪/workflow/tasks/wf-focus/task.json" <<'JSON'
{"workflow_id":"wf-focus","workflow_type":"review_repair","task_dir":"追踪/workflow/tasks/wf-focus","state_version":2,"scope":"第9卷/第701章"}
JSON

    node "$SCRIPT" --project-root "$PROJECT" --task long_write:chapter_brief --target "第1卷/第003章" --workflow-id wf-background --task-dir "追踪/workflow/tasks/wf-focus" --budget 1200 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_task_authority_mismatch') throw new Error(JSON.stringify(out));
NODE
}
