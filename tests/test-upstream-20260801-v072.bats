#!/usr/bin/env bats

# Task 1: 去除"短句崇拜"——公有短篇、长篇、审阅、去 AI 规则不再鼓励无差别短句。
# 上游依据：60bdae7 / 0a37505
# 注：bats 1.x 对中文 @test 名有编码问题，测试名用 ASCII，中文语义放注释。

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SRC="$REPO/src/internal-skills"
}

# ----------------------------------------------------------------------
# Task 3: 修复会话起点的假未完成与重复更新提醒
# 上游依据：c0a1482
# ----------------------------------------------------------------------

# 公共库提供 is_progress_completed：completed/completed_with_errors 返回 0，其他返回非 0
@test "task3 common.sh exposes is_progress_completed" {
    [ -f "$SRC/story-setup/references/templates/hooks/lib/common.sh" ]
    grep -q "is_progress_completed()" "$SRC/story-setup/references/templates/hooks/lib/common.sh"
}

# 辅助：构造一个临时项目根并复制 hook 模板，返回 hooks 目录绝对路径。
# 用 CLAUDE_PROJECT_DIR 把 project_root 锚定到临时项目根，避免污染真实仓库。
_setup_hook_fixture() {
    FIXTURE="$(mktemp -d)"
    HOOKS="$FIXTURE/.claude/hooks"
    mkdir -p "$HOOKS/lib"
    cp "$SRC/story-setup/references/templates/hooks/lib/common.sh" "$HOOKS/lib/"
    cp "$SRC/story-setup/references/templates/hooks/lib/sentinel.sh" "$HOOKS/lib/"
    cp "$SRC/story-setup/references/templates/hooks/lib/book-state.sh" "$HOOKS/lib/"
    export CLAUDE_PROJECT_DIR="$FIXTURE"
}

# 场景 1：空 _progress.md（缺字段）算未完成；completed 不算未完成 → 只剩 1 个未完成
@test "task3 empty progress counts unfinished, completed does not" {
    _setup_hook_fixture
    mkdir -p "$FIXTURE/拆文库/a" "$FIXTURE/拆文库/b"
    : > "$FIXTURE/拆文库/a/_progress.md"   # 空 → 未完成
    printf -- '- 最终状态：completed\n' > "$FIXTURE/拆文库/b/_progress.md"

    source "$HOOKS/lib/common.sh"
    unfinished=0
    while IFS= read -r -d '' f; do
        if ! is_progress_completed "$f"; then unfinished=$((unfinished+1)); fi
    done < <(find "$FIXTURE/拆文库" -name "_progress.md" -print0)

    [ "$unfinished" -eq 1 ]
}

# 场景 2：completed_with_errors 不算未完成
@test "task3 completed_with_errors not unfinished" {
    _setup_hook_fixture
    mkdir -p "$FIXTURE/拆文库/a"
    printf -- '- 最终状态：completed_with_errors\n' > "$FIXTURE/拆文库/a/_progress.md"

    source "$HOOKS/lib/common.sh"
    if is_progress_completed "$FIXTURE/拆文库/a/_progress.md"; then
        true
    else
        echo "completed_with_errors should be completed"; false
    fi
}

# 场景 3：模板占位值含 completed 字样（如 "completed/completed_with_errors"）仍视为未完成（不做子串误判）
@test "task3 placeholder containing completed substring still unfinished" {
    _setup_hook_fixture
    mkdir -p "$FIXTURE/拆文库/a"
    # 模板占位：{pending/paused_after_stage1/completed/completed_with_errors}
    printf -- '- 最终状态：{pending/paused_after_stage1/completed/completed_with_errors}\n' > "$FIXTURE/拆文库/a/_progress.md"

    source "$HOOKS/lib/common.sh"
    if is_progress_completed "$FIXTURE/拆文库/a/_progress.md"; then
        echo "placeholder must not match as completed"; false
    else
        true
    fi
}

# 场景 4：pending 仍视为未完成
@test "task3 pending still unfinished" {
    _setup_hook_fixture
    mkdir -p "$FIXTURE/拆文库/a"
    printf -- '- 最终状态：pending\n' > "$FIXTURE/拆文库/a/_progress.md"

    source "$HOOKS/lib/common.sh"
    if is_progress_completed "$FIXTURE/拆文库/a/_progress.md"; then
        echo "pending must not match as completed"; false
    else
        true
    fi
}

