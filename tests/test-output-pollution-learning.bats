#!/usr/bin/env bats
# tests/test-output-pollution-learning.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/output-pollution-check.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "output pollution check detects repeated report filler" {
    report="$TMP_DIR/report.md"
    cat > "$report" <<'EOF'
# 修复方案

S2-1 ch100 云华修真进度阈值：修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected repeated filler to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!report.findings.length) throw new Error('expected findings');
const first = report.findings[0];
if (first.type !== 'consecutive-repeat') throw new Error(`wrong type: ${first.type}`);
if (first.phrase !== '修真进度阈值') throw new Error(`wrong phrase: ${first.phrase}`);
if (first.count < 6) throw new Error(`repeat count too low: ${first.count}`);
NODE
}

@test "output pollution check detects long cultivation phrase loops" {
    report="$TMP_DIR/report.md"
    cat > "$report" <<'EOF'
# 修真界境界线核验建议

修真界境界过渡 4 节点对齐（SSOT）修真界境界线核验建议

修真界境界过渡 4 节点对齐修真界境界线 SSOT 修真界境界过渡 4 节点对齐已修真界境界过渡 4 节点对齐确立修真界原则修真界境界过渡 4 节点对齐修真界境界线修真界境界过渡 4 节点对齐修真界境界过渡 4 节点对齐修真界境界过渡 4 节点对齐修真界境界过渡 4 节点对齐修真界境界过渡 4 节点对齐修真界境界过渡 4 节点对齐
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected long cultivation phrase loop to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hit = report.findings.find(f => f.phrase === '修真界境界过渡4节点对齐');
if (!hit) throw new Error(`expected 修真界境界过渡4节点对齐 finding: ${JSON.stringify(report.findings)}`);
if (hit.count < 6) throw new Error(`repeat count too low: ${hit.count}`);
NODE
}

@test "output pollution check detects short cultivation token floods" {
    report="$TMP_DIR/report.md"
    cat > "$report" <<'EOF'
# 修真进度/伏笔批次报告

修真进度核对已完成，NPC 化神名单待补。

修真进度 修真节拍 修真界原则 修真伏笔 修真节点 修真主线 修真境界 修真伏笔 修真过渡 修真核查
修真进度 修真节拍 修真界原则 修真伏笔 修真节点 修真主线 修真境界 修真伏笔 修真过渡 修真核查
修真进度 修真节拍 修真界原则 修真伏笔 修真节点 修真主线 修真境界 修真伏笔 修真过渡 修真核查
修真进度 修真节拍 修真界原则 修真伏笔 修真节点 修真主线 修真境界 修真伏笔 修真过渡 修真核查
修真进度 修真节拍 修真界原则 修真伏笔 修真节点 修真主线 修真境界 修真伏笔 修真过渡 修真核查
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected short cultivation token flood to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hit = report.findings.find(f => f.type === 'domain-token-flood' && f.phrase === '修真');
if (!hit) throw new Error(`expected 修真 token flood: ${JSON.stringify(report.findings)}`);
if (hit.count < 40) throw new Error(`repeat count too low: ${hit.count}`);
NODE
}

@test "output pollution check detects visible-choice SSOT token loops" {
    report="$TMP_DIR/visible-reply.md"
    cat > "$report" <<'EOF'
# 下一步候选

1. 修复伏笔
2. 继续写下一章
3. 修真SSOT修真SSOT修真SSOT修真SSOT修真SSOT修真SSOT修真SSOT

也修真SSOT直接告诉我修真SSOT修真SSOT修真SSOT。
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected visible choice SSOT loop to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hit = report.findings.find(f => f.type === 'domain-token-flood' && f.phrase === '修真SSOT');
if (!hit) throw new Error(`expected 修真SSOT token flood: ${JSON.stringify(report.findings)}`);
if (hit.count < 4) throw new Error(`repeat count too low: ${hit.count}`);
NODE
}

@test "output pollution check detects provider artifacts and fake completion sentinels" {
    report="$TMP_DIR/report.md"
    cat > "$report" <<'EOF'
# 批次报告

修真进度/伏笔 批次 1 报告已落盘并通过 AI 痕迹检测。
]minimax[]<]minimax[[
CREATED REPORT FILE COMPLETE
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected provider artifact and fake completion sentinel to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!report.findings.find(f => f.type === 'provider-artifact' && /minimax/.test(f.phrase))) {
  throw new Error(`expected minimax provider artifact: ${JSON.stringify(report.findings)}`);
}
if (!report.findings.find(f => f.type === 'fake-completion-sentinel' && /CREATED REPORT FILE COMPLETE/.test(f.phrase))) {
  throw new Error(`expected fake completion sentinel: ${JSON.stringify(report.findings)}`);
}
NODE
}

