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
    cat > "$PROJECT/正文/第1卷/第003章_蛋炒饭.md" <<'MD'
# 第003章
沈七用蛋炒饭稳住绿珠。绿珠读心时出现空白。
MD
    printf '沈七用做饭破局。\n' > "$PROJECT/设定/人物/沈七.md"
    CHAPTER_HASH="sha256:d896e86ebd9d399191c88a5ba5eddafcd1cf08d79452a2a9d6f9f63882bc7454"
    CHAPTER_COMMIT_ID="chapter-vtest-003-provenance"
    cat > "$PROJECT/追踪/story-system/commits/$CHAPTER_COMMIT_ID.json" <<JSON
{"commit_id":"$CHAPTER_COMMIT_ID","status":"accepted","artifacts":[{"target":"正文/第1卷/第003章_蛋炒饭.md","after_hash":"$CHAPTER_HASH"}]}
JSON
    cat > "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"char.shen-qi","type":"character","title":"沈七","aliases":["沈七"],"triggers":["沈七"],"scope":{"book":"current"},"priority":90,"tokenBudget":160,"content":"沈七用做饭破局。","constraints":[],"sourceRefs":[{"path":"设定/人物/沈七.md","hash":"sha256:c0598fe31159af007a483db96eadc7445ea14c96cb5cc60b093e1dd970cecb94","note":"confirmed"}],"status":"active","updatedAt":"2026-07-05T00:00:00Z"}
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
    "entryId": "hook.f025",
    "type": "hook",
    "risk": "low",
    "reason": "new accepted chapter introduced a recurring hook",
    "evidencePath": "$PROJECT/正文/第1卷/第003章_蛋炒饭.md",
    "proposedContent": "绿珠读心时出现空白，后续需要解释精神力异常。",
    "sourceRefs": [{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:d896e86ebd9d399191c88a5ba5eddafcd1cf08d79452a2a9d6f9f63882bc7454","note":"accepted chapter"}],
    "affects": ["write_chapter", "review"]
  }
]
JSON

    node "$SCRIPT" --project-root "$PROJECT" --input "$TMP_DIR/suggestions.json" --write --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'suggestions_recorded') process.exit(1);
      if (out.recorded !== 1) process.exit(2);
    "

    assert_file_contains "$PROJECT/追踪/memory/memory-suggestions.jsonl" "hook.f025"
    assert_file_not_contains "$PROJECT/追踪/memory/lorebook.jsonl" "hook.f025"
}

@test "memory recommender applies low-risk additive suggestions only" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"create","entryId":"hook.f025","type":"hook","risk":"low","reason":"accepted chapter introduced hook","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"绿珠读心时出现空白，后续需要解释精神力异常。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:d896e86ebd9d399191c88a5ba5eddafcd1cf08d79452a2a9d6f9f63882bc7454","note":"accepted chapter"}],"affects":["write_chapter","review"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"update","entryId":"char.shen-qi","type":"character","risk":"high","reason":"would change confirmed canon","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"沈七已经公开系统真相。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:d896e86ebd9d399191c88a5ba5eddafcd1cf08d79452a2a9d6f9f63882bc7454","note":"risky"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'applied_low_risk') process.exit(1);
      if (out.applied !== 1) process.exit(2);
      if (out.confirmationRequired !== 1) process.exit(3);
    "

    assert_file_contains "$PROJECT/追踪/memory/lorebook.jsonl" "hook.f025"
    assert_file_contains "$PROJECT/追踪/memory/lorebook.jsonl" "char.shen-qi"
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "requires_confirmation"
}

@test "memory recommender blocks confirmation-required suggestions when none can apply" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"update","entryId":"char.shen-qi","type":"character","risk":"high","reason":"would change confirmed canon","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"沈七已经公开系统真相。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:d896e86ebd9d399191c88a5ba5eddafcd1cf08d79452a2a9d6f9f63882bc7454","note":"risky"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
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
      if (value[0].id !== 'char.shen-qi') process.exit(3);
    "
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "requires_confirmation"
}

@test "memory recommender rejects placeholder source hashes before recording suggestions" {
    cat > "$TMP_DIR/placeholder.json" <<'JSON'
[{"action":"create","entryId":"hook.placeholder","type":"hook","risk":"low","proposedContent":"需要追踪的真实伏笔。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test"}]}]
JSON

    run node "$SCRIPT" --project-root "$PROJECT" --input "$TMP_DIR/placeholder.json" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_invalid_memory_provenance'* ]]
    assert_file_missing "$PROJECT/追踪/memory/memory-suggestions.jsonl"
}

