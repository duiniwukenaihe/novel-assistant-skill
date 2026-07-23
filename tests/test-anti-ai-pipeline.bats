#!/usr/bin/env bash

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/anti-ai-diagnose.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "anti-ai diagnosis script classifies shortform AI flavor findings" {
    cat > "$TMP_DIR/short.md" <<'EOF'
本章我要写一个转折，读者会看到她深深的绝望。
她不是害怕，而是终于知道自己被卖了。
门外传来一声——很轻。
EOF

    node "$SCRIPT" --json --work-type=shortform "$TMP_DIR/short.md" > "$TMP_DIR/out.json"

    grep -q '"schemaVersion": "1.0.0"' "$TMP_DIR/out.json"
    grep -q '"workType": "shortform"' "$TMP_DIR/out.json"
    grep -q '"recommendedProfile": "shortform"' "$TMP_DIR/out.json"
    grep -q '"type": "engineering-leak"' "$TMP_DIR/out.json"
    grep -q '"type": "generic-emotion"' "$TMP_DIR/out.json"
    grep -q '"type": "negative-positive-flip"' "$TMP_DIR/out.json"
    grep -q '"type": "em-dash"' "$TMP_DIR/out.json"
    grep -q '"blocking"' "$TMP_DIR/out.json"
    grep -q '"strong"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis keeps a few functional Chinese em dashes advisory" {
    cat > "$TMP_DIR/functional-dashes.md" <<'EOF'
门外传来一声——很轻。
她终于说出那句话——这次由她自己决定。
EOF

    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$TMP_DIR/functional-dashes.md" > "$TMP_DIR/functional-dashes.json"

    node - "$TMP_DIR/functional-dashes.json" <<'NODE'
const fs=require('fs');const report=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const findings=report.files[0].findings.filter(item=>item.type==='em-dash');
if(findings.length!==2) throw new Error(JSON.stringify(findings));
if(findings.some(item=>item.severity!=='advisory')) throw new Error(JSON.stringify(findings));
if(report.files[0].summary.blocking!==0) throw new Error(JSON.stringify(report.files[0].summary));
NODE
}

@test "anti-ai diagnosis blocks dense or per-character dash abuse" {
    cat > "$TMP_DIR/dense-dashes.md" <<'EOF'
他抬头——没有说话。
门外——有人站着。
风声——贴着窗缝。
她的手——停在半空。
灯光——晃了一下。
本——系——统——开——始——提——示。
EOF

    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$TMP_DIR/dense-dashes.md" > "$TMP_DIR/dense-dashes.json"

    node - "$TMP_DIR/dense-dashes.json" <<'NODE'
const fs=require('fs');const report=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const findings=report.files[0].findings;
if(!findings.some(item=>item.type==='dash-density'&&item.severity==='blocking')) throw new Error(JSON.stringify(findings));
if(!findings.some(item=>item.type==='per-character-dash'&&item.severity==='blocking')) throw new Error(JSON.stringify(findings));
NODE
}

@test "anti-ai diagnosis sends moderate dash density to human review without blocking" {
    cat > "$TMP_DIR/review-dashes.md" <<'EOF'
他抬头——没有说话。
门外——有人站着。
风声——贴着窗缝。
她的手——停在半空。
灯光——晃了一下。
下一秒——门开了。
EOF

    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$TMP_DIR/review-dashes.md" > "$TMP_DIR/review-dashes.json"

    node - "$TMP_DIR/review-dashes.json" <<'NODE'
const fs=require('fs');const report=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const file=report.files[0];
const density=file.findings.find(item=>item.type==='dash-density');
if(!density||density.severity!=='advisory') throw new Error(JSON.stringify(file.findings));
if(file.summary.blocking!==0) throw new Error(JSON.stringify(file.summary));
NODE
}

