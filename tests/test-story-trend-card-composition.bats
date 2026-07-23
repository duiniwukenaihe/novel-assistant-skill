#!/usr/bin/env bats
# tests/test-story-trend-card-composition.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    PRIVATE_SKILL="$REPO/src/private-internal-skills/private-short-extension"
    SKILL_MD="$PRIVATE_SKILL/SKILL.md"
    PRIVATE_ROUTE="$PRIVATE_SKILL/references/novel-assistant-private-route.md"
    REGISTRY="$PRIVATE_SKILL/workflow-registry.json"
    CARD_DOC="$PRIVATE_SKILL/references/card-composition-system.md"
    MATERIAL_BANK="$PRIVATE_SKILL/references/material-bank.md"
    INSPIRATION="$PRIVATE_SKILL/references/inspiration-engine.md"
    PIPELINE="$PRIVATE_SKILL/scripts/card_pipeline.py"
    BUNDLE_PRIVATE="$REPO/skills/novel-assistant/references/private-internal-skills/private-short-extension"
}

@test "private short workflow defines material hotspot topic card layers" {
    test -f "$CARD_DOC"
    grep -q "素材卡 -> 爆点卡 -> 选题卡" "$CARD_DOC"
    grep -q "平台是强约束" "$CARD_DOC"
    grep -q "平台不能替代爆点本身" "$CARD_DOC"
    grep -q "material_card" "$CARD_DOC"
    grep -q "hotspot_card" "$CARD_DOC"
    grep -q "topic_card" "$CARD_DOC"
    grep -q "source_material_ids" "$CARD_DOC"
    grep -q "hotspot_ids" "$CARD_DOC"
    grep -q "platform_reader_profile" "$CARD_DOC"
    grep -q "platform_trope_fit" "$CARD_DOC"
}

@test "fresh material workflow separates info source selection from brainstorm card generation" {
    grep -q "资讯池" "$PRIVATE_ROUTE"
    grep -q "选择资讯后" "$PRIVATE_ROUTE"
    grep -q "不得直接跳到脑洞卡池" "$PRIVATE_ROUTE"
    grep -q "short_info_source_pool" "$REGISTRY"
    grep -q '"stage_id": "info_source_pool"' "$REGISTRY"
    grep -q '"stage_id": "freshness_window"' "$REGISTRY"
    grep -q '最近 24 小时' "$REGISTRY"
    grep -q '"frontend_surface": "short_info_source_pool"' "$REGISTRY"
    grep -q '"stage_id": "material_learning"' "$REGISTRY"
    grep -q '"info_source_pool"' "$REGISTRY"

    grep -q "资讯候选" "$CARD_DOC"
    grep -q "先选资讯" "$CARD_DOC"
    grep -q "选择资讯后" "$CARD_DOC"
}

@test "info source pool persists retained cards across discovery rounds" {
    workspace="$TMPDIR/story-trend-info-pool-$$"
    mkdir -p "$workspace"
    first="$workspace/first.json"
    second="$workspace/second.json"
    cat > "$first" <<'JSON'
[{"card_type":"info_source_card","info_id":"info_a","title":"第一轮保留","source_refs":[{"title":"来源A","url":"https://example.com/a","date":"2026-07-16"}],"factual_summary":"第一轮事实","human_conflict":"第一轮冲突","scorecard":{"tomato_fit":9},"verdict":"write","route_fit":[{"route_name":"反诈","recommendation":"primary","reason":"可反打"}],"learning_notes":{"source_pattern":"A","reusable_conflict_pattern":"A","platform_signal":"A","query_expansion_hint":"A","next_reuse_rule":"A"}}]
JSON
    cat > "$second" <<'JSON'
[{"card_type":"info_source_card","info_id":"info_b","title":"第二轮新增","source_refs":[{"title":"来源B","url":"https://example.com/b","date":"2026-07-16"}],"factual_summary":"第二轮事实","human_conflict":"第二轮冲突","scorecard":{"tomato_fit":8},"verdict":"backup","route_fit":[{"route_name":"婚恋","recommendation":"primary","reason":"可反转"}],"learning_notes":{"source_pattern":"B","reusable_conflict_pattern":"B","platform_signal":"B","query_expansion_hint":"B","next_reuse_rule":"B"}}]
JSON

    run python3 "$PIPELINE" info-pool import --workspace "$workspace" --input "$first" --round round-1
    [ "$status" -eq 0 ]
    run python3 "$PIPELINE" info-pool retain --workspace "$workspace" --info-ids info_a
    [ "$status" -eq 0 ]
    run python3 "$PIPELINE" info-pool import --workspace "$workspace" --input "$second" --round round-2
    [ "$status" -eq 0 ]
    [[ "$output" == *'"retained_count":1'* ]]
    [[ "$output" == *'"new_count":1'* ]]
    [[ "$output" == *'"info_id":"info_a"'* ]]
    [[ "$output" == *'"info_id":"info_b"'* ]]
    [[ "$output" == *'"display_group":"retained","display_no":1'* ]]
    [[ "$output" == *'"display_group":"new","display_no":2'* ]]
    grep -q '"pool_status": "retained"\|"pool_status":"retained"' "$workspace/追踪/private-short-extension/cards/info-source-cards.jsonl"

    run python3 "$PIPELINE" info-pool select --workspace "$workspace" --info-ids info_a,info_b
    [ "$status" -eq 0 ]
    [[ "$output" == *'"selected"'* ]]
    grep -q '"pool_status": "selected"\|"pool_status":"selected"' "$workspace/追踪/private-short-extension/cards/info-source-cards.jsonl"
}