# 场景 4b：paused_after_stage1 仍视为未完成
@test "task3 paused_after_stage1 still unfinished" {
    _setup_hook_fixture
    mkdir -p "$FIXTURE/拆文库/a"
    printf -- '- 最终状态：paused_after_stage1\n' > "$FIXTURE/拆文库/a/_progress.md"

    source "$HOOKS/lib/common.sh"
    if is_progress_completed "$FIXTURE/拆文库/a/_progress.md"; then
        echo "paused must not match as completed"; false
    else
        true
    fi
}

# completed 后可带尾随注释（真实 demo 文件格式：completed ✅（...））
@test "task3 completed with trailing annotation still completed" {
    _setup_hook_fixture
    mkdir -p "$FIXTURE/拆文库/a"
    printf -- '- 最终状态：completed ✅（Stage 0/1/2 全部完成）\n' > "$FIXTURE/拆文库/a/_progress.md"

    source "$HOOKS/lib/common.sh"
    if is_progress_completed "$FIXTURE/拆文库/a/_progress.md"; then
        true
    else
        echo "completed with annotation should be completed"; false
    fi
}

# 场景 5：C locale 与可用中文 locale 下结果一致（locale 安全）
@test "task3 is_progress_completed locale-stable" {
    _setup_hook_fixture
    mkdir -p "$FIXTURE/拆文库/ok" "$FIXTURE/拆文库/pending"
    printf -- '- 最终状态：completed\n' > "$FIXTURE/拆文库/ok/_progress.md"
    printf -- '- 最终状态：pending\n' > "$FIXTURE/拆文库/pending/_progress.md"

    source "$HOOKS/lib/common.sh"
    # C locale
    ok_c=$(LC_ALL=C is_progress_completed "$FIXTURE/拆文库/ok/_progress.md" && echo yes || echo no)
    pend_c=$(LC_ALL=C is_progress_completed "$FIXTURE/拆文库/pending/_progress.md" && echo yes || echo no)
    # 选一个可用的 UTF-8 中文 locale（macOS / glibc 命名不同）；没有则跳过
    utf8_locale=""
    for cand in en_US.UTF-8 en_US.UTF8 zh_CN.UTF-8 C.UTF-8 UTF-8; do
        if LC_ALL="$cand" locale >/dev/null 2>&1; then utf8_locale="$cand"; break; fi
    done
    if [ -z "$utf8_locale" ]; then skip "no utf-8 locale available"; fi
    ok_u=$(LC_ALL="$utf8_locale" is_progress_completed "$FIXTURE/拆文库/ok/_progress.md" && echo yes || echo no)
    pend_u=$(LC_ALL="$utf8_locale" is_progress_completed "$FIXTURE/拆文库/pending/_progress.md" && echo yes || echo no)

    [ "$ok_c" = "$ok_u" ] || { echo "completed differs across locale: $ok_c vs $ok_u"; false; }
    [ "$pend_c" = "$pend_u" ] || { echo "pending differs across locale: $pend_c vs $pend_u"; false; }
    [ "$ok_c" = "yes" ] && [ "$pend_c" = "no" ]
}

# 集成：session-start.sh 对一个 completed + 一个 pending 的拆文库，只报告 1 个未完成
@test "task3 session-start reports only unfinished count" {
    _setup_hook_fixture
    cp "$SRC/story-setup/references/templates/hooks/session-start.sh" "$HOOKS/"
    mkdir -p "$FIXTURE/拆文库/done" "$FIXTURE/拆文库/todo"
    printf -- '- 最终状态：completed\n' > "$FIXTURE/拆文库/done/_progress.md"
    printf -- '- 最终状态：pending\n' > "$FIXTURE/拆文库/todo/_progress.md"

    out=$(bash "$HOOKS/session-start.sh" 2>/dev/null || true)
    # 只剩 1 个未完成
    echo "$out" | grep -q "有 1 个未完成拆文"
    ! echo "$out" | grep -qE "有 2 个未完成拆文"
}