@test "memory recommender preserves verified v1 evidence when confirming a v2 update" {
    printf '沈七把读心异常告诉绿珠。\n' > "$PROJECT/追踪/新增证据.md"
    extra_hash="sha256:$(shasum -a 256 "$PROJECT/追踪/新增证据.md" | awk '{print $1}')"
    node - "$PROJECT/追踪/story-system/commits/$CHAPTER_COMMIT_ID.json" "$extra_hash" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const commit=JSON.parse(fs.readFileSync(file,'utf8'));
commit.artifacts.push({target:'追踪/新增证据.md',after_hash:process.argv[3]});
fs.writeFileSync(file,`${JSON.stringify(commit)}\n`);
NODE
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<JSONL
{"suggestionId":"sg-v2-lineage","action":"update","entryId":"char.shen-qi","type":"character","risk":"high","proposedContent":"沈七仍未公开系统真相，但已经把读心异常告诉绿珠。","sourceRefs":[{"path":"追踪/新增证据.md","hash":"$extra_hash"}],"status":"pending"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --confirm sg-v2-lineage --decision apply --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$PROJECT/追踪/memory/lorebook.jsonl" "$CHAPTER_COMMIT_ID" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const rows=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse);
const v2=rows.filter(row=>row.id==='char.shen-qi').at(-1);
if(out.status!=='confirmed_applied' || out.chapter_commit_id!==process.argv[4]) throw new Error(JSON.stringify(out));
if(v2.version!==2 || v2.supersedes!=='char.shen-qi@v1') throw new Error(JSON.stringify(v2));
if(!v2.sourceRefs.some(ref=>ref.path==='设定/人物/沈七.md')) throw new Error('v1 evidence disappeared');
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
    "evidencePath": "$PROJECT/正文/第1卷/第003章_蛋炒饭.md",
    "proposedContent": "节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制。",
    "sourceRefs": [{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"bad"}],
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
{"action":"create","entryId":"bad.loop","type":"rule","risk":"low","reason":"polluted pending output","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制节奏控制。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"bad"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
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
      if (value[0].id !== 'char.shen-qi') process.exit(3);
    "
    assert_file_missing "$PROJECT/追踪/memory/memory-audit.jsonl"
}

@test "memory recommender forces confirmation for mislabeled low-risk canon and style changes" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"create","entryId":"char.secret","type":"character","risk":"low","reason":"new fact","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"确认设定：沈七已经知道绿珠会读心。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"hook.chapter-shift","type":"hook","risk":"low","reason":"new hook note","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"把伏笔提前到第001章再在第005章回收。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"rule.power-limit","type":"rule","risk":"low","reason":"new power note","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"成长规则调整为沈七每次升级都永久提升精神力上限。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"chapter.rename","type":"chapter","risk":"low","reason":"chapter cleanup","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"章节编号改为第004章并重命名标题。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"create","entryId":"style.preference","type":"style","risk":"low","reason":"style update","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"以后统一改成第一人称冷幽默口吻。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"mislabeled"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
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
      if (value[0].id !== 'char.shen-qi') process.exit(3);
    "
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"char.secret\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"hook.chapter-shift\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"rule.power-limit\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"chapter.rename\""
    assert_file_contains "$PROJECT/追踪/memory/memory-audit.jsonl" "\"entryId\":\"style.preference\""
}

@test "memory recommender reports visible learning status without mutating files" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"action":"create","entryId":"hook.f025","type":"hook","risk":"low","reason":"accepted chapter introduced hook","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"绿珠读心时出现空白，后续需要解释精神力异常。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"accepted chapter"}],"affects":["write_chapter","review"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
{"action":"update","entryId":"char.shen-qi","type":"character","risk":"high","reason":"would change confirmed canon","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"沈七已经公开系统真相。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:test","note":"risky"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --status --json > "$TMP_DIR/out.json"

    assert_json_file "$TMP_DIR/out.json" "
      if (out.status !== 'memory_status') process.exit(1);
      if (out.lorebookCount !== 1) process.exit(2);
      if (out.activeEntries !== 1) process.exit(3);
      if (out.pendingSuggestions !== 2) process.exit(4);
      if (out.autoApplicable !== 1) process.exit(5);
      if (out.confirmationRequired !== 1) process.exit(6);
      if (!Array.isArray(out.recentLearned) || out.recentLearned[0].id !== 'char.shen-qi') process.exit(7);
      if (!Array.isArray(out.pendingConfirmations) || out.pendingConfirmations[0].entryId !== 'char.shen-qi') process.exit(8);
      if (!Array.isArray(out.nextEffects) || !out.nextEffects.includes('review')) process.exit(9);
    "

    assert_jsonl_file "$PROJECT/追踪/memory/lorebook.jsonl" "
      if (!Array.isArray(value)) process.exit(1);
      if (value.length !== 1) process.exit(2);
      if (value[0].id !== 'char.shen-qi') process.exit(3);
    "
}

@test "memory recommender does not reapply an already applied low risk suggestion" {
    cat > "$PROJECT/追踪/memory/memory-suggestions.jsonl" <<'JSONL'
{"suggestionId":"sg-hook-new","action":"create","entryId":"hook.new","type":"hook","risk":"low","reason":"accepted chapter introduced hook","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"铁锅缺口需要在下一章解释。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:d896e86ebd9d399191c88a5ba5eddafcd1cf08d79452a2a9d6f9f63882bc7454","note":"accepted"}],"affects":["write_chapter"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
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
{"suggestionId":"sg-char-update","action":"update","entryId":"char.shen-qi","type":"character","risk":"high","reason":"用户确认修正人物认知","evidencePath":"正文/第1卷/第003章_蛋炒饭.md","proposedContent":"沈七仍未公开系统真相，但已经把读心异常告诉绿珠。","sourceRefs":[{"path":"正文/第1卷/第003章_蛋炒饭.md","hash":"sha256:d896e86ebd9d399191c88a5ba5eddafcd1cf08d79452a2a9d6f9f63882bc7454","note":"confirmed by user"}],"affects":["write_chapter","review"],"status":"pending","createdAt":"2026-07-05T00:00:00Z"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --confirm sg-char-update --decision apply --json > "$TMP_DIR/out.json"
    node "$SCRIPT" --project-root "$PROJECT" --status --json > "$TMP_DIR/status.json"

    node - "$TMP_DIR/out.json" "$TMP_DIR/status.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const status=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const lines=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse).filter(x=>x.id==='char.shen-qi');
if(out.status!=='confirmed_applied') throw new Error(JSON.stringify(out));
if(lines.length!==2 || lines[1].version!==2) throw new Error(JSON.stringify(lines));
if(!lines[1].content.includes('读心异常')) throw new Error(lines[1].content);
if(status.pendingSuggestions!==0) throw new Error(JSON.stringify(status));
NODE
}