@test "card composition documents compatible multi-source plot-bomb combinations" {
    grep -q "主冲突" "$CARD_DOC"
    grep -q "压力放大器" "$CARD_DOC"
    grep -q "证据/反转机制" "$CARD_DOC"
    grep -q "人物关系能否自然相连" "$CARD_DOC"
    grep -q "不能把两条真实事件机械并置" "$PRIVATE_ROUTE"
}

@test "unspecified short material discovery stays broad until sources are scored" {
    grep -q "开放题材" "$PRIVATE_ROUTE"
    grep -q "先广域获取" "$PRIVATE_ROUTE"
    grep -q "题材聚类" "$PRIVATE_ROUTE"
    ! grep -q '题材方向=现代世情/复仇打脸' "$PRIVATE_ROUTE"

    grep -q "不得在资讯获取前按题材淘汰" "$PRIVATE_SKILL/references/search-strategy.md"
    grep -q "天气灾害" "$PRIVATE_SKILL/references/search-strategy.md"
    grep -q "科技相邻" "$PRIVATE_SKILL/references/search-strategy.md"
}

@test "info source pool scores news and explains route fit before cards" {
    grep -q "素材评分表" "$PRIVATE_ROUTE"
    grep -q "write / backup / discard" "$PRIVATE_ROUTE"
    grep -q "主推荐路线" "$PRIVATE_ROUTE"
    grep -q "不适合路线" "$PRIVATE_ROUTE"
    grep -q "只允许 write 和强 backup" "$PRIVATE_ROUTE"
    grep -q "资讯学习摘要" "$PRIVATE_ROUTE"
    grep -q "学习笔记" "$PRIVATE_ROUTE"

    grep -q "评分" "$REGISTRY"
    grep -q "write/backup/discard" "$REGISTRY"
    grep -q "主推荐路线" "$REGISTRY"
    grep -q "学习" "$REGISTRY"

    grep -q "info_source_card" "$CARD_DOC"
    grep -q "route_fit" "$CARD_DOC"
    grep -q "verdict" "$CARD_DOC"
    grep -q "learning_notes" "$CARD_DOC"
    grep -q "可复用模式" "$CARD_DOC"
}

@test "fresh search strategy uses configurable source coverage and visible learning" {
    SEARCH="$PRIVATE_SKILL/references/search-strategy.md"
    LEARNING="$PRIVATE_SKILL/references/learning-loop.md"
    FILTER="$PRIVATE_SKILL/references/source-filter.md"

    grep -q "Source Coverage Matrix" "$SEARCH"
    grep -q "不要把具体事件写死" "$SEARCH"
    grep -q "公共事件" "$SEARCH"
    grep -q "query seed" "$SEARCH"
    grep -q "资讯学习摘要" "$LEARNING"
    grep -q "learning-ledger.jsonl" "$LEARNING"
    grep -q "下次如何影响抓取" "$LEARNING"
    grep -q "有价值资源" "$FILTER"
    grep -q "价值评分" "$FILTER"
}

