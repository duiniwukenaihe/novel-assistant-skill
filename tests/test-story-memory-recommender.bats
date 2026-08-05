#!/usr/bin/env bats

assert_json_file() {
    local file="$1"
    local script="$2"
    node -e "
      const fs = require('fs');
      const value = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      const out = value;
      ${script}
    " "$file"
}

assert_jsonl_file() {
    local file="$1"
    local script="$2"
    node -e "
      const fs = require('fs');
      const lines = fs.readFileSync(process.argv[1], 'utf8')
        .split(/\\r?\\n/)
        .filter(Boolean);
      const value = lines.map((line) => JSON.parse(line));
      ${script}
    " "$file"
}

assert_file_contains() {
    local file="$1"
    local needle="$2"
    node -e "
      const fs = require('fs');
      const text = fs.readFileSync(process.argv[1], 'utf8');
      if (!text.includes(process.argv[2])) process.exit(1);
    " "$file" "$needle"
}

assert_file_not_contains() {
    local file="$1"
    local needle="$2"
    node -e "
      const fs = require('fs');
      const text = fs.readFileSync(process.argv[1], 'utf8');
      if (text.includes(process.argv[2])) process.exit(1);
    " "$file" "$needle"
}

assert_file_missing() {
    local file="$1"
    if [[ -e "$file" ]]; then
        return 1
    fi
}

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/memory-recommender.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/memory" "$PROJECT/正文/第1卷" "$PROJECT/设定/人物" "$PROJECT/追踪/story-system/commits"
    cat > "$PROJECT/正文/第1卷/第003章_炒饭.md" <<'MD'
# 第003章
陆川用炒饭稳住苏禾。苏禾感知时出现空白。
MD
    printf '陆川用做饭破局。\n' > "$PROJECT/设定/人物/陆川.md"
    CHAPTER_HASH="sha256:06d611bff06b9403e5db441f32e1aa695610f281fc00fb650ab3b6fb5b18eea8"
    CHAPTER_COMMIT_ID="chapter-vtest-003-provenance"
    cat > "$PROJECT/追踪/story-system/commits/$CHAPTER_COMMIT_ID.json" <<JSON
{"commit_id":"$CHAPTER_COMMIT_ID","status":"accepted","artifacts":[{"target":"正文/第1卷/第003章_炒饭.md","after_hash":"$CHAPTER_HASH"}]}
JSON
    cat > "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"char.lu-chuan","type":"character","title":"陆川","aliases":["陆川"],"triggers":["陆川"],"scope":{"book":"current"},"priority":90,"tokenBudget":160,"content":"陆川用做饭破局。","constraints":[],"sourceRefs":[{"path":"设定/人物/陆川.md","hash":"sha256:810ad329e59b5dbbfc026bdda742f2ab9f30543a233dd042e1b5d3654a4466f0","note":"confirmed"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
