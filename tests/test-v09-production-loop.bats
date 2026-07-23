#!/usr/bin/env bats

setup() {
    export REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export FIXTURE="$REPO_ROOT/tests/fixtures/v09-production-loop"
    export WORKDIR="$(mktemp -d)"
    mkdir -p "$WORKDIR"
}

@test "oh-story-doctor reports valid fixture" {
    cp -R "$FIXTURE/valid-book" "$WORKDIR/book"

    set +e
    output="$(node "$REPO_ROOT/scripts/oh-story-doctor.js" "$WORKDIR/book" --json 2>&1)"
    status="$?"
    set -e

    [ "$status" -eq 0 ]
    printf '%s' "$output" | node -e 'let input=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", chunk => input += chunk); process.stdin.on("end", () => { const report = JSON.parse(input); if (report.schemaVersion !== "0.9.0") process.exit(1); if (report.status !== "pass") process.exit(1); });'
}

@test "oh-story-doctor writes doctor report" {
    cp -R "$FIXTURE/valid-book" "$WORKDIR/book"

    node "$REPO_ROOT/scripts/oh-story-doctor.js" "$WORKDIR/book" --write

    [ -f "$WORKDIR/book/追踪/doctor-report.json" ]
    node -e 'const fs=require("fs"); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p,"utf8")); if (x.status !== "pass") process.exit(1)' "$WORKDIR/book/追踪/doctor-report.json"
}

@test "story-schema-build creates valid schema files" {
    cp -R "$FIXTURE/valid-book" "$WORKDIR/book"

    node "$REPO_ROOT/scripts/story-schema-build.js" "$WORKDIR/book" --write
    node "$REPO_ROOT/scripts/story-schema-validate.js" "$WORKDIR/book"

    [ -f "$WORKDIR/book/追踪/schema/story-state.json" ]
    [ -f "$WORKDIR/book/追踪/schema/chapter-index.jsonl" ]
}

@test "current-contract-build creates current chapter contract" {
    cp -R "$FIXTURE/valid-book" "$WORKDIR/book"

    node "$REPO_ROOT/scripts/current-contract-build.js" "$WORKDIR/book" --chapter 1 --write

    [ -f "$WORKDIR/book/追踪/schema/current-contract.json" ]
    node -e 'const fs=require("fs"); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p,"utf8")); if (x.chapterNo !== 1) process.exit(1); if (!x.mustInclude.length) process.exit(1)' "$WORKDIR/book/追踪/schema/current-contract.json"
}

@test "current-contract-build projects an accepted matching quality result" {
    mkdir -p "$WORKDIR/book/大纲" "$WORKDIR/book/追踪/章节契约" "$WORKDIR/book/追踪/workflow/tasks/wf-long-1/result-packets"
    cat > "$WORKDIR/book/大纲/细纲_第001章.md" <<'EOF_OUTLINE'
# 第001章
- 核心事件：林昭保存调度记录并继续追查。
- 目标情绪：疑虑转为主动。
#### 情节安排
1. 林昭打开手机保存调度记录，因此确认旧账号仍在使用。
2. 她拨打旧同事电话，拿到需要继续调查的新地址。
#### 质量触发
- 激活标签：悬念推进
#### 呈现与连续性
- 可见证据：调度记录和通话录音。
- 前置承接：承接上一章的异常调度。
- 本章变化：林昭从怀疑转为掌握追查入口。
- 后续债务：新地址的主人尚未现身。
EOF_OUTLINE
    cat > "$WORKDIR/book/追踪/章节契约/第001章.md" <<'EOF_CONTRACT'
# 第001章契约
- 必须出现：林昭保存调度记录。
EOF_CONTRACT
    hash="$(shasum -a 256 "$WORKDIR/book/大纲/细纲_第001章.md" | awk '{print $1}')"
    cat > "$WORKDIR/book/追踪/workflow/tasks/wf-long-1/result-packets/detail_outline_review.result.json" <<EOF_RESULT
{"status":"pass","workflow_id":"wf-long-1","outline_path":"大纲/细纲_第001章.md","outline_sha256":"$hash","activated_dimensions":["C5_suspense_progression"],"contract_projection":["B1：必须写成场景。","可见证据：调度记录和通话录音。"],"memory_projection":[{"kind":"promise","dimension":"C5_suspense_progression","workflow_id":"wf-long-1","outline_sha256":"$hash","source_path":"大纲/细纲_第001章.md","source_kind":"canonical","valid_from":"chapter-001","evidence":"新地址的主人尚未现身。"}],"execution":{"completed_at":"2026-07-17T00:00:00.000Z"}}
EOF_RESULT

    node "$REPO_ROOT/scripts/current-contract-build.js" "$WORKDIR/book" --chapter 1 --quality-result 追踪/workflow/tasks/wf-long-1/result-packets/detail_outline_review.result.json --write

    node -e 'const fs=require("fs"); const x=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(x.gate.status!=="pass" || x.qualityGate.status!=="pass" || !x.mustInclude.some(v=>/可见证据/.test(v)) || x.memoryProjection[0].source_kind!=="canonical") process.exit(1)' "$WORKDIR/book/追踪/schema/current-contract.json"
}