@test "output health gate detects repeated lines and engineering term leaks" {
    report="$TMP_DIR/report.md"
    cat > "$report" <<'EOF'
# 审查输出

本章优势：任务描述需要补充细纲，优势在于任务描述清晰。
本章优势：任务描述需要补充细纲，优势在于任务描述清晰。
本章优势：任务描述需要补充细纲，优势在于任务描述清晰。
本章优势：任务描述需要补充细纲，优势在于任务描述清晰。
本章优势：任务描述需要补充细纲，优势在于任务描述清晰。

正文里还混入了细纲、任务描述、优势、执行范围、审稿人、作者输出格式等工程词。
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected output health gate to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!report.findings.find(f => f.type === 'repeated-line')) {
  throw new Error(`expected repeated-line finding: ${JSON.stringify(report.findings)}`);
}
if (!report.findings.find(f => f.type === 'engineering-term-leak')) {
  throw new Error(`expected engineering-term-leak finding: ${JSON.stringify(report.findings)}`);
}
NODE
}

@test "output health gate does not treat normal strengths lists as engineering leaks" {
    report="$TMP_DIR/healthy-report.md"
    cat > "$report" <<'EOF'
# 选题评估

## 优势
1. 优势：主角目标清楚。
2. 优势：开篇冲突直接。
3. 优势：女主反应有差异。
4. 优势：经营线能提供日常爽点。
5. 优势：感情线和事业线能互相推动。
6. 优势：章尾期待明确。

## 风险
节奏需要控制，不要把设定解释堆到正文里。
EOF

    node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (report.findings.find(f => f.type === 'engineering-term-leak')) {
  throw new Error(`normal strengths list should not be an engineering-term leak: ${JSON.stringify(report.findings)}`);
}
NODE
}

@test "output pollution check learns detected pollution into project rules" {
    mkdir -p "$TMP_DIR/book/追踪/审查报告"
    report="$TMP_DIR/book/追踪/审查报告/修复方案.md"
    cat > "$report" <<'EOF'
# 修复建议

必须先处理修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值。
EOF

    ! node "$SCRIPT" --learn --project-root "$TMP_DIR/book" --json "$report" > "$TMP_DIR/out.json"

    [ -f "$TMP_DIR/book/追踪/schema/output-pollution-rules.jsonl" ]
    [ -f "$TMP_DIR/book/追踪/schema/user-style-rules.jsonl" ]
    [ -f "$TMP_DIR/book/设定/作者风格/禁用表达.md" ]
    grep -q "修真进度阈值" "$TMP_DIR/book/追踪/schema/output-pollution-rules.jsonl"
    grep -q '"category":"模型退化"' "$TMP_DIR/book/追踪/schema/user-style-rules.jsonl"
    grep -q '"blockedStatus":"blocked_model_degradation"' "$TMP_DIR/book/追踪/schema/user-style-rules.jsonl"
    grep -q "修真进度阈值" "$TMP_DIR/book/设定/作者风格/禁用表达.md"
}

@test "output pollution check learns arbitrary repeated model degradation loops" {
    mkdir -p "$TMP_DIR/book/追踪/审查报告"
    report="$TMP_DIR/book/追踪/审查报告/退化循环.md"
    cat > "$report" <<'EOF'
# 退化循环

灵根跃迁触发灵根跃迁触发灵根跃迁触发灵根跃迁触发灵根跃迁触发灵根跃迁触发灵根跃迁触发
EOF

    ! node "$SCRIPT" --learn --project-root "$TMP_DIR/book" --json "$report" > "$TMP_DIR/out.json"

    grep -q "灵根跃迁触发" "$TMP_DIR/book/追踪/schema/output-pollution-rules.jsonl"
    grep -q '"category":"模型退化"' "$TMP_DIR/book/追踪/schema/output-pollution-rules.jsonl"
    grep -q '"blockedStatus":"blocked_model_degradation"' "$TMP_DIR/book/追踪/schema/output-pollution-rules.jsonl"
    grep -q "下次生成前先检查该规则" "$TMP_DIR/book/设定/作者风格/禁用表达.md"
}

@test "output pollution check catches visible reply loop before workflow reuse" {
    report="$TMP_DIR/visible-loop.md"
    cat > "$report" <<'EOF'
修真界境界线收束 6 章回炉是一个大事务。
修真界境界线收束修真界境界线收束修真界境界线收束修真界境界线收束修真界境界线收束修真界境界线收束
EOF

    ! node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hit = report.findings.find(f => f.type === 'consecutive-repeat' && f.phrase === '修真界境界线收束');
if (!hit) throw new Error(`expected visible reply loop finding: ${JSON.stringify(report.findings)}`);
if (hit.count < 6) throw new Error(`repeat count too low: ${hit.count}`);
NODE
}