@test "fresh news policy is configurable and keeps news separate from methodology" {
    test -f "$PRIVATE_SKILL/references/fresh-news-policy.json"
    test -f "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'primary_window_hours' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q '"primary_window_hours": 24' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q '"default_mode": "heat_first"' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q 'expand_requires_user_confirmation' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q 'min_recent_news_cards' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q 'min_hot_topic_cards' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q 'min_discussion_ready_cards' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q 'hot_topic' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q 'news_event' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q 'methodology' "$PRIVATE_SKILL/references/fresh-news-policy.json"
    grep -q '百度热搜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '腾讯新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '新浪新闻与娱乐榜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '网易新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '抖音热榜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '今日头条热榜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '微博热搜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '知乎热榜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '哔哩哔哩热门' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '快手热点' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '小红书发现' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '搜狐新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'top.baidu.com' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'news.qq.com' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'news.sina.com.cn' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'news.163.com' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'douyin.com' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'toutiao.com' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 's.weibo.com' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'validate-fresh' "$PRIVATE_SKILL/references/search-strategy.md"
    grep -q '不需要用户先限定题材' "$PRIVATE_SKILL/references/search-strategy.md"
}

@test "fresh gate accepts current hot-list topics without article dates" {
    tmp="${TMPDIR:-/tmp}/fresh-hot-topics-ok-$$.json"
    cat > "$tmp" <<'JSON'
{
  "discovery_policy": {"as_of_date":"2026-07-16","min_primary_news_cards":0,"min_recent_news_cards":0,"min_hot_topic_cards":4,"min_discussion_ready_cards":4,"min_event_clusters":4,"min_source_domains":4},
  "discovery_evidence": {"performed":true,"methods":["browser_cdp"],"queried_at":"2026-07-16"},
  "info_source_cards": [
    {"card_type":"info_source_card","info_id":"h1","source_kind":"hot_topic","verification_status":"unverified","event_fingerprint":"baidu-1","source_refs":[{"title":"百度热榜词条","url":"https://top.baidu.com/board?tab=realtime"}],"heat_evidence":[{"source":"百度热搜","observed_at":"2026-07-16","signal":"public_hotlist_rank","value":"1"}],"discussion_value":{"question":"谁应承担代价？","positions":["个人负责","平台负责"],"fiction_entry":"家庭冲突"},"factual_summary":"榜单词条，不作事实背书","human_conflict":"责任争夺","scorecard":{"fiction_value":8},"verdict":"write","route_fit":[{"route_name":"世情"}],"learning_notes":{"source_pattern":"热榜","reusable_conflict_pattern":"责任转移","platform_signal":"争议","query_expansion_hint":"同题讨论","next_reuse_rule":"匿名化"}},
    {"card_type":"info_source_card","info_id":"h2","source_kind":"hot_topic","verification_status":"single_source","event_fingerprint":"tencent-1","source_refs":[{"title":"腾讯新闻热点","url":"https://news.qq.com/"}],"heat_evidence":[{"source":"腾讯新闻","observed_at":"2026-07-16","signal":"discussion_metric","value":"100000"}],"discussion_value":{"question":"真心能否被利用？","positions":["应当原谅","必须追责"],"fiction_entry":"婚恋反转"},"factual_summary":"单源热点","human_conflict":"信任利用","scorecard":{"fiction_value":8},"verdict":"write","route_fit":[{"route_name":"婚恋"}],"learning_notes":{"source_pattern":"热点","reusable_conflict_pattern":"信任背叛","platform_signal":"讨论","query_expansion_hint":"评论争议","next_reuse_rule":"去真人化"}},
    {"card_type":"info_source_card","info_id":"h3","source_kind":"hot_topic","verification_status":"unverified","event_fingerprint":"sina-1","source_refs":[{"title":"新浪娱乐热点","url":"https://ent.sina.com.cn/topnews/"}],"heat_evidence":[{"source":"新浪娱乐榜","observed_at":"2026-07-16","signal":"public_hotlist_rank","value":"3"}],"discussion_value":{"question":"公众评价是否公平？","positions":["公众有权评价","私人边界优先"],"fiction_entry":"身份错认"},"factual_summary":"娱乐热榜词条","human_conflict":"名誉与隐私","scorecard":{"fiction_value":8},"verdict":"backup","route_fit":[{"route_name":"都市"}],"learning_notes":{"source_pattern":"娱乐榜","reusable_conflict_pattern":"身份压力","platform_signal":"围观","query_expansion_hint":"同类舆情","next_reuse_rule":"不使用真人姓名"}},
    {"card_type":"info_source_card","info_id":"h4","source_kind":"hot_topic","verification_status":"corroborated","event_fingerprint":"netease-1","source_refs":[{"title":"网易新闻热议","url":"https://news.163.com/"}],"heat_evidence":[{"source":"网易新闻","observed_at":"2026-07-16","signal":"rapid_followup","value":"多轮跟进"}],"discussion_value":{"question":"家庭秘密该不该公开？","positions":["应当公开","应保护家人"],"fiction_entry":"遗产反转"},"factual_summary":"多源跟进热点","human_conflict":"真相与亲情","scorecard":{"fiction_value":9},"verdict":"write","route_fit":[{"route_name":"家庭"}],"learning_notes":{"source_pattern":"热议","reusable_conflict_pattern":"秘密公开","platform_signal":"持续跟进","query_expansion_hint":"后续报道","next_reuse_rule":"抽象事件结构"}}
  ],
  "material_cards": [], "hotspot_cards": [], "topic_cards": []
}
JSON
    run python3 "$PIPELINE" validate-fresh "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hot_topic_cards":4'* ]]
    [[ "$output" == *'"unverified_hot_topics":2'* ]]
    [[ "$output" == *'"source_domains":4'* ]]
}