@test "current-contract-build carries the accepted narrative contract chain" {
    mkdir -p "$WORKDIR/book/大纲" "$WORKDIR/book/追踪/章节契约" "$WORKDIR/book/追踪/workflow/tasks/wf-long-chain/result-packets"
    cat > "$WORKDIR/book/大纲/细纲_第001章.md" <<'EOF_OUTLINE'
# 第001章
- 核心事件：林昭保存调度记录并继续追查。
- 目标情绪：疑虑转为主动。
#### 情节安排
1. 林昭打开手机保存调度记录，因此确认旧账号仍在使用。
2. 她拨打旧同事电话，拿到需要继续调查的新地址。
#### 质量触发
- 激活标签：悬念推进
#### 呈现与连续性
- 可见证据：调度记录和通话录音。
- 前置承接：承接上一章的异常调度。
- 本章变化：林昭从怀疑转为掌握追查入口。
- 后续债务：新地址的主人尚未现身。
#### 剧情单元合同
- 剧情单元ID：PU-V01-001
- 单元位置：1/4
- 本章读者问题：旧账号为什么仍在使用？
- 本章可见回报：林昭拿到新地址。
- 关键转折：旧同事承认账号被人接管。
- 本章净变化：林昭从被动怀疑转为主动追查。
- 继承钩子责任：继续追查 P-旧账号水印。
- 终局储备动作：不动用终极身份底牌。
EOF_OUTLINE
    printf '# 第001章契约\n- 必须出现：林昭保存调度记录。\n' > "$WORKDIR/book/追踪/章节契约/第001章.md"
    hash="$(shasum -a 256 "$WORKDIR/book/大纲/细纲_第001章.md" | awk '{print $1}')"
    node - "$REPO_ROOT/scripts/lib/detail-outline-quality.js" "$WORKDIR/book/大纲/细纲_第001章.md" "$hash" "$WORKDIR/book/追踪/workflow/tasks/wf-long-chain/result-packets/detail_outline_review.result.json" <<'NODE'
const fs = require('fs');
const qualityLib = require(process.argv[2]);
const outline = fs.readFileSync(process.argv[3], 'utf8');
const quality = qualityLib.evaluateDetailOutline({ text: outline, workflowId: 'wf-long-chain', outlinePath: '大纲/细纲_第001章.md' });
quality.status = 'pass';
quality.outline_sha256 = process.argv[4];
quality.execution.completed_at = '2026-07-20T00:00:00.000Z';
fs.writeFileSync(process.argv[5], JSON.stringify(quality));
NODE

    node "$REPO_ROOT/scripts/current-contract-build.js" "$WORKDIR/book" --chapter 1 --quality-result 追踪/workflow/tasks/wf-long-chain/result-packets/detail_outline_review.result.json --write

    node -e 'const x=require(process.argv[1]); if(x.plotUnit.id!=="PU-V01-001" || x.plotUnit.beatPosition!=="1/4" || x.readerExperience.readerQuestion.indexOf("旧账号")<0 || x.terminalReserve.action.indexOf("不动用")<0) process.exit(1)' "$WORKDIR/book/追踪/schema/current-contract.json"
}