@test "output pollution check blocks internal workflow narration in visible replies" {
    report="$TMP_DIR/visible-tool-narration.md"
    cat > "$report" <<'EOF'
先快速看一下项目目录与工作流状态，再给出本次回炉进入阶段的最小必要回复。
我并行读取关键的设定/大纲/工作流状态文件，确认"卖点需重构"具体卡在哪。
我先读取正文落到哪一节、看素材/角色小传是否还在，再给最小必要修订方案。
继续读 §3-§8 的实质。
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected internal workflow narration to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hit = report.findings.find(f => f.type === 'internal-workflow-narration');
if (!hit) throw new Error(`expected internal-workflow-narration finding: ${JSON.stringify(report.findings)}`);
if (hit.count < 3) throw new Error(`hit count too low: ${hit.count}`);
NODE
}

@test "output pollution check blocks encoded gibberish blobs in visible replies" {
    report="$TMP_DIR/visible-encoded-gibberish.md"
    cat > "$report" <<'EOF'
本轮拆文继续推进。
CuKPuiBCYXRjaCAyIOWFqOmDqOWujOaIkOOAguiuqeaIkeaxh+aAu+WujOaIkOaDheWGkuKPuiBCYXRjaCAyIOWFqOmDqOWujOaIkOOAguiuqeaIkeaxh+aAu+WujOaIkOaDheWGkuKPuiBCYXRjaCAyIOWFqOmDqOWujOaIkOOAguiuqeaIkeaxh+aAu+WujOaIkOaDheWG
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected encoded gibberish blob to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hit = report.findings.find(f => f.type === 'encoded-gibberish-blob');
if (!hit) throw new Error(`expected encoded-gibberish-blob finding: ${JSON.stringify(report.findings)}`);
NODE
}

@test "output pollution check hard-blocks terminal escape residues in visible replies" {
    report="$TMP_DIR/visible-terminal-escape-residues.md"
    printf '%s\n' \
        '本轮审阅已完成。[e~[请继续下一批。' \
        '终端光标控制残片：[?25l' \
        $'真实 ANSI 残片：\033[31m错误颜色未清理。' > "$report"

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected terminal escape residues to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hits = report.findings.filter(f => f.type === 'terminal-escape-residue');
if (hits.length !== 1 || hits[0].count !== 3) throw new Error(`expected all terminal escape residues: ${JSON.stringify(report.findings)}`);
if (hits.some(f => f.blockedStatus !== 'blocked_output_pollution')) {
  throw new Error(`terminal escape residues must hard-block: ${JSON.stringify(hits)}`);
}
NODE
}

@test "output pollution check blocks SSOT jargon in user-visible replies" {
    report="$TMP_DIR/visible-ssot-jargon.md"
    cat > "$report" <<'EOF'
境界 SSOT 1-50：炼气（杂役→灵根觉醒），第50章雷霆激活【超级高潮】。
下一步做 SSOT 对齐建议。
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected SSOT jargon leak to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hit = report.findings.find(f => f.type === 'user-facing-jargon-leak' && f.phrase === 'SSOT');
if (!hit) throw new Error(`expected SSOT jargon finding: ${JSON.stringify(report.findings)}`);
if (!/权威设定/.test(hit.message)) throw new Error(`expected Chinese replacement guidance: ${hit.message}`);
if (hit.blockedStatus !== 'rewrite_visible_reply') throw new Error(`jargon should be rewrite-only, not hard blocked: ${JSON.stringify(hit)}`);
NODE
}

@test "output pollution check blocks common English engineering jargon in visible replies" {
    report="$TMP_DIR/visible-engineering-jargon.md"
    cat > "$report" <<'EOF'
下一步先写批 001 的 Context Pack，再进入 4 视角 full 审查。
跳过 preflight 可以节省 token；如果触发 recap，就从 checkpoint 继续。
EOF

    if node "$SCRIPT" --json "$report" > "$TMP_DIR/out.json"; then
        echo "expected English engineering jargon to fail"
        cat "$TMP_DIR/out.json"
        return 1
    fi

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const hits = report.findings.filter(f => f.type === 'user-facing-jargon-leak').map(f => f.phrase);
for (const phrase of ['Context Pack', 'full 审查', 'preflight', 'token', 'recap', 'checkpoint']) {
  if (!hits.includes(phrase)) throw new Error(`missing jargon finding for ${phrase}: ${JSON.stringify(report.findings)}`);
}
if (report.findings.some(f => f.type === 'user-facing-jargon-leak' && f.blockedStatus !== 'rewrite_visible_reply')) {
  throw new Error(`engineering jargon should be rewrite-only: ${JSON.stringify(report.findings)}`);
}
NODE
}