@test "anti-ai diagnosis script classifies longform explanation voice" {
    cat > "$TMP_DIR/long.md" <<'EOF'
他终于明白，这意味着宗门内部的裂缝已经无法弥合。
这一夜，注定无人入眠。
EOF

    node "$SCRIPT" --json --work-type=longform "$TMP_DIR/long.md" > "$TMP_DIR/out.json"

    grep -q '"workType": "longform"' "$TMP_DIR/out.json"
    grep -q '"recommendedProfile": "longform"' "$TMP_DIR/out.json"
    grep -q '"type": "explanation-voice"' "$TMP_DIR/out.json"
    grep -q '"strong"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis keeps one contextual comparison advisory" {
    printf '%s\n' '沉默的代价不是我们两个人的事，是三千名员工的工资。' > "$TMP_DIR/contextual-comparison.md"
    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$TMP_DIR/contextual-comparison.md" > "$TMP_DIR/contextual-comparison.json"
    node - "$TMP_DIR/contextual-comparison.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const file=out.files[0];
const finding=file.findings.find((item)=>item.type==='negative-positive-flip');
if(!finding||finding.severity!=='advisory'||file.summary.blocking!==0) throw new Error(JSON.stringify(file));
NODE
}

@test "anti-ai diagnosis blocks ASCII quotes in Chinese fiction" {
    printf '%s\n' '她把合同推过来。"你自己看。"桌边的人都没说话。' > "$TMP_DIR/ascii-quotes.md"
    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$TMP_DIR/ascii-quotes.md" > "$TMP_DIR/ascii-quotes.json"
    grep -q '"type": "ascii-quote-style"' "$TMP_DIR/ascii-quotes.json"
    grep -q '"severity": "blocking"' "$TMP_DIR/ascii-quotes.json"
}

@test "anti-ai diagnosis script detects repeated model loops" {
    cat > "$TMP_DIR/loop.md" <<'EOF'
修真修真修真修真修真修真修真修真修真修真
EOF

    node "$SCRIPT" --json --work-type=unknown_fragment "$TMP_DIR/loop.md" > "$TMP_DIR/out.json"

    grep -q '"workType": "unknown_fragment"' "$TMP_DIR/out.json"
    grep -q '"recommendedProfile": "unknown_fragment"' "$TMP_DIR/out.json"
    grep -q '"type": "model-loop"' "$TMP_DIR/out.json"
    grep -q '"blocking"' "$TMP_DIR/out.json"
}

@test "output pollution check detects domain-token flood in repair summaries" {
    cat > "$TMP_DIR/repair-summary.md" <<'EOF'
修真高潮风格保护原则下开始修复。
修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍修真高潮修真节拍。
EOF

    status=0
    node "$REPO/scripts/output-pollution-check.js" --json "$TMP_DIR/repair-summary.md" > "$TMP_DIR/pollution.json" || status=$?

    [ "$status" -eq 1 ]
    grep -q '"type": "domain-token-flood"' "$TMP_DIR/pollution.json"
    grep -q '"phrase": "修真高潮"' "$TMP_DIR/pollution.json"
}