@test "fresh gate rejects stale heat observations and missing verification labels" {
    tmp="${TMPDIR:-/tmp}/fresh-hot-topics-stale-$$.json"
    cat > "$tmp" <<'JSON'
{
  "discovery_policy": {"as_of_date":"2026-07-16","min_primary_news_cards":0,"min_recent_news_cards":0,"min_hot_topic_cards":1,"min_discussion_ready_cards":1,"min_event_clusters":1,"min_source_domains":1},
  "discovery_evidence": {"performed":true,"methods":["web_search"],"queried_at":"2026-07-16"},
  "info_source_cards": [
    {"card_type":"info_source_card","info_id":"stale","source_kind":"hot_topic","event_fingerprint":"stale-1","source_refs":[{"title":"旧热榜","url":"https://top.baidu.com/board?tab=realtime"}],"heat_evidence":[{"source":"百度热搜","observed_at":"2026-07-10","signal":"public_hotlist_rank","value":"1"}],"discussion_value":{"question":"谁负责？","positions":["甲","乙"],"fiction_entry":"家庭"},"factual_summary":"旧词条","human_conflict":"冲突","scorecard":{"fiction_value":8},"verdict":"write","route_fit":[{"route_name":"世情"}],"learning_notes":{"source_pattern":"热榜","reusable_conflict_pattern":"冲突","platform_signal":"热度","query_expansion_hint":"后续","next_reuse_rule":"匿名"}}
  ],
  "material_cards": [], "hotspot_cards": [], "topic_cards": []
}
JSON
    run python3 "$PIPELINE" validate-fresh "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *'missing_or_invalid_verification_status'* ]]
    [[ "$output" == *'stale_hot_topic'* ]]
    [[ "$output" == *'insufficient_hot_topics'* ]]
}