# 集成：detect-story-gaps.sh 只对未完成的 _progress.md 报 WARN
@test "task3 detect-story-gaps only warns on unfinished progress" {
    _setup_hook_fixture
    cp "$SRC/story-setup/references/templates/hooks/detect-story-gaps.sh" "$HOOKS/"
    # detect-story-gaps 在「无任何书目」时会静默 exit 0（见 hook 第 26-29 行），
    # 故 fixture 必须含至少一个书目目录（正文/）才能走到全局拆文检测。
    mkdir -p "$FIXTURE/某书/正文" "$FIXTURE/拆文库/done" "$FIXTURE/拆文库/todo"
    printf '正文\n' > "$FIXTURE/某书/正文/ch1.md"
    printf -- '- 最终状态：completed\n' > "$FIXTURE/拆文库/done/_progress.md"
    printf -- '- 最终状态：pending\n' > "$FIXTURE/拆文库/todo/_progress.md"

    out=$(bash "$HOOKS/detect-story-gaps.sh" 2>/dev/null || true)
    # 未完成的 todo 报 WARN
    echo "$out" | grep -q "todo/_progress.md"
    # completed 的 done 不报
    ! echo "$out" | grep -q "done/_progress.md"
}

# 场景 6：版本类更新提醒写 24h 负缓存戳；24h 内不重复提醒
@test "task3 session-start update warning throttled by negative cache" {
    _setup_hook_fixture
    cp "$SRC/story-setup/references/templates/hooks/session-start.sh" "$HOOKS/"
    # 构造一个会触发"版本偏旧"警告的 sentinel：agents v18 < 19
    mkdir -p "$FIXTURE/.claude"
    cat > "$FIXTURE/.story-deployed" <<'SENT'
deployed_at: 2026-01-01T00:00:00Z
agents_version: 18
setup_skill_version: 1.4.1
novel_assistant_bundle_id: old999
novel_assistant_source_commit: abc1234
target_cli: claude-code
resolver_strategy: global-skill-with-project-agent-references
references_dir: .claude/agent-references/novel-assistant
SENT
    # 模拟 references_dir 存在且非空，避免触发 references 缺失警告干扰断言
    mkdir -p "$FIXTURE/.claude/agent-references/novel-assistant"
    printf 'ref\n' > "$FIXTURE/.claude/agent-references/novel-assistant/x.md"

    first=$(bash "$HOOKS/session-start.sh" 2>/dev/null || true)
    # 第一次：应出现版本偏旧提醒，并写入负缓存戳
    echo "$first" | grep -q "版本偏旧"
    [ -f "$FIXTURE/.claude/.update-notify.stamp" ] || { echo "no negative-cache stamp written"; false; }

    # 第二次：24h 内不应再出现版本偏旧提醒
    second=$(bash "$HOOKS/session-start.sh" 2>/dev/null || true)
    ! echo "$second" | grep -q "版本偏旧" || { echo "update warning re-appeared within 24h"; false; }
}

# 场景 7：超过 24h 的旧戳视为过期，允许重新提醒一次（戳被刷新）
@test "task3 session-start update warning re-appears after 24h" {
    _setup_hook_fixture
    cp "$SRC/story-setup/references/templates/hooks/session-start.sh" "$HOOKS/"
    mkdir -p "$FIXTURE/.claude"
    cat > "$FIXTURE/.story-deployed" <<'SENT'
deployed_at: 2026-01-01T00:00:00Z
agents_version: 18
setup_skill_version: 1.4.1
novel_assistant_bundle_id: old999
novel_assistant_source_commit: abc1234
target_cli: claude-code
resolver_strategy: global-skill-with-project-agent-references
references_dir: .claude/agent-references/novel-assistant
SENT
    mkdir -p "$FIXTURE/.claude/agent-references/novel-assistant"
    printf 'ref\n' > "$FIXTURE/.claude/agent-references/novel-assistant/x.md"
    # 预置一个 25h 前的戳（用 epoch 秒）：now - 90000s
    old_ts=$(( $(date +%s) - 90000 ))
    printf '%s\n' "$old_ts" > "$FIXTURE/.claude/.update-notify.stamp"

    out=$(bash "$HOOKS/session-start.sh" 2>/dev/null || true)
    echo "$out" | grep -q "版本偏旧" || { echo "update warning did not re-appear after 24h"; false; }
}

# 禁用短语"短句优先"不得出现在公有规则
@test "task1 public rules no longer say short-sentence-first" {
    files=$(grep -rln "短句优先" "$SRC" 2>/dev/null | grep -v "private-internal-skills" || true)
    [ -z "$files" ] || { echo "still contains short-sentence-first: $files"; false; }
}