JSONL
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "memory recommender records suggestions without mutating lorebook" {
    cat > "$TMP_DIR/suggestions.json" <<JSON
[
  {
    "action": "create",
    "entryId": "hook.f101",
    "type": "hook",
    "risk": "low",
    "reason": "new accepted chapter introduced a recurring hook",
    "evidencePath": "$PROJECT/正文/第1卷/第003章_炒饭.md",
    "proposedContent": "苏禾感知时出现空白，后续需要解释精神力异常。",
    "sourceRefs": [{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:06d611bff06b9403e5db441f32e1aa695610f281fc00fb650ab3b6fb5b18eea8","note":"accepted chapter"}],
    "affects": ["write_chapter", "review"]
  }
]
JSON

    node "$SCRIPT" --project-root "$PROJECT" --input "$TMP_DIR/suggestions.json" --write --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'suggestions_recorded') process.exit(1);
      if (out.recorded !== 1) process.exit(2);
    "

    assert_file_contains "$PROJECT/追踪/memory/memory-suggestions.jsonl" "hook.f101"
    assert_file_not_contains "$PROJECT/追踪/memory/lorebook.jsonl" "hook.f101"
}

@test "memory recommender rejects object content instead of persisting object Object" {
    cat > "$TMP_DIR/object-content.json" <<'JSON'
[
  {
    "action": "create",
    "entryId": "fact.structured-content",
    "type": "accepted_fact",
    "risk": "low",
    "reason": "model returned structured content",
    "proposedContent": {"fact":"苏禾已经确认异常","chapter":3},
    "sourceKind": "user_confirmed",
    "accepted_artifact_id": "sa-review",
    "sourceRefs": [],
    "affects": ["write_chapter"]
  }
]
JSON

    node "$SCRIPT" --project-root "$PROJECT" --input "$TMP_DIR/object-content.json" --write --json > "$TMP_DIR/object-out.json"

    assert_json_file "$TMP_DIR/object-out.json" "
      if (out.status !== 'blocked_invalid_memory_suggestions') process.exit(1);
      if (!out.blockedEntryIds.includes('fact.structured-content')) process.exit(2);
    "
    assert_file_not_contains "$PROJECT/追踪/memory/lorebook.jsonl" "[object Object]"
    assert_file_missing "$PROJECT/追踪/memory/memory-suggestions.jsonl"
}

@test "memory recommender applies low-risk additive suggestions only" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"create","entryId":"hook.f101","type":"hook","risk":"low","reason":"accepted chapter introduced hook","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"苏禾感知时出现空白，后续需要解释精神力异常。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:06d611bff06b9403e5db441f32e1aa695610f281fc00fb650ab3b6fb5b18eea8","note":"accepted chapter"}],"affects":["write_chapter","review"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"update","entryId":"char.lu-chuan","type":"character","risk":"high","reason":"would change confirmed canon","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"陆川已经公开能力秘密。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:06d611bff06b9403e5db441f32e1aa695610f281fc00fb650ab3b6fb5b18eea8","note":"risky"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'applied_low_risk') process.exit(1);
      if (out.applied !== 1) process.exit(2);
      if (out.confirmationRequired !== 1) process.exit(3);
    "

    assert_file_contains "$PROJECT/追踪/memory/lorebook.jsonl" "hook.f101"
    assert_file_contains "$PROJECT/追踪/memory/lorebook.jsonl" "char.lu-chuan"
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "requires_confirmation"
}

@test "memory recommender scopes automatic application to explicit suggestion ids" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"suggestionId":"sg-old-risky","action":"update","entryId":"char.lu-chuan","type":"character","risk":"high","reason":"历史待确认项","proposedContent":"陆川已经公开能力秘密。","sourceKind":"user_confirmed","accepted_artifact_id":"sa-old","sourceRefs":[],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"suggestionId":"sg-current-safe","action":"create","entryId":"fact.current","type":"fact","risk":"low","reason":"本轮确认的稳定事实","proposedContent":"苏禾本轮已经确认锅沿缺口来自旧伤。","sourceKind":"user_confirmed","accepted_artifact_id":"sa-current","sourceRefs":[],"affects":["review"],"status":"pending","createdAt":"2026-07-05T00:01:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --suggestion-id sg-current-safe --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$PROJECT/追踪/memory/memory-suggestions.jsonl" "$PROJECT/追踪/memory/memory-audit.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const suggestions=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse);
const audit=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
if(out.applied!==1||out.confirmationRequired!==0||out.pendingConfirmationTotal!==1) throw new Error(JSON.stringify(out));
if(!suggestions.some(item=>item.suggestionId==='sg-old-risky'&&item.status==='pending')) throw new Error('old pending suggestion changed');
if(audit.some(item=>item.entryId==='char.lu-chuan')) throw new Error('unscoped suggestion was audited');
NODE
}

@test "memory recommender blocks confirmation-required suggestions when none can apply" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"update","entryId":"char.lu-chuan","type":"character","risk":"high","reason":"would change confirmed canon","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"陆川已经公开能力秘密。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:06d611bff06b9403e5db441f32e1aa695610f281fc00fb650ab3b6fb5b18eea8","note":"risky"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'blocked_confirmation_required') process.exit(1);
      if (out.applied !== 0) process.exit(2);
      if (out.confirmationRequired !== 1) process.exit(3);
    "

    assert_jsonl_file "$PROJECT/追踪/memory/lorebook.jsonl" "
      if (!Array.isArray(value)) process.exit(1);
      if (value.length !== 1) process.exit(2);
      if (value[0].id !== 'char.lu-chuan') process.exit(3);
    "
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "requires_confirmation"
}

@test "memory recommender rejects placeholder source hashes before recording suggestions" {
    cat > "$TMP_DIR/placeholder.json" <<'JSON'
[{"action":"create","entryId":"hook.placeholder","type":"hook","risk":"low","proposedContent":"需要追踪的真实伏笔。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test"}]}]
JSON

    run node "$SCRIPT" --project-root "$PROJECT" --input "$TMP_DIR/placeholder.json" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_invalid_memory_provenance'* ]]
    assert_file_missing "$PROJECT/追踪/memory/memory-suggestions.jsonl"
}