@test "fresh news gate accepts a verified current news mix" {
    tmp="${TMPDIR:-/tmp}/fresh-news-ok-$$.json"
    cat > "$tmp" <<'JSON'
{
  "discovery_policy": {"as_of_date":"2026-07-16","primary_window_hours":72,"recent_window_days":7},
  "discovery_evidence": {"performed":true,"methods":["web_search"],"queried_at":"2026-07-16"},
  "info_source_cards": [
    {"card_type":"info_source_card","info_id":"n1","source_kind":"news_event","event_fingerprint":"event-1","source_refs":[{"title":"A","url":"https://a.example/news/1","date":"2026-07-16"}],"heat_evidence":[{"source":"A热榜","observed_at":"2026-07-16","signal":"public_hotlist_rank","value":"12"}],"discussion_value":{"question":"A该由谁承担？","positions":["个人负责","系统负责"],"fiction_entry":"家庭选择"},"factual_summary":"A","human_conflict":"A","scorecard":{"fiction_value":8},"verdict":"write","route_fit":[{"route_name":"A"}],"learning_notes":{"source_pattern":"A","reusable_conflict_pattern":"A","platform_signal":"A","query_expansion_hint":"A","next_reuse_rule":"A"}},
    {"card_type":"info_source_card","info_id":"n2","source_kind":"news_event","event_fingerprint":"event-2","source_refs":[{"title":"B","url":"https://b.example/news/2","date":"2026-07-15"}],"heat_evidence":[{"source":"B热榜","observed_at":"2026-07-16","signal":"public_hotlist_rank","value":"8"}],"discussion_value":{"question":"B该保护谁？","positions":["保护弱者","尊重规则"],"fiction_entry":"关系决裂"},"factual_summary":"B","human_conflict":"B","scorecard":{"fiction_value":8},"verdict":"write","route_fit":[{"route_name":"B"}],"learning_notes":{"source_pattern":"B","reusable_conflict_pattern":"B","platform_signal":"B","query_expansion_hint":"B","next_reuse_rule":"B"}},
    {"card_type":"info_source_card","info_id":"n3","source_kind":"news_event","event_fingerprint":"event-3","source_refs":[{"title":"C","url":"https://c.example/news/3","date":"2026-07-12"}],"heat_evidence":[{"source":"C媒体群","observed_at":"2026-07-16","signal":"cross_source_reports","value":"6"}],"discussion_value":{"question":"C是否公平？","positions":["结果公平","过程公平"],"fiction_entry":"职场反证"},"factual_summary":"C","human_conflict":"C","scorecard":{"fiction_value":8},"verdict":"backup","route_fit":[{"route_name":"C"}],"learning_notes":{"source_pattern":"C","reusable_conflict_pattern":"C","platform_signal":"C","query_expansion_hint":"C","next_reuse_rule":"C"}},
    {"card_type":"info_source_card","info_id":"n4","source_kind":"news_event","event_fingerprint":"event-4","source_refs":[{"title":"D","url":"https://d.example/news/4","date":"2026-07-10"}],"heat_evidence":[{"source":"D热榜","observed_at":"2026-07-16","signal":"discussion_metric","value":"100000"}],"discussion_value":{"question":"D该不该原谅？","positions":["可以原谅","必须追责"],"fiction_entry":"证据反转"},"factual_summary":"D","human_conflict":"D","scorecard":{"fiction_value":8},"verdict":"backup","route_fit":[{"route_name":"D"}],"learning_notes":{"source_pattern":"D","reusable_conflict_pattern":"D","platform_signal":"D","query_expansion_hint":"D","next_reuse_rule":"D"}},
    {"card_type":"info_source_card","info_id":"m1","source_kind":"methodology","source_refs":[{"title":"Method","url":"https://method.example/guide","date":"2025-01-01"}],"factual_summary":"M","human_conflict":"M","scorecard":{"learning_value":8},"verdict":"backup","route_fit":[{"route_name":"method"}],"learning_notes":{"source_pattern":"M","reusable_conflict_pattern":"M","platform_signal":"M","query_expansion_hint":"M","next_reuse_rule":"M"}}
  ],
  "material_cards": [], "hotspot_cards": [], "topic_cards": []
}
JSON
    run python3 "$PIPELINE" validate-fresh "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"recent_news_cards":4'* ]]
    [[ "$output" == *'"hot_topic_cards":4'* ]]
    [[ "$output" == *'"discussion_ready_cards":4'* ]]
    [[ "$output" == *'"methodology_cards":1'* ]]
}