@test "current-contract-build fails a stale quality result for a new-format outline" {
    mkdir -p "$WORKDIR/book/大纲" "$WORKDIR/book/追踪/章节契约" "$WORKDIR/book/追踪"
    cat > "$WORKDIR/book/大纲/细纲_第001章.md" <<'EOF_OUTLINE'
# 第001章
#### 质量触发
- 激活标签：悬念推进
#### 呈现与连续性
- 可见证据：记录。
EOF_OUTLINE
    printf '# 第001章契约\n- 必须出现：记录。\n' > "$WORKDIR/book/追踪/章节契约/第001章.md"
    hash="$(shasum -a 256 "$WORKDIR/book/大纲/细纲_第001章.md" | awk '{print $1}')"
    printf '{"status":"pass","outline_path":"大纲/细纲_第001章.md","outline_sha256":"%s"}' "$hash" > "$WORKDIR/book/追踪/quality.json"
    printf '\n- 后续债务：记录被删除。\n' >> "$WORKDIR/book/大纲/细纲_第001章.md"

    node "$REPO_ROOT/scripts/current-contract-build.js" "$WORKDIR/book" --chapter 1 --quality-result 追踪/quality.json --json > "$WORKDIR/contract.json"

    node -e 'const fs=require("fs"); const x=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(x.gate.status!=="fail" || !x.gate.blockingFindings.some(v=>v.code==="detail_outline_quality_stale")) process.exit(1)' "$WORKDIR/contract.json"
}

@test "story schema accepts legacy beat sheets and rejects invalid quality gate status" {
    cp -R "$FIXTURE/valid-book" "$WORKDIR/book"
    node "$REPO_ROOT/scripts/story-schema-build.js" "$WORKDIR/book" --write
    mkdir -p "$WORKDIR/book/追踪/schema/beat-sheets"
    cat > "$WORKDIR/book/追踪/schema/beat-sheets/第001章.json" <<'EOF_BEAT'
{"schemaVersion":"0.8.0","chapterId":"第001章","beats":[{"id":"B1","type":"conflict","summary":"主角拒绝错误任务。"}]}
EOF_BEAT
    node "$REPO_ROOT/scripts/story-schema-validate.js" "$WORKDIR/book"
    node - "$WORKDIR/book/追踪/schema/beat-sheets/第001章.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const beatSheet = JSON.parse(fs.readFileSync(file, 'utf8'));
beatSheet.qualityGate = {
  version: 'detail_outline_quality_v1',
  status: 'revise',
  outlinePath: '大纲/细纲_第001章.md',
  outlineSha256: 'a'.repeat(64),
  activatedDimensions: ['C5_suspense_progression'],
};
fs.writeFileSync(file, JSON.stringify(beatSheet));
NODE
    run node "$REPO_ROOT/scripts/story-schema-validate.js" "$WORKDIR/book"
    [ "$status" -ne 0 ]
    [[ "$output" == *"qualityGate.status"* ]]
}

@test "story schema builds stable plot units without inventing ids for legacy outlines" {
    mkdir -p "$WORKDIR/book/大纲/第1卷" "$WORKDIR/book/正文/第1卷" "$WORKDIR/book/追踪/章节契约/第1卷"
    cat > "$WORKDIR/book/大纲/第1卷/细纲_第001章.md" <<'EOF_ONE'
# 第001章
- 剧情单元ID：PU-V01-001
- 单元位置：1/2
- 本章读者问题：谁在使用旧账号？
- 本章可见回报：拿到第一段登录记录。
- 终局储备动作：不动用幕后身份底牌。
EOF_ONE
    cat > "$WORKDIR/book/大纲/第1卷/细纲_第002章.md" <<'EOF_TWO'
# 第002章
- 剧情单元ID：PU-V01-001
- 单元位置：2/2
- 本章读者问题：登录记录指向谁？
- 本章可见回报：锁定中间人。
- 终局储备动作：只推进线索，不揭最终主使。
EOF_TWO
    printf '# 第001章\n正文。\n' > "$WORKDIR/book/正文/第1卷/第001章_开端.md"
    printf '# 契约\n' > "$WORKDIR/book/追踪/章节契约/第1卷/第001章.md"
    printf '# 契约\n' > "$WORKDIR/book/追踪/章节契约/第1卷/第002章.md"

    node "$REPO_ROOT/scripts/story-schema-build.js" "$WORKDIR/book" --write --json > "$WORKDIR/schema.json"

    [ -f "$WORKDIR/book/追踪/schema/plot-units.jsonl" ]
    node - "$WORKDIR/book/追踪/schema/plot-units.jsonl" <<'NODE'
const fs = require('fs');
const units = fs.readFileSync(process.argv[2], 'utf8').trim().split(/\n/).map(JSON.parse);
if (units.length !== 1) throw new Error(JSON.stringify(units));
const unit = units[0];
if (unit.id !== 'PU-V01-001' || unit.planningMode !== 'hard' || unit.planningState !== 'active_locked_prefix') throw new Error(JSON.stringify(unit));
if (unit.chapters.length !== 2 || unit.chapters[0].beatPosition !== '1/2' || unit.chapters[1].beatPosition !== '2/2') throw new Error(JSON.stringify(unit));
NODE
}