@test "anti-ai diagnosis script detects Chinese template shells and tool fingerprints" {
    cat > "$TMP_DIR/fingerprints.md" <<'EOF'
真正重要的是，这背后其实是一套底层逻辑。
总的来说，你觉得呢？
这里引用了 contentReference[oaicite:0]{index=0} 和 turn0search0。
链接是 https://example.com/?utm_source=chatgpt.com
[INSERT SOURCE URL]
EOF

    node "$SCRIPT" --json --work-type=unknown_fragment "$TMP_DIR/fingerprints.md" > "$TMP_DIR/out.json"

    grep -q '"type": "template-shell"' "$TMP_DIR/out.json"
    grep -q '"type": "tool-fingerprint-leak"' "$TMP_DIR/out.json"
    grep -q '"type": "placeholder-leak"' "$TMP_DIR/out.json"
    grep -q '"clusterScore"' "$TMP_DIR/out.json"
    grep -q '"clusterLevel": "high"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis script detects humanizer-inspired Chinese prose signals" {
    cat > "$TMP_DIR/humanizer_zh.md" <<'EOF'
好问题！您说得完全正确，这是一个复杂的话题。
根据我最后的训练更新，虽然具体细节有限，但行业专家认为这代表了一个关键转折点。
公司的未来看起来光明，激动人心的时代即将到来。
此外，它提供了无缝、直观和强大的体验。
EOF

    node "$SCRIPT" --json --work-type=unknown_fragment "$TMP_DIR/humanizer_zh.md" > "$TMP_DIR/out.json"

    grep -q '"type": "sycophantic-tone"' "$TMP_DIR/out.json"
    grep -q '"type": "knowledge-cutoff-disclaimer"' "$TMP_DIR/out.json"
    grep -q '"type": "vague-attribution"' "$TMP_DIR/out.json"
    grep -q '"type": "generic-positive-conclusion"' "$TMP_DIR/out.json"
    grep -q '"type": "ai-vocabulary"' "$TMP_DIR/out.json"
    grep -q '"qualityScore"' "$TMP_DIR/out.json"
    grep -q '"total"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis script supports fiction prose profile and fiction cliche signals" {
    cat > "$TMP_DIR/fiction.md" <<'EOF'
他不禁心中暗道，眼前这个女人太会骗人。
她嘴角微扬，缓缓说道："你猜。"
EOF

    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$TMP_DIR/fiction.md" > "$TMP_DIR/out.json"

    grep -q '"proseProfile": "fiction"' "$TMP_DIR/out.json"
    grep -q '"type": "fiction-cliche"' "$TMP_DIR/out.json"
    grep -q '"advisory"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis warns on dense corner quotes for Fanqie shortform" {
    cat > "$TMP_DIR/corner_quotes.md" <<'EOF'
「你凭什么替我决定？」
「我是你妈。」
「那你把我标价的时候，有没有问过我？」
「二十八万，少一分都不行。」
「我偏不。」
「你敢？」
EOF

    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$TMP_DIR/corner_quotes.md" > "$TMP_DIR/out.json"

    grep -q '"type": "corner-quote-density"' "$TMP_DIR/out.json"
    grep -q '"advisory"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis outline profile does not block legitimate outline engineering words" {
    cat > "$TMP_DIR/outline.md" <<'EOF'
本章目标：完成章节契约。
细纲：第一节压迫，第二节反击，下一章回收伏笔。
EOF

    node "$SCRIPT" --json --work-type=longform --prose-profile=outline "$TMP_DIR/outline.md" > "$TMP_DIR/out.json"

    grep -q '"proseProfile": "outline"' "$TMP_DIR/out.json"
    ! grep -q '"type": "engineering-leak"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis enables human voice protection from accepted project samples" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/设定/作者风格"
    cat > "$TMP_DIR/book/追踪/workflow/author-voice.json" <<'EOF'
{"schemaVersion":"1.0.0","sourceFiles":["accepted.md"],"voiceHints":["短句","生活物件"]}
EOF
    cat > "$TMP_DIR/book/设定/作者风格/优秀样章.md" <<'EOF'
我把碗放回桌上。
汤已经凉了，油花贴在碗沿，像一层没擦干净的旧账。
EOF
    cat > "$TMP_DIR/human_voice.md" <<'EOF'
我把碗放回桌上。
"你还想让我怎么忍？"我问。
母亲没看我，只把那张纸往前推了半寸。
EOF

    node "$SCRIPT" --json --project-root "$TMP_DIR/book" --work-type=shortform --prose-profile=fiction "$TMP_DIR/human_voice.md" > "$TMP_DIR/out.json"

    grep -q '"humanVoiceProtection"' "$TMP_DIR/out.json"
    grep -q '"mode": "minimal_repair"' "$TMP_DIR/out.json"
    grep -q '"author_voice_profile"' "$TMP_DIR/out.json"
    grep -q '"accepted_sample"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis fixture after sample is cleaner than before sample" {
    BEFORE="$REPO/tests/fixtures/anti-ai/novel_opening_before.md"
    AFTER="$REPO/tests/fixtures/anti-ai/novel_opening_after.md"

    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$BEFORE" > "$TMP_DIR/before.json"
    node "$SCRIPT" --json --work-type=shortform --prose-profile=fiction "$AFTER" > "$TMP_DIR/after.json"

    node - "$TMP_DIR/before.json" "$TMP_DIR/after.json" <<'NODE'
const fs = require('fs');
const before = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).files[0];
const after = JSON.parse(fs.readFileSync(process.argv[3], 'utf8')).files[0];
if (!(before.summary.total > after.summary.total)) {
  throw new Error(`expected before findings ${before.summary.total} > after ${after.summary.total}`);
}
if (!(before.qualityScore.total < after.qualityScore.total)) {
  throw new Error(`expected before quality ${before.qualityScore.total} < after ${after.qualityScore.total}`);
}
NODE
}