@test "review workflows gate direct visible long replies before answering" {
    grep -q "可见长回复污染门禁" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "直接回复用户前" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "visible_reply_draft" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "不得把污染文本继续输出到聊天窗口" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "领域术语循环" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "可见长回复污染门禁" "$REPO/src/internal-skills/story-long-write/references/workflow-review-feedback.md"
    grep -q "直接回复用户前" "$REPO/src/internal-skills/story-long-write/references/workflow-review-feedback.md"
    grep -q "前置自检硬停" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "污染段#N" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "源污染隔离" "$REPO/src/internal-skills/story-review/SKILL.md"
}

@test "all report-producing modules use global visible reply pollution gate" {
    files=(
        "$REPO/src/internal-skills/story/SKILL.md"
        "$REPO/src/internal-skills/story-long-analyze/SKILL.md"
        "$REPO/src/internal-skills/story-long-scan/SKILL.md"
        "$REPO/src/internal-skills/story-short-analyze/SKILL.md"
        "$REPO/src/internal-skills/story-short-scan/SKILL.md"
        "$REPO/src/internal-skills/story-import/SKILL.md"
        "$REPO/src/internal-skills/story-deslop/SKILL.md"
        "$REPO/src/internal-skills/story-cover/SKILL.md"
        "$REPO/src/internal-skills/story-short-write/SKILL.md"
        "$REPO/src/internal-skills/story-long-write/SKILL.md"
    )

    for file in "${files[@]}"; do
        grep -q "全局可见长回复污染门禁" "$file"
        grep -q "visible_reply_draft" "$file"
        grep -q "output-pollution-check.js" "$file"
        grep -q "不得直接输出长报告" "$file"
    done
}

@test "interactive choices are treated as visible output and must be short clean options" {
    grep -q "交互选项污染门禁" "$REPO/src/internal-skills/story/SKILL.md"
    grep -q "选项描述" "$REPO/src/internal-skills/story/SKILL.md"
    grep -q "120" "$REPO/src/internal-skills/story/SKILL.md"
    grep -q "output-pollution-check.js" "$REPO/src/internal-skills/story/SKILL.md"
    grep -q "不得把长报告、修复清单或污染段塞进选项描述" "$REPO/src/internal-skills/story/SKILL.md"

    grep -q "交互选项污染门禁" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "next_candidates" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "option_payload_draft" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "最终可见回复" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "visible_reply_draft" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "领域术语循环" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "也可以直接输入你的意见" "$REPO/src/internal-skills/story-workflow/SKILL.md"

    grep -q "交互选项污染门禁" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "选项描述不得承载修复报告正文" "$REPO/src/internal-skills/story-review/SKILL.md"
}

@test "workflow output safety contract forbids internal narration and gibberish in visible replies" {
    grep -q "内部工作流旁白" "$REPO/src/internal-skills/story-workflow/references/output-safety-contract.md"
    grep -q "我先读取" "$REPO/src/internal-skills/story-workflow/references/output-safety-contract.md"
    grep -q "编码/乱码块" "$REPO/src/internal-skills/story-workflow/references/output-safety-contract.md"
    grep -q "internal-workflow-narration" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "encoded-gibberish-blob" "$REPO/src/internal-skills/story-workflow/SKILL.md"
}

@test "user visible workflow terminology localizes SSOT to Chinese" {
    grep -q "用户可见术语必须中文化" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "境界设定：第 1-50 章维持炼气阶段" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "设定基准对齐建议" "$REPO/src/internal-skills/story-long-write/SKILL.md"
    grep -q "目标权威设定" "$REPO/src/internal-skills/story-long-write/references/workflow-review-feedback.md"
    grep -q "设定基准词表" "$REPO/src/internal-skills/story-long-write/references/workflow-review-feedback.md"

    ! rg -n "SSOT 对齐建议|目标 SSOT|SSOT 词表|境界 SSOT|修真 SSOT" \
        "$REPO/src/internal-skills/story-workflow/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/references/workflow-review-feedback.md"
}