@test "context-pack-build writes minimal chapter context pack" {
    cp -R "$REPO_ROOT/tests/fixtures/longform-stability-mini" "$WORKDIR/book"
    mkdir -p "$WORKDIR/book/追踪/交接包"
    cat > "$WORKDIR/book/追踪/交接包/第001章_to_第002章.md" <<'EOF_HANDOFF'
# 第001章_to_第002章交接包
- 必须继承：江临已经拒绝错误任务，异常水印仍未解决。
- 禁止事项：不得让异常水印提前消失。
EOF_HANDOFF

    node "$REPO_ROOT/scripts/context-pack-build.js" "$WORKDIR/book" --chapter 2 --write --json > "$WORKDIR/context-pack.json"

    [ -f "$WORKDIR/book/追踪/context-pack/第002章.json" ]
    node -e '
      const fs=require("fs");
      const x=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      if (x.schemaVersion !== "0.10.0") process.exit(1);
      if (x.target.chapterNo !== 2) process.exit(1);
      if (!x.sourceFiles.outline || !x.sourceFiles.currentContract || !x.sourceFiles.previousHandoff) process.exit(1);
      if (!x.summary.mustCarryForward.some(v => v.includes("异常水印"))) process.exit(1);
      if (!x.summary.characterState.some(v => v.includes("江临"))) process.exit(1);
      if (!x.summary.openForeshadows.some(v => v.includes("异常水印"))) process.exit(1);
    ' "$WORKDIR/book/追踪/context-pack/第002章.json"
}

@test "scan-artifact-build converts markdown scan report into v0.8 artifacts" {
    mkdir -p "$WORKDIR/scan"

    node "$REPO_ROOT/scripts/scan-artifact-build.js" \
        "$FIXTURE/manual-scan/起点-新书榜.md" \
        --outdir "$WORKDIR/scan" \
        --platform qidian \
        --channel male \
        --list-name new-book \
        --type long \
        --capture-mode manual

    node "$REPO_ROOT/scripts/scan-json-validate.js" "$WORKDIR/scan"
    [ -f "$WORKDIR/scan/scan-metadata.json" ]
    [ -f "$WORKDIR/scan/ranking-items.jsonl" ]
    [ -f "$WORKDIR/scan/trend-signals.json" ]
    [ -f "$WORKDIR/scan/topic-candidates.json" ]
}

@test "story-long-write skill references v0.9 production loop" {
    grep -q "node scripts/current-contract-build.js" "$REPO_ROOT/src/internal-skills/story-long-write/SKILL.md"
    grep -q "node scripts/context-pack-build.js" "$REPO_ROOT/src/internal-skills/story-long-write/SKILL.md"
    grep -q "context-pack.md" "$REPO_ROOT/src/internal-skills/story-long-write/SKILL.md"
    grep -q "node scripts/oh-story-doctor.js" "$REPO_ROOT/src/internal-skills/story-long-write/SKILL.md"
    grep -q "gate.status" "$REPO_ROOT/src/internal-skills/story-long-write/SKILL.md"
    grep -q "v0-9-production-loop.md" "$REPO_ROOT/src/internal-skills/story-long-write/SKILL.md"
}

@test "story-review uses context pack for batch continuity" {
    grep -q "Context Pack" "$REPO_ROOT/src/internal-skills/story-review/SKILL.md"
    grep -q "node scripts/context-pack-build.js" "$REPO_ROOT/src/internal-skills/story-review/SKILL.md"
    grep -q "追踪/context-pack" "$REPO_ROOT/src/internal-skills/story-review/SKILL.md"
}

@test "single-directory oh-story bundle contract includes v0.9 scripts" {
    node - "$REPO_ROOT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const manifest = require(path.join(root, 'config', 'novel-assistant-bundle-files.json'));
for (const name of [
  'oh-story-doctor.js',
  'story-schema-build.js',
  'current-contract-build.js',
  'context-pack-build.js',
  'scan-artifact-build.js',
]) {
  if (!manifest.scriptFiles.includes(name)) throw new Error(`unmanaged v0.9 script: ${name}`);
  if (!fs.existsSync(path.join(root, 'skills', 'novel-assistant', 'scripts', name))) {
    throw new Error(`missing bundled v0.9 script: ${name}`);
  }
}
NODE
}