@test "anti-ai diagnosis script loads project learned style and pollution rules" {
    mkdir -p "$TMP_DIR/book/追踪/schema" "$TMP_DIR/book/设定/作者风格"
    cat > "$TMP_DIR/book/追踪/schema/user-style-rules.jsonl" <<'EOF'
{"id":"style-test-dash","scope":"当前书","priority":"hard","category":"AI味","rule":"禁止逐字破折号化。","bad_example":"本大爷——御——兽——宗——","preferred_fix":"改成短句或动作。"}
EOF
    cat > "$TMP_DIR/book/追踪/schema/output-pollution-rules.jsonl" <<'EOF'
{"phrase":"灵根跃迁触发","category":"模型退化","blockedStatus":"blocked_model_degradation","maxOccurrences":2}
EOF
    cat > "$TMP_DIR/book/设定/作者风格/禁用表达.md" <<'EOF'
# 禁用表达

- `他终于明白`
EOF
    cat > "$TMP_DIR/learned.md" <<'EOF'
本大爷——御——兽——宗——这个名字，记住了。
他终于明白，灵根跃迁触发灵根跃迁触发。
EOF

    node "$SCRIPT" --json --project-root "$TMP_DIR/book" "$TMP_DIR/learned.md" > "$TMP_DIR/out.json"

    grep -q '"projectRulesLoaded"' "$TMP_DIR/out.json"
    grep -q '"type": "learned-project-rule"' "$TMP_DIR/out.json"
    grep -q '"phrase": "本大爷——御——兽——宗——"' "$TMP_DIR/out.json"
    grep -q '"phrase": "灵根跃迁触发"' "$TMP_DIR/out.json"
    grep -q '"phrase": "他终于明白"' "$TMP_DIR/out.json"
}

@test "anti-ai diagnosis does not treat ordinary repeated topic words as model loops" {
    cat > "$TMP_DIR/topic.md" <<'EOF'
脚本用于诊断正文。
这个脚本不会改写正文。
脚本可以输出 JSON。
脚本结果只作为证据。
脚本需要配合人工判断。
脚本运行后再看正文。
脚本不是模型。
脚本不是裁决。
EOF

    node "$SCRIPT" --json --work-type=unknown_fragment "$TMP_DIR/topic.md" > "$TMP_DIR/out.json"

    ! grep -q '"type": "model-loop"' "$TMP_DIR/out.json"
}