@test "memory recommender preserves verified v1 evidence when confirming a v2 update" {
    printf '陆川把感知异常告诉苏禾。\n' > "$PROJECT/追踪/新增证据.md"
    extra_hash="sha256:$(shasum -a 256 "$PROJECT/追踪/新增证据.md" | awk '{print $1}')"
    node - "$PROJECT/追踪/story-system/commits/$CHAPTER_COMMIT_ID.json" "$extra_hash" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const commit=JSON.parse(fs.readFileSync(file,'utf8'));
commit.artifacts.push({target:'追踪/新增证据.md',after_hash:process.argv[3]});
fs.writeFileSync(file,`${JSON.stringify(commit)}\n`);
NODE
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<JSONL
{"suggestionId":"sg-v2-lineage","action":"update","entryId":"char.lu-chuan","type":"character","risk":"high","proposedContent":"陆川仍未公开能力秘密，但已经把感知异常告诉苏禾。","sourceRefs":[{"path":"追踪/新增证据.md","hash":"$extra_hash"}],"status":"pending"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --confirm sg-v2-lineage --decision apply --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$PROJECT/追踪/memory/lorebook.jsonl" "$CHAPTER_COMMIT_ID" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const rows=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse);
const v2=rows.filter(row=>row.id==='char.lu-chuan').at(-1);
if(out.status!=='confirmed_applied' || out.chapter_commit_id!==process.argv[4]) throw new Error(JSON.stringify(out));
if(v2.version!==2 || v2.supersedes!=='char.lu-chuan@v1') throw new Error(JSON.stringify(v2));
if(!v2.sourceRefs.some(ref=>ref.path==='设定/人物/陆川.md')) throw new Error('v1 evidence disappeared');
if(!v2.sourceRefs.some(ref=>ref.path==='追踪/新增证据.md')) throw new Error('v2 evidence missing');
if(v2.chapter_commit_id!==process.argv[4] || v2.provenance_status!=='verified') throw new Error(JSON.stringify(v2));
NODE
}

@test "memory recommender blocks polluted suggestions" {
    cat > "$TMP_DIR/suggestions.json" <<JSON
[
  {
    "action": "create",
    "entryId": "bad.loop",
    "type": "rule",
    "risk": "low",
    "reason": "bad model output",
    "evidencePath": "$PROJECT/正文/第1卷/第003章_炒饭.md",
    "proposedContent": "节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制。",
    "sourceRefs": [{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"bad"}],
    "affects": ["write_chapter"]
  }
]
JSON

    node "$SCRIPT" --project-root "$PROJECT" --input "$TMP_DIR/suggestions.json" --write --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'blocked_output_pollution') process.exit(1);
      if (!out.blockedEntryIds.includes('bad.loop')) process.exit(2);
    "
}

@test "memory recommender blocks polluted pending suggestions during apply-low-risk" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"create","entryId":"bad.loop","type":"rule","risk":"low","reason":"polluted pending output","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"bad"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'blocked_output_pollution') process.exit(1);
      if (!Array.isArray(out.blockedEntryIds) || !out.blockedEntryIds.includes('bad.loop')) process.exit(2);
      if (out.applied !== 0) process.exit(3);
      if (out.confirmationRequired !== 0) process.exit(4);
    "

    assert_jsonl_file "$PROJECT/追踪/memory/lorebook.jsonl" "
      if (!Array.isArray(value)) process.exit(1);
      if (value.length !== 1) process.exit(2);
      if (value[0].id !== 'char.lu-chuan') process.exit(3);
    "
    assert_file_missing "$PROJECT/追踪/memory/memory-audit.jsonl"
}

@test "memory recommender forces confirmation for mislabeled low-risk canon and style changes" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"create","entryId":"char.secret","type":"character","risk":"low","reason":"new fact","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"确认设定：陆川已经知道苏禾会感知。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"hook.chapter-shift","type":"hook","risk":"low","reason":"new hook note","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"把伏笔提前到第001章再在第005章回收。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"rule.power-limit","type":"rule","risk":"low","reason":"new power note","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"成长规则调整为陆川每次升级都永久提升精神力上限。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"chapter.rename","type":"chapter","risk":"low","reason":"chapter cleanup","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"章节编号改为第004章并重命名标题。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"style.preference","type":"style","risk":"low","reason":"style update","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"以后统一改成第一人称冷幽默口吻。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'blocked_confirmation_required') process.exit(1);
      if (out.applied !== 0) process.exit(2);
      if (out.confirmationRequired !== 5) process.exit(3);
    "

    assert_jsonl_file "$PROJECT/追踪/memory/lorebook.jsonl" "
      if (!Array.isArray(value)) process.exit(1);
      if (value.length !== 1) process.exit(2);
      if (value[0].id !== 'char.lu-chuan') process.exit(3);
    "
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"char.secret\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"hook.chapter-shift\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"rule.power-limit\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"chapter.rename\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"style.preference\""
}