@test "top-level router quarantines polluted source phrases before visible replies" {
    grep -q "可见回复前置健康自检" "$REPO/skills/novel-assistant/SKILL.md"
    grep -q "污染源隔离" "$REPO/skills/novel-assistant/SKILL.md"
    grep -q "污染段#N" "$REPO/skills/novel-assistant/SKILL.md"
    grep -q "blocked-recovery-template.js --status blocked_model_degradation" "$REPO/skills/novel-assistant/SKILL.md"

    grep -q "可见回复前置自检" "$REPO/src/internal-skills/story/SKILL.md"
    grep -q "污染段#N" "$REPO/src/internal-skills/story/SKILL.md"
    grep -q "blocked-recovery-template.js --status blocked_model_degradation" "$REPO/src/internal-skills/story/SKILL.md"

    grep -q "前置自检比落盘门禁更早" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "污染源隔离" "$REPO/src/internal-skills/story-workflow/SKILL.md"
}

@test "global visible reply gate defines recovery not just blocking" {
    for file in \
        "$REPO/src/internal-skills/story/SKILL.md" \
        "$REPO/src/internal-skills/story-review/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/references/workflow-review-feedback.md"; do
        grep -q "污染恢复协议" "$file"
        grep -q "最后可信事实点" "$file"
        grep -q "丢弃污染段" "$file"
        grep -q "分块重写" "$file"
        grep -q "连续 2 次" "$file"
        grep -q "新会话" "$file"
        grep -q "paused_after_output_pollution" "$file"
    done
}

@test "review and revision workflows run output pollution gate before report completion" {
    grep -q "output-pollution-check.js" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "输出污染" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "output-pollution-check.js" "$REPO/src/internal-skills/story-long-write/references/revision-impact-analysis.md"
    grep -q "output-pollution-check.js" "$REPO/src/internal-skills/story-long-write/references/workflow-revision.md"
}

@test "review workflow rejects fake passed reports with raw artifacts or token floods" {
    grep -q "provider-artifact" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "fake-completion-sentinel" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "domain-token-flood" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "AI 痕迹检测通过不能替代 output-pollution-check.js" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "自称已通过" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "作废污染报告" "$REPO/src/internal-skills/story-review/SKILL.md"
}

@test "workflows front-stop model degradation loops before writing" {
    for file in \
        "$REPO/src/internal-skills/story-workflow/SKILL.md" \
        "$REPO/src/internal-skills/story-review/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"; do
        grep -q "blocked_model_degradation" "$file"
        grep -q "领域词无间隔重复" "$file"
        grep -q "最后可信断点" "$file"
        grep -q "缩小任务粒度重试一次" "$file"
        grep -q "不得写入正文/报告" "$file"
        grep -q "不得继续 Write/Edit" "$file"
    done
}

@test "runtime skill markdown does not embed raw model-degradation poison examples" {
    bad_pattern='修真修真|修真SSOT修真|修真进度阈值修真进度阈值|修真界境界线收束修真界境界线收束|修真界境界过渡 4 节点对齐修真界境界过渡|节拍节拍'
    if rg -n "$bad_pattern" "$REPO/src/internal-skills" "$REPO/skills/novel-assistant/SKILL.md" --glob '*.md' > "$TMP_DIR/runtime-poison.txt"; then
        cat "$TMP_DIR/runtime-poison.txt"
        return 1
    fi
}

@test "workflows preload learned model degradation rules before long generation" {
    for file in \
        "$REPO/src/internal-skills/story-workflow/SKILL.md" \
        "$REPO/src/internal-skills/story-review/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/SKILL.md"; do
        grep -q "output-pollution-rules.jsonl" "$file"
        grep -q "生成前先读取已学习模型退化规则" "$file"
        grep -q "blockedStatus=blocked_model_degradation" "$file"
        grep -q "前置阻断" "$file"
    done
}

@test "workflows handle provider output sensitive api errors without raw retry" {
    for file in \
        "$REPO/src/internal-skills/story-workflow/SKILL.md" \
        "$REPO/src/internal-skills/story-review/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/SKILL.md" \
        "$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"; do
        grep -q "output new_sensitive" "$file"
        grep -q "1027" "$file"
        grep -q "blocked_provider_sensitive" "$file"
        grep -q "不得原样重试" "$file"
        grep -q "用户输入继续也不得直接恢复原任务" "$file"
        grep -q "不得调用 Agent/TaskCreate 继续撞同一任务" "$file"
        grep -q "降低显性描写" "$file"
        grep -q "保留最后可信断点" "$file"
    done
}

@test "setup and bundle deploy output pollution runtime script" {
    grep -q "output-pollution-check.js" "$REPO/scripts/build-oh-story-bundle.sh"
    grep -q "output-pollution-check.js" "$REPO/src/internal-skills/story-setup/SKILL.md"
    grep -q "output-pollution-check.js" "$REPO/scripts/check-story-setup-deployment.sh"
}