@test "fresh news gate rejects stale cases and cannot count methodology as news" {
    tmp="${TMPDIR:-/tmp}/fresh-news-stale-$$.json"
    cat > "$tmp" <<'JSON'
{
  "discovery_policy": {"as_of_date":"2026-07-16"},
  "discovery_evidence": {"performed":false,"methods":[],"queried_at":"2026-07-16"},
  "info_source_cards": [
    {"card_type":"info_source_card","info_id":"old","source_kind":"news_event","event_fingerprint":"old-event","source_refs":[{"title":"Old","url":"https://old.example/news","date":"2025-06-01"}],"factual_summary":"old","human_conflict":"old","scorecard":{"fiction_value":8},"verdict":"write","route_fit":[{"route_name":"old"}],"learning_notes":{"source_pattern":"old","reusable_conflict_pattern":"old","platform_signal":"old","query_expansion_hint":"old","next_reuse_rule":"old"}},
    {"card_type":"info_source_card","info_id":"method","source_kind":"methodology","source_refs":[{"title":"Method","url":"https://method.example/guide","date":"2026-07-16"}],"factual_summary":"method","human_conflict":"method","scorecard":{"learning_value":8},"verdict":"backup","route_fit":[{"route_name":"method"}],"learning_notes":{"source_pattern":"method","reusable_conflict_pattern":"method","platform_signal":"method","query_expansion_hint":"method","next_reuse_rule":"method"}}
  ],
  "material_cards": [], "hotspot_cards": [], "topic_cards": []
}
JSON
    run python3 "$PIPELINE" validate-fresh "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *'stale_news_source'* ]]
    [[ "$output" == *'insufficient_recent_news'* ]]
    [[ "$output" == *'insufficient_hot_topics'* ]]
    [[ "$output" == *'"methodology_cards":1'* ]]
}

@test "private-short-extension loads card composition before online card generation" {
    grep -q "card-composition-system.md" "$SKILL_MD"
    grep -q "在线获取" "$SKILL_MD"
    grep -q "爆点卡" "$SKILL_MD"
    grep -q "组合" "$SKILL_MD"
}

@test "material and inspiration docs point card work to the composition system" {
    grep -q "card-composition-system.md" "$MATERIAL_BANK"
    grep -q "素材卡" "$MATERIAL_BANK"
    grep -q "爆点卡" "$MATERIAL_BANK"
    grep -q "card-composition-system.md" "$INSPIRATION"
    grep -q "选题卡" "$INSPIRATION"
}

@test "card pipeline validates composed topic lineage" {
    tmp="${TMPDIR:-/tmp}/cards-ok-$$.json"
    cat > "$tmp" <<'JSON'
{
  "info_source_cards": [
    {
      "card_type": "info_source_card",
      "info_id": "info_001",
      "source_refs": [{"title": "公开素材", "url": "https://example.com/a", "date": "2026-07-08"}],
      "title": "相亲角标价",
      "factual_summary": "母亲在相亲角公开给女儿标价。",
      "human_conflict": "亲情定价与自我定价冲突",
      "scorecard": {"click_hook": 9, "emotional_intensity": 8, "tomato_fit": 9, "fictionalization_safety": 8},
      "verdict": "write",
      "route_fit": [{"route_name": "现代世情反打", "recommendation": "primary", "reason": "公开羞辱适合快速反打"}],
      "learning_notes": {
        "source_pattern": "公开羞辱+亲情定价",
        "reusable_conflict_pattern": "亲人把主角当商品，主角反向定价",
        "platform_signal": "番茄短篇适合快速公开反打",
        "query_expansion_hint": "相亲角 标价 亲情 边界",
        "next_reuse_rule": "同类素材优先找公开场景和可反证证据"
      }
    }
  ],
  "material_cards": [
    {
      "card_type": "material_card",
      "canonical_id": "mat_001",
      "source_type": "online",
      "source_info_ids": ["info_001"],
      "source_refs": [{"title": "公开素材", "url": "https://example.com/a"}],
      "title": "相亲角标价",
      "event_summary": "母亲在相亲角公开给女儿标价。",
      "human_conflict": "亲情定价与自我定价冲突",
      "extractable_hotspots": ["hot_001"]
    }
  ],
  "hotspot_cards": [
    {
      "card_type": "hotspot_card",
      "hotspot_id": "hot_001",
      "source_material_ids": ["mat_001"],
      "hotspot_line": "被亲人当众标价后反向抬价",
      "reader_desire": "尊严反击",
      "payoff_shape": "公开打脸"
    }
  ],
  "topic_cards": [
    {
      "card_type": "topic_card",
      "topic_id": "top_001",
      "primary_hotspot_id": "hot_001",
      "supporting_hotspot_ids": [],
      "hotspot_ids": ["hot_001"],
      "target_platform": "番茄短篇",
      "genre_lane": "现代世情",
      "title_candidates": ["我妈在相亲角给我标价28万"]
    }
  ]
}
JSON
    run python3 "$PIPELINE" validate "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"ok"'* ]]
}