# 禁用短语"句短、段碎"
@test "task1 short-craft no longer says short-sentence-broken-paragraph" {
    files=$(grep -rln "句短、段碎" "$SRC" 2>/dev/null | grep -v "private-internal-skills" || true)
    [ -z "$files" ] || { echo "still contains broken-paragraph: $files"; false; }
}

# 禁用短语"短句 = 情绪密度高"
@test "task1 short-craft no longer says short-sentence-equals-emotion" {
    files=$(grep -rln "短句 = 情绪密度高" "$SRC" 2>/dev/null | grep -v "private-internal-skills" || true)
    [ -z "$files" ] || { echo "still contains emotion-density: $files"; false; }
}

# 新规则：句长随场景功能变化（不追求统一短句）
@test "task1 rules describe scene-driven sentence length" {
    hit=0
    for f in \
        "$SRC/story-short-write/references/writing-craft.md" \
        "$SRC/story-short-write/references/anti-ai-writing.md" \
        "$SRC/story-long-write/references/writing-craft.md" \
        "$SRC/story-long-write/references/anti-ai-writing.md"; do
        if [ -f "$f" ] && grep -q "场景功能\|随场景\|场景需要" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no scene-driven sentence-length rule"; false; }
}

# 新规则：禁止为通过检测器机械拆句/机械替换
@test "task1 rules forbid mechanical splitting to pass detectors" {
    hit=0
    for f in \
        "$SRC/story-short-write/references/anti-ai-writing.md" \
        "$SRC/story-long-write/references/anti-ai-writing.md" \
        "$SRC/story-deslop/references/anti-ai-writing.md"; do
        if [ -f "$f" ] && grep -qE "机械拆句|机械替换|为了通过检测器|不要为了.{0,8}检测" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no mechanical-split ban"; false; }
}

# 新规则：情绪词在证据支撑下可用（不是绝对禁止）
@test "task1 emotion words allowed when backed by evidence" {
    for f in \
        "$SRC/story-short-write/references/writing-craft.md" \
        "$SRC/story-long-write/references/writing-craft.md" \
        "$SRC/story-short-write/references/anti-ai-writing.md" \
        "$SRC/story-long-write/references/anti-ai-writing.md" \
        "$SRC/story-short-analyze/references/anti-ai-writing.md"; do
        [ -f "$f" ] || { echo "missing $f"; false; }
        grep -qE "情绪词.{0,30}证据|情绪词.{0,30}支撑|可以使用情绪词|不禁止情绪词" "$f" \
            || { echo "no evidence-backed emotion-word rule in $f"; false; }
        ! grep -qE "禁止直接写出情绪词|无直接写.{0,20}全用身体反应" "$f" \
            || { echo "absolute emotion-word ban remains in $f"; false; }
    done
}

@test "task1 dash policy is consistent across writing and review rules" {
    for f in \
        "$SRC/story-short-write/references/anti-ai-writing.md" \
        "$SRC/story-long-write/references/anti-ai-writing.md" \
        "$SRC/story-deslop/references/anti-ai-writing.md" \
        "$SRC/story-review/references/anti-ai-writing.md" \
        "$SRC/story-review/references/quality-checklist.md" \
        "$SRC/story-short-analyze/references/anti-ai-writing.md" \
        "$SRC/story-short-analyze/references/quality-checklist.md"; do
        [ -f "$f" ] || { echo "missing $f"; false; }
        grep -qE "少量.{0,12}功能.{0,12}——|——.{0,20}少量.{0,12}功能" "$f" \
            || { echo "functional dash allowance missing in $f"; false; }
        ! grep -qE '无 `——`/`—`/`--`|不保留 `——`/`—`/`--`|目标为 0 处' "$f" \
            || { echo "blanket dash ban remains in $f"; false; }
    done
}

# ----------------------------------------------------------------------
# Task 2: 细纲只传递故事责任，不把结构形状复制进正文
# 上游依据：f710ade
# ----------------------------------------------------------------------