@test "memory recommender reports visible learning status without mutating files" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"create","entryId":"hook.f101","type":"hook","risk":"low","reason":"accepted chapter introduced hook","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"苏禾感知时出现空白，后续需要解释精神力异常。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"accepted chapter"}],"affects":["write_chapter","review"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"update","entryId":"char.lu-chuan","type":"character","risk":"high","reason":"would change confirmed canon","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"陆川已经公开能力秘密。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:test","note":"risky"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --status --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'memory_status') process.exit(1);
      if (out.lorebookCount !== 1) process.exit(2);
      if (out.activeEntries !== 1) process.exit(3);
      if (out.pendingSuggestions !== 2) process.exit(4);
      if (out.autoApplicable !== 1) process.exit(5);
      if (out.confirmationRequired !== 1) process.exit(6);
      if (!Array.isArray(out.recentLearned) || out.recentLearned[0].id !== 'char.lu-chuan') process.exit(7);
      if (!Array.isArray(out.pendingConfirmations) || out.pendingConfirmations[0].entryId !== 'char.lu-chuan') process.exit(8);
      if (!Array.isArray(out.nextEffects) || !out.nextEffects.includes('review')) process.exit(9);
    "

    assert_jsonl_file "$PROJECT/追踪/memory/lorebook.jsonl" "
      if (!Array.isArray(value)) process.exit(1);
      if (value.length !== 1) process.exit(2);
      if (value[0].id !== 'char.lu-chuan') process.exit(3);
    "
}

@test "memory recommender does not reapply an already applied low risk suggestion" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"suggestionId":"sg-hook-new","action":"create","entryId":"hook.new","type":"hook","risk":"low","reason":"accepted chapter introduced hook","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"铁锅缺口需要在下一章解释。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:06d611bff06b9403e5db441f32e1aa695610f281fc00fb650ab3b6fb5b18eea8","note":"accepted"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/first.json"
    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/second.json"
    node "$SCRIPT" --project-root "$PROJECT" --status --json > "$TMP_DIR/status.json"

    node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$TMP_DIR/status.json" <<'NODE'
const fs=require('fs');
const first=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const second=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const status=JSON.parse(fs.readFileSync(process.argv[4],'utf8'));
if(first.applied!==1) throw new Error('first not applied');
if(second.applied!==0 || second.confirmationRequired!==0) throw new Error(JSON.stringify(second));
if(status.pendingSuggestions!==0) throw new Error(JSON.stringify(status));
NODE
}

@test "memory recommender applies a confirmed high risk update as a new version" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"suggestionId":"sg-char-update","action":"update","entryId":"char.lu-chuan","type":"character","risk":"high","reason":"用户确认修正人物认知","evidencePath":"正文/第1卷/第003章_炒饭.md","proposedContent":"陆川仍未公开能力秘密，但已经把感知异常告诉苏禾。","sourceRefs":[{"path":"正文/第1卷/第003章_炒饭.md","hash":"sha256:06d611bff06b9403e5db441f32e1aa695610f281fc00fb650ab3b6fb5b18eea8","note":"confirmed by user"}],"affects":["write_chapter","review"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --confirm sg-char-update --decision apply --json > "$TMP_DIR/out.json"
    node "$SCRIPT" --project-root "$PROJECT" --status --json > "$TMP_DIR/status.json"

    node - "$TMP_DIR/out.json" "$TMP_DIR/status.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const status=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const lines=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse).filter(x=>x.id==='char.lu-chuan');
if(out.status!=='confirmed_applied') throw new Error(JSON.stringify(out));
if(lines.length!==2 || lines[1].version!==2) throw new Error(JSON.stringify(lines));
if(!lines[1].content.includes('感知异常')) throw new Error(lines[1].content);
if(status.pendingSuggestions!==0) throw new Error(JSON.stringify(status));
NODE
}