@test "card pipeline rejects info source without route verdict" {
    tmp="${TMPDIR:-/tmp}/info-source-bad-$$.json"
    cat > "$tmp" <<'JSON'
{
  "info_source_cards": [
    {
      "card_type": "info_source_card",
      "info_id": "info_001",
      "source_refs": [{"title": "公开素材", "url": "https://example.com/a"}],
      "title": "相亲角标价",
      "factual_summary": "母亲在相亲角公开给女儿标价。",
      "human_conflict": "亲情定价与自我定价冲突",
      "verdict": "write",
      "route_fit": [],
      "learning_notes": {
        "source_pattern": "公开羞辱+亲情定价",
        "reusable_conflict_pattern": "亲人把主角当商品",
        "platform_signal": "番茄短篇适合公开反打",
        "query_expansion_hint": "相亲角 标价",
        "next_reuse_rule": "找可公开兑现的证据"
      }
    }
  ],
  "material_cards": [],
  "hotspot_cards": [],
  "topic_cards": []
}
JSON
    run python3 "$PIPELINE" validate "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing_route_fit"* ]]
}

@test "card pipeline rejects info source without learning notes" {
    tmp="${TMPDIR:-/tmp}/info-source-no-learning-$$.json"
    cat > "$tmp" <<'JSON'
{
  "info_source_cards": [
    {
      "card_type": "info_source_card",
      "info_id": "info_001",
      "source_refs": [{"title": "公开素材", "url": "https://example.com/a"}],
      "title": "相亲角标价",
      "factual_summary": "母亲在相亲角公开给女儿标价。",
      "human_conflict": "亲情定价与自我定价冲突",
      "scorecard": {"click_hook": 9},
      "verdict": "write",
      "route_fit": [{"route_name": "现代世情反打", "recommendation": "primary", "reason": "公开羞辱适合快速反打"}]
    }
  ],
  "material_cards": [],
  "hotspot_cards": [],
  "topic_cards": []
}
JSON
    run python3 "$PIPELINE" validate "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing_learning_notes"* ]]
}

@test "card pipeline rejects topic without valid hotspot lineage" {
    tmp="${TMPDIR:-/tmp}/cards-bad-$$.json"
    cat > "$tmp" <<'JSON'
{
  "material_cards": [
    {
      "card_type": "material_card",
      "canonical_id": "mat_001",
      "source_type": "online",
      "source_refs": [{"title": "公开素材", "url": "https://example.com/a"}],
      "title": "相亲角标价"
    }
  ],
  "hotspot_cards": [],
  "topic_cards": [
    {
      "card_type": "topic_card",
      "topic_id": "top_001",
      "primary_hotspot_id": "hot_missing",
      "hotspot_ids": ["hot_missing"],
      "target_platform": "番茄短篇"
    }
  ]
}
JSON
    run python3 "$PIPELINE" validate "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing_hotspot"* ]]
}

@test "private bundle includes card composition assets" {
    test -f "$BUNDLE_PRIVATE/references/card-composition-system.md"
    test -f "$BUNDLE_PRIVATE/references/fresh-news-policy.json"
    test -f "$BUNDLE_PRIVATE/references/hot-source-profiles.json"
    test -f "$BUNDLE_PRIVATE/scripts/card_pipeline.py"
    grep -q "素材卡 -> 爆点卡 -> 选题卡" "$BUNDLE_PRIVATE/references/card-composition-system.md"
    grep -q "validate-fresh" "$BUNDLE_PRIVATE/references/search-strategy.md"
    grep -q "网易新闻" "$BUNDLE_PRIVATE/references/hot-source-profiles.json"
}