# 写作规则必须说明：细纲传递责任（事件/选择/代价/承接），正文自主组织场景
@test "task2 writing rules separate outline duty from prose shape" {
    hit=0
    for f in \
        "$SRC/story-short-write/SKILL.md" \
        "$SRC/story-long-write/SKILL.md" \
        "$SRC/story-long-write/references/writing-craft.md"; do
        if [ -f "$f" ] && grep -qE "细纲.{0,40}责任|责任.{0,20}正文自主|正文自主组织" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no outline-duty vs prose-shape separation rule"; false; }
}

# 禁止把细纲字段（目标/阻力/反转/爽点/下节钩子）逐条翻译进正文
@test "task2 rules forbid translating outline fields into prose narration" {
    hit=0
    for f in \
        "$SRC/story-short-write/SKILL.md" \
        "$SRC/story-long-write/references/writing-craft.md" \
        "$SRC/story-review/references/quality-checklist.md"; do
        if [ -f "$f" ] && grep -qE "禁止.{0,30}逐条翻译|不得.{0,30}字段.{0,15}翻译|字段名.{0,15}正文" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no ban on field-by-field translation"; false; }
}

# 禁止工程化章尾总结/预告，但允许场景内已经发生的动作、对白和证据钩子
@test "task2 rules distinguish meta preview from diegetic hook" {
    for f in \
        "$SRC/story-long-write/references/writing-craft.md" \
        "$SRC/story-review/references/quality-checklist.md"; do
        [ -f "$f" ] || { echo "missing $f"; false; }
        grep -qE "工程化预告|叙述者预告|元叙事预告" "$f" \
            || { echo "no meta-preview ban in $f"; false; }
        grep -qE "场景内.{0,30}(动作|对白|证据).{0,30}钩子|动作.{0,20}对白.{0,20}钩子" "$f" \
            || { echo "no diegetic-hook allowance in $f"; false; }
    done
}

# ----------------------------------------------------------------------
# Task 5: 既有世界观和同人命名护栏
# 上游依据：d83d99c
# ----------------------------------------------------------------------

# 至少一个长篇设定文件含 fanfic / historical_derivative / imported_existing_world 模式识别
@test "task5 long-form setting files recognize non-original world modes" {
    hit=0
    for f in \
        "$SRC/story-long-write/references/character-basics.md" \
        "$SRC/story-long-write/references/genre-catalog.md" \
        "$SRC/story-long-write/references/plot-special-topics.md"; do
        if [ -f "$f" ] && grep -qE "fanfic|historical_derivative|imported_existing_world" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no non-original world mode recognition"; false; }
}

# 命名护栏规则说明：非原创模式下启用，但给 advisory 不硬阻断
@test "task5 naming guardrail is advisory not hard-block in non-original modes" {
    hit=0
    for f in \
        "$SRC/story-long-write/references/character-basics.md" \
        "$SRC/story-long-write/references/genre-catalog.md" \
        "$SRC/story-long-write/references/plot-special-topics.md" \
        "$SRC/story-review/SKILL.md"; do
        if [ -f "$f" ] && grep -qE "命名.{0,30}(规律|护栏|advisory|替代)" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no advisory-only naming guardrail rule"; false; }
}

# ----------------------------------------------------------------------
# Task 6: 开书时主动发现本地对标
# 上游依据：b1e9ddb
# ----------------------------------------------------------------------

# 至少一个开书 SKILL 含对标发现规则（返回主对标/辅助候选）
@test "task6 opening skill discovers local benchmark assets" {
    hit=0
    for f in \
        "$SRC/story-short-write/SKILL.md" \
        "$SRC/story-long-write/SKILL.md" \
        "$SRC/story/SKILL.md"; do
        if [ -f "$f" ] && grep -qE "主对标.{0,8}候选|辅助.{0,5}(候选|对标)|发现.{0,10}本地对标|本地对标.{0,10}发现" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no local benchmark discovery rule"; false; }
}

# 规则说明：找不到本地对标时不阻断、不联网
@test "task6 benchmark discovery non-blocking and offline" {
    hit=0
    for f in \
        "$SRC/story-short-write/SKILL.md" \
        "$SRC/story-long-write/SKILL.md" \
        "$SRC/story/SKILL.md"; do
        if [ -f "$f" ] && grep -qE "找不到.{0,15}(不阻断|继续)|不联网|无对标.{0,15}继续" "$f"; then
            hit=1
            break
        fi
    done
    [ "$hit" -eq 1 ] || { echo "no non-blocking offline discovery rule"; false; }
}