@test "author voice profile extracts stable prose habits from accepted samples" {
    SAMPLE="$TMP_DIR/accepted.md"
    OUT="$TMP_DIR/voice.json"
    cat > "$SAMPLE" <<'EOF'
我把碗放回桌上。
汤已经凉了，油花贴在碗沿，像一层没擦干净的旧账。
"你还想让我怎么忍？"我问。
母亲没看我，只把那张纸往前推了半寸。
EOF

    node "$REPO/scripts/author-voice-profile.js" --json --output "$OUT" "$SAMPLE"

    grep -q '"schemaVersion": "1.0.0"' "$OUT"
    grep -q '"sentenceLength"' "$OUT"
    grep -q '"paragraphShape"' "$OUT"
    grep -q '"punctuationHabits"' "$OUT"
    grep -q '"dialogueRatio"' "$OUT"
}

@test "bundle script includes anti-ai diagnosis runtime" {
    grep -q '"anti-ai-diagnose.js"' "$REPO/config/novel-assistant-bundle-files.json"
    grep -q '"author-voice-profile.js"' "$REPO/config/novel-assistant-bundle-files.json"
    test -x "$REPO/skills/novel-assistant/scripts/anti-ai-diagnose.js"
    test -x "$REPO/skills/novel-assistant/scripts/author-voice-profile.js"
}

@test "story-workflow defines anti-ai workflow packet fields" {
    entry="$REPO/src/internal-skills/story-workflow/SKILL.md"
    protocol="$REPO/src/internal-skills/story-workflow/references/task-inbox-protocol.md"

    grep -q "task-inbox-protocol.md" "$entry"
    grep -q "anti_ai_workflow" "$protocol"
    grep -q "anti_ai_work_type" "$protocol"
    grep -q "prose_profile" "$protocol"
    grep -q "target_scope" "$protocol"
    grep -q "write_mode" "$protocol"
    grep -q "fact_baseline_paths" "$protocol"
    grep -q "author_voice_profile_paths" "$protocol"
    grep -q "human_voice_protection" "$protocol"
    grep -q "external_ai_detector_signal" "$protocol"
    grep -q "verification_policy" "$protocol"
    grep -q "blocked_revision_required" "$protocol"
}

@test "story-deslop branches shortform longform and unknown fragment profiles" {
    file="$REPO/src/internal-skills/story-deslop/SKILL.md"
    grep -q "shortform" "$file"
    grep -q "longform" "$file"
    grep -q "unknown_fragment" "$file"
    grep -q "detector score is evidence, not verdict" "$file"
    grep -q "qualityScore" "$file"
    grep -q "proseProfile" "$file"
    grep -q "humanVoiceProtection" "$file"
    grep -q "short-deslop.md" "$file"
    grep -q "章节契约" "$file"
    grep -q "blocked_revision_required" "$file"
}

@test "story-deslop treats task blocks and metaphor density as advisory review evidence" {
    file="$REPO/src/internal-skills/story-deslop/SKILL.md"

    grep -q "任务块密度" "$file"
    grep -q "隐喻密度" "$file"
    grep -q "advisory" "$file"
    grep -q "人工复核" "$file"
    grep -q "不得为降低指标" "$file"
}

@test "short-write defines short-form anti-AI prevention before drafting" {
    file="$REPO/src/internal-skills/story-short-write/SKILL.md"
    grep -q "short-form anti-AI prevention" "$file"
    grep -q "写前防 AI" "$file"
    grep -q "1-2 个小节" "$file"
    grep -q "已写小节摘要" "$file"
    grep -q "anti-ai-diagnose.js" "$file"
}

@test "short deslop and shared anti-ai guide define layered repair without killing commercial heat" {
    short_ref="$REPO/src/internal-skills/story-short-write/references/short-deslop.md"
    shared_ref="$REPO/src/internal-skills/story-setup/references/agent-references/anti-ai-writing.md"

    grep -q "分层修复" "$short_ref"
    grep -q "商业强情绪" "$short_ref"
    grep -q "检测器分数是证据，不是裁决" "$short_ref"
    grep -q "长篇" "$shared_ref"
    grep -q "事实保留优先于降 AI 分" "$shared_ref"
    grep -q "blocked_revision_required" "$shared_ref"
}
