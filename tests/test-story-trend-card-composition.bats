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
    HOT_CAPTURE="$PRIVATE_SKILL/scripts/hot_source_capture.js"
    HOT_PROVIDERS="$PRIVATE_SKILL/references/hot-source-providers.json"
    DISCOVERY_PLAN="$REPO/scripts/hot-source-discovery-plan.js"
    BUNDLE_PRIVATE="$REPO/skills/novel-assistant/references/private-internal-skills/private-short-extension"
}

@test "topic card gate rejects symbolic payoffs and thematic multi-source montages" {
    fixture="$TMPDIR/story-value-cards-$$.json"
    node - "$fixture" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const info=[1,2].map(i=>({card_type:'info_source_card',info_id:`info-${i}`,source_refs:[{url:`https://example.com/${i}`}],factual_summary:`事实${i}`,human_conflict:`冲突${i}`,verdict:'write',route_fit:['番茄短篇'],scorecard:{material_score:8},learning_notes:{source_pattern:'现实冲突',reusable_conflict_pattern:'权力压迫',platform_signal:'热榜',query_expansion_hint:'家庭',next_reuse_rule:'保留因果'}}));
const material=[1,2].map(i=>({card_type:'material_card',canonical_id:`mat-${i}`,source_type:'online',source_info_ids:[`info-${i}`],source_refs:[{url:`https://example.com/${i}`}],title:`素材${i}`,event_summary:'事件',human_conflict:'冲突',emotion_trigger:'愤怒',protagonist_seed:'主角',immediate_stakes:'立即失去工作',actionable_choice:'公开证据并报警',extractable_hotspots:[`hot-${i}`]}));
const hotspot=[1,2].map(i=>({card_type:'hotspot_card',hotspot_id:`hot-${i}`,source_material_ids:[`mat-${i}`],hotspot_line:'当众拆穿',reader_desire:'反打',emotional_entry:'愤怒',power_relation:'员工对老板',oppressor:'老板',protagonist_action:'直播公开账本',escalation_trigger:'老板停职威胁',counterattack_method:'报警并提交录音',reversal_method:'监管调取证据',payoff_shape:'公司停产整改并退款',reusable_scene:'直播间',platform_fit:['番茄短篇']}));
const topic={card_type:'topic_card',topic_id:'topic-1',primary_hotspot_id:'hot-1',supporting_hotspot_ids:['hot-2'],target_platform:'番茄短篇',title_candidates:['两座城的纸条'],genre_lane:'现实情感',opening_scene:'两座城市同时发生事故',story_promise:'两件事互相映照',protagonist_pressure:'主角被迫选择',antagonist_pressure:'舆论压迫',irreversible_choice:'她保存了照片',escalation_beats:['她想起旧事','另一座城也有人哭','两人分别写下日记'],first_reversal:'她终于理解母亲',final_payoff:'她把照片换成母亲的合影',expected_length:'8000字',hotspot_ids:['hot-1','hot-2'],combination_bridge:{primary_conflict:'两座城市的痛苦',pressure_amplifier:'同时发生',evidence_or_reversal:'平行蒙太奇',causal_chain:'不同城市互相映照'}};
fs.writeFileSync(file,JSON.stringify({info_source_cards:info,material_cards:material,hotspot_cards:hotspot,topic_cards:[topic]}));
NODE
    run python3 "$PIPELINE" validate "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *'protagonist_choice_lacks_external_action'* ]]
    [[ "$output" == *'final_payoff_lacks_visible_consequence'* ]]
    [[ "$output" == *'multi_source_combination_is_thematic_not_causal'* ]]
}

@test "topic card gate accepts causal action escalation and visible payoff" {
    fixture="$TMPDIR/story-value-good-$$.json"
    node - "$fixture" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const info={card_type:'info_source_card',info_id:'info-1',source_refs:[{url:'https://example.com/1'}],factual_summary:'企业虚假宣传',human_conflict:'员工生计与消费者知情权冲突',verdict:'write',route_fit:['番茄短篇'],scorecard:{material_score:9},learning_notes:{source_pattern:'商业欺骗',reusable_conflict_pattern:'亲情包庇',platform_signal:'热榜',query_expansion_hint:'职场家庭',next_reuse_rule:'主角必须承担现实代价'}};
const material={card_type:'material_card',canonical_id:'mat-1',source_type:'online',source_info_ids:['info-1'],source_refs:[{url:'https://example.com/1'}],title:'空工厂直播',event_summary:'主播发现工厂造假',human_conflict:'亲情与真相',emotion_trigger:'愤怒',protagonist_seed:'家族企业女儿',immediate_stakes:'沉默会继续欺骗消费者',actionable_choice:'直播公开证据并接受停职',extractable_hotspots:['hot-1']};
const hotspot={card_type:'hotspot_card',hotspot_id:'hot-1',source_material_ids:['mat-1'],hotspot_line:'直播镜头转向空生产线',reader_desire:'公开反打',emotional_entry:'背叛',power_relation:'女儿对家族董事会',oppressor:'哥哥与虚假宣传',protagonist_action:'直播公开仓库和账本',escalation_trigger:'哥哥冻结账号并威胁员工工资',counterattack_method:'向监管提交录音与批次记录',reversal_method:'监管当场封存宣传材料',payoff_shape:'旧货召回退款，真实生产线整改后公开复产',reusable_scene:'直播间和董事会',platform_fit:['番茄短篇']};
const topic={card_type:'topic_card',topic_id:'topic-1',primary_hotspot_id:'hot-1',target_platform:'番茄短篇',title_candidates:['我直播鲜榨工厂，镜头里却没有水果'],genre_lane:'现实反打',opening_scene:'全网逼问她敢不敢拍生产线',story_promise:'她会亲手拆穿家族企业并承担复产代价',protagonist_pressure:'公开会失去家人与职位，沉默会继续欺骗消费者',antagonist_pressure:'哥哥冻结权限并拿员工工资施压',irreversible_choice:'她切断官方直播，改用私人账号公开账本并向监管举报',escalation_beats:['哥哥冻结权限，她公开录音反证','董事会要求删稿，她提交批次记录触发监管进厂','员工质问工资，她公开保障方案并投票暂停哥哥职务'],first_reversal:'监管调取账本后当场封存宣传材料，哥哥第一次失去控制权',final_payoff:'企业召回退款并停产整改，三个月后真实鲜果生产线恢复直播，消费者可核验批次',expected_length:'10000字'};
fs.writeFileSync(file,JSON.stringify({info_source_cards:[info],material_cards:[material],hotspot_cards:[hotspot],topic_cards:[topic]}));
NODE
    run python3 "$PIPELINE" validate "$fixture"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"ok"'* ]]
}

@test "topic value contract rejects a complete but weak primary card" {
    run python3 - "$PIPELINE" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('card_pipeline',sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
card={
  'topic_id':'weak-complete','value_verdict':'primary',
  'value_scorecard':{
    key:{'score':5,'reason':'字段完整但题眼普通，缺少关系与反转增量'}
    for key in ('premise_freshness','immediate_stakes','protagonist_agency','relationship_tension','escalation_quality','reversal_fairness','payoff_strength','platform_fit')
  } | {'writing_difficulty':{'score':4,'reason':'执行难度一般'}},
  'payoff_mechanism':'公开曝光','conflict_domain':'职场','relationship_engine':'员工对老板','reversal_mechanism':'证据翻盘'
}
errors=mod.topic_value_contract_errors(card,'weak-complete')
print(errors)
if not any(row.get('code')=='topic_value_below_primary_threshold' for row in errors): raise SystemExit(1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "topic batch diversity rejects one-note payoff and reversal routes" {
    run python3 - "$PIPELINE" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('card_pipeline',sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
cards=[{
  'topic_id':f'topic-{index}','payoff_mechanism':'直播曝光','conflict_domain':'职场',
  'relationship_engine':'员工对老板','reversal_mechanism':'证据翻盘'
} for index in range(6)]
errors=mod.topic_batch_diversity_errors(cards)
codes={row.get('code') for row in errors}
print(errors)
if 'topic_batch_payoff_homogeneous' not in codes or 'topic_batch_reversal_homogeneous' not in codes: raise SystemExit(1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "topic cards receive a deterministic recommendation rank" {
    run python3 - "$PIPELINE" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('card_pipeline',sys.argv[1])
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
def card(topic_id, score, difficulty):
    return {
      'topic_id':topic_id,
      'value_scorecard':{
        key:{'score':score,'reason':'具备明确的人物选择、升级和外部兑现'}
        for key in mod.VALUE_SCORE_FIELDS
      } | {'writing_difficulty':{'score':difficulty,'reason':'执行难度'}},
      'value_verdict':'primary' if score >= 7 else 'backup'
    }
cards=[card('middle',8,7),card('best',9,5),card('backup',6,3)]
ranked=mod.rank_topic_cards(cards)
if [row['topic_id'] for row in ranked] != ['best','middle','backup']: raise SystemExit(ranked)
if [row['recommendation_rank'] for row in ranked] != [1,2,3]: raise SystemExit(ranked)
print(ranked)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "private hot source capture uses structured provider and preserves snapshots" {
    port=$((24000 + ($$ % 1000)))
    capture_file="$TMPDIR/hot-source-capture-$$/capture.json"
    node "$REPO/tests/fixtures/fake-hot-source-server.js" "$port" &
    server_pid=$!
    sleep 0.2

    run node "$HOT_CAPTURE" \
        --profiles "$PRIVATE_SKILL/references/hot-source-profiles.json" \
        --providers "$HOT_PROVIDERS" \
        --provider-base-url "http://127.0.0.1:$port" \
        --source-ids baidu_realtime,weibo_hot \
        --window-days 1 \
        --as-of 2026-07-27 \
        --output "$capture_file" \
        --json
    kill "$server_pid" 2>/dev/null || true

    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -f "$capture_file" ]
    run node - "$capture_file" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (data.status !== 'hot_source_capture_ready') throw new Error(JSON.stringify(data));
if (data.discovery_evidence.methods[0] !== 'structured_provider') throw new Error(JSON.stringify(data.discovery_evidence));
if (data.discovery_evidence.source_attempts.length !== 2) throw new Error(JSON.stringify(data.discovery_evidence));
if (!data.discovery_evidence.source_attempts.every((item) => item.status === 'success' && item.snapshot_sha256 && item.snapshot_path)) throw new Error(JSON.stringify(data.discovery_evidence));
if (data.source_items.length !== 4) throw new Error(JSON.stringify(data.source_items));
if (!data.source_items.every((item) => item.capture_item_id && item.provider === 'newsnow' && item.observed_at === '2026-07-27')) throw new Error(JSON.stringify(data.source_items));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "private hot source capture exposes a clean help contract" {
    run node "$HOT_CAPTURE" --help
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"--external-hits"* ]]
    [[ "$output" == *"--source-ids"* ]]
}

@test "private hot source capture accepts browser and web fallback evidence with source lineage" {
    capture_dir="$TMPDIR/hot-source-external-$$"
    capture_file="$capture_dir/capture.json"
    external_file="$capture_dir/external-hits.json"
    mkdir -p "$capture_dir"
    cat > "$external_file" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "queried_at": "2026-07-27T08:00:00.000Z",
  "methods": ["browser_cdp", "web_search"],
  "queries": ["网易新闻 热点 2026-07-27"],
  "hits": [
    {
      "source_id": "netease_news",
      "source_name": "网易新闻",
      "title": "高温天外卖员休息点引发热议",
      "url": "https://news.163.com/example-hot-topic",
      "summary": "围绕劳动保障与平台责任形成讨论。",
      "observed_at": "2026-07-27",
      "rank": 3,
      "heat_signal": "public_hotlist_rank",
      "heat_value": "3"
    }
  ]
}
JSON

    run node "$HOT_CAPTURE" \
        --profiles "$PRIVATE_SKILL/references/hot-source-profiles.json" \
        --providers "$HOT_PROVIDERS" \
        --source-ids netease_news \
        --external-hits "$external_file" \
        --window-days 1 \
        --as-of 2026-07-27 \
        --output "$capture_file" \
        --json

    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run node - "$capture_file" <<'NODE'
const fs=require('fs');
const data=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const attempt=data.discovery_evidence.source_attempts[0];
const item=data.source_items[0];
if(!data.discovery_evidence.methods.includes('external_hits_json')) throw new Error(JSON.stringify(data.discovery_evidence));
if(attempt.status!=='success'||attempt.provider!=='external_hits_json'||attempt.selected_mode!=='browser_cdp+web_search') throw new Error(JSON.stringify(attempt));
if(!attempt.snapshot_path||!attempt.snapshot_sha256) throw new Error(JSON.stringify(attempt));
if(item.source_name!=='网易新闻'||item.url!=='https://news.163.com/example-hot-topic'||item.heat_value!=='3') throw new Error(JSON.stringify(item));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "private hot source capture falls back to the next configured JSON route" {
    port=$((24500 + ($$ % 1000)))
    capture_dir="$TMPDIR/hot-source-fallback-$$"
    capture_file="$capture_dir/capture.json"
    providers_file="$capture_dir/providers.json"
    mkdir -p "$capture_dir"
    cat > "$providers_file" <<JSON
{
  "schema_version": "1.1.0",
  "providers": {
    "broken": {"kind":"static_json","base_url":"http://127.0.0.1:$port","path":"/fail","timeout_ms":2000},
    "backup": {"kind":"query_json_api","base_url":"http://127.0.0.1:$port","path":"/api/s","query_key":"id","timeout_ms":2000}
  },
  "source_routes": {
    "baidu_realtime": [
      {"provider":"broken","mode":"static_json","path":"/fail"},
      {"provider":"backup","mode":"query_json_api","route":"baidu"}
    ]
  }
}
JSON
    node "$REPO/tests/fixtures/fake-hot-source-server.js" "$port" &
    server_pid=$!
    sleep 0.2

    run node "$HOT_CAPTURE" \
        --profiles "$PRIVATE_SKILL/references/hot-source-profiles.json" \
        --providers "$providers_file" \
        --source-ids baidu_realtime \
        --window-days 1 \
        --as-of 2026-07-27 \
        --output "$capture_file" \
        --json
    kill "$server_pid" 2>/dev/null || true

    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run node - "$capture_file" <<'NODE'
const fs=require('fs');
const data=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const attempt=data.discovery_evidence.source_attempts[0];
if(attempt.status!=='success'||attempt.provider!=='backup'||attempt.selected_mode!=='query_json_api') throw new Error(JSON.stringify(attempt));
if(!Array.isArray(attempt.attempted_routes)||attempt.attempted_routes.length!==2) throw new Error(JSON.stringify(attempt));
if(attempt.attempted_routes[0].status!=='failed'||attempt.attempted_routes[1].status!=='success') throw new Error(JSON.stringify(attempt));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "private hot source capture fills fixed budget with provider-backed expansion sources" {
    port=$((25000 + ($$ % 1000)))
    capture_file="$TMPDIR/hot-source-expanded-$$/capture.json"
    node "$REPO/tests/fixtures/fake-hot-source-server.js" "$port" &
    server_pid=$!
    sleep 0.2

    run node "$HOT_CAPTURE" \
        --profiles "$PRIVATE_SKILL/references/hot-source-profiles.json" \
        --providers "$HOT_PROVIDERS" \
        --provider-base-url "http://127.0.0.1:$port" \
        --window-days 1 \
        --as-of 2026-07-27 \
        --max-items 1 \
        --output "$capture_file" \
        --json
    kill "$server_pid" 2>/dev/null || true

    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run node - "$capture_file" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (data.source_summary.selected_sources !== 12) throw new Error(JSON.stringify(data.source_summary));
if (data.source_summary.successful_sources < 8) throw new Error(JSON.stringify(data.source_summary));
const ids = new Set(data.discovery_evidence.source_attempts.map(item => item.source_id));
for (const id of ['zhihu_hot', 'bilibili_popular', 'baidu_tieba_hot', 'thepaper_hot']) {
  if (!ids.has(id)) throw new Error(JSON.stringify([...ids]));
}
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "hot source validator selection excludes sources without a configured provider route" {
    run node - "$REPO/scripts/lib/hot-source-registry.js" "$PRIVATE_SKILL/references/hot-source-profiles.json" "$HOT_PROVIDERS" <<'NODE'
const fs = require('fs');
const { buildHotSourceSelection } = require(process.argv[2]);
const profiles = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const providers = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const selection = buildHotSourceSelection(profiles, { availableIds: Object.keys(providers.source_routes || {}) });
if (selection.selectedIds.includes('sohu_news')) throw new Error(JSON.stringify(selection.selectedIds));
if (!selection.selectedIds.includes('ifeng_news')) throw new Error(JSON.stringify(selection.selectedIds));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "legacy hot topic cards normalize into the private info pool contract" {
    candidate="$TMPDIR/hot-source-normalized-$$.json"
    run node - "$REPO/scripts/short-info-source-finalize.js" "$candidate" <<'NODE'
const fs = require('fs');
const { normalizeCandidatePayload } = require(process.argv[2]);
const sourceItems = Array.from({ length: 4 }, (_, index) => ({
  capture_item_id: `ref-${index + 1}`,
  source_id: `source-${index + 1}`,
  source_name: `来源${index + 1}`,
  url: `https://source${index + 1}.example/item`,
  observed_at: '2026-07-27',
  heat_signal: 'public_hotlist_rank',
  heat_value: String(index + 1),
}));
const payload = normalizeCandidatePayload({
  discovery_policy: { as_of_date: '2026-07-27' },
  discovery_evidence: { performed: true, methods: ['structured_provider'], queried_at: '2026-07-27', source_attempts: [] },
  hot_topic_cards: sourceItems.map((item, index) => ({
    card_id: `card-${index + 1}`,
    capture_refs: [item.capture_item_id],
    topic_title: `热点${index + 1}`,
    character_conflict: `人物冲突${index + 1}`,
    material_score: 8,
    decision: 'write',
    main_route: `主路线${index + 1}`,
    backup_route: `备选路线${index + 1}`,
    category: '社会讨论',
    learning_notes: `学习结论${index + 1}`,
    story_value_signals: {
      immediate_stakes: `当事人当天会失去第${index + 1}份工作和收入`,
      protagonist_action: `当事人保存第${index + 1}份证据并公开追责`,
      escalation_path: `对方先删除记录，再冻结账号，最后逼当事人承担第${index + 1}次损失`,
      credible_payoff: `监管核验第${index + 1}份证据后责令退款并公开责任人`,
    },
  })),
}, { source_items: sourceItems });
if (payload.info_source_cards.length !== 4) throw new Error(JSON.stringify(payload));
if (!payload.info_source_cards.every(card => card.card_type === 'info_source_card' && card.source_refs.length === 1 && card.discussion_value.fiction_entry)) throw new Error(JSON.stringify(payload));
fs.writeFileSync(process.argv[3], JSON.stringify(payload), 'utf8');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }

    run python3 "$PIPELINE" validate-fresh "$candidate" --policy "$PRIVATE_SKILL/references/fresh-news-policy.json"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "info source enrichment accepts the compact hot_topics alias" {
    run node - "$REPO/scripts/short-info-source-finalize.js" <<'NODE'
const { normalizeCandidatePayload } = require(process.argv[2]);
const capture = {
  source_items: [{
    capture_item_id: 'ref-1',
    source_id: 'baidu_realtime',
    source_name: '百度热搜',
    title: '热点原题',
    url: 'https://example.com/hot',
    observed_at: '2026-07-28',
    heat_signal: 'public_hotlist_rank',
    heat_value: '1',
  }],
};
const payload = normalizeCandidatePayload({
  hot_topics: [{
    card_id: 'hot-1',
    capture_refs: ['ref-1'],
    topic_title: '热点原题',
    character_conflict: '普通人的秘密被平台拿去获利',
    material_score: 8.4,
    decision: 'write',
    main_route: '隐私泄露反杀',
    learning_notes: '适合转成辅助爆点，不直接照搬真实事件',
    story_value_signals: {
      immediate_stakes: '普通人的私密对话当天被广告公开，工作和婚约同时受损',
      protagonist_action: '她保存投放记录并公开追查数据流转责任人',
      escalation_path: '平台先删证据，再让前任公司起诉她造谣，最后用家人隐私逼她撤诉',
      credible_payoff: '监管调取后台记录后停止广告并责令赔偿，责任人公开道歉',
    },
  }],
}, capture);
if (payload.info_source_cards?.length !== 1) throw new Error(JSON.stringify(payload));
if (payload.info_source_cards[0].scorecard.material_score !== 8.4) throw new Error(JSON.stringify(payload));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "info source enrichment normalizes the actual compact model card shape" {
    run node - "$REPO/scripts/short-info-source-finalize.js" <<'NODE'
const { normalizeCandidatePayload } = require(process.argv[2]);
const capture = { source_items: [{
  capture_item_id: 'ref-1', source_id: 'weibo_hot', source_name: '微博热搜',
  title: '平台处罚热点', url: 'https://example.com/hot', observed_at: '2026-07-28',
  heat_signal: 'public_hotlist_rank', heat_value: '1',
}] };
const payload = normalizeCandidatePayload({ hot_topics: [{
  hot_topic_id: 'ht-1', title: '平台处罚热点', capture_refs: ['ref-1'],
  summary: '平台因不公平规则被处罚', discussion_value: '用户、商家和员工都在争论',
  character_conflict: '员工服从公司与保护用户之间冲突', material_score: 9,
  judgment: 'write', route_fit: ['番茄', '知乎盐选'],
  angle_candidates: ['被迫执行规则的客服留下证据', '小商家联合反击平台'],
}] }, capture);
if (payload.info_source_cards?.length !== 0) throw new Error(JSON.stringify(payload));
if (payload.rejected_summary?.discarded !== 1) throw new Error(JSON.stringify(payload));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "weak hot information is downgraded to combination fuel instead of a primary story" {
    run node - "$REPO/scripts/short-info-source-finalize.js" "$REPO/scripts/short-material-learning-finalize.js" <<'NODE'
const { normalizeCandidatePayload } = require(process.argv[2]);
const { buildGenerationPlan } = require(process.argv[3]);
const payload = normalizeCandidatePayload({
  info_source_cards: [{
    info_id: 'info-weak',
    title: '模型说要吃饭',
    material_score: 7,
    verdict: 'write',
    story_value_signals: {
      immediate_stakes: '客服当天会因模型异常失去工作并承担用户退款',
      protagonist_action: '客服保存日志并向公司合规部门公开提交记录',
      escalation_path: '主管先要求删日志，再冻结账号，最后让客服独自承担全部退款',
      credible_payoff: '审计调取日志后恢复客服职位并追责主管',
    },
  }],
}, {});
if (payload.info_source_cards[0].verdict !== 'backup') throw new Error(JSON.stringify(payload));
const plan = buildGenerationPlan(payload.info_source_cards);
if (plan.primary_candidate_limit !== 0 || plan.candidate_mode !== 'exploratory_backup') throw new Error(JSON.stringify(plan));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "info source enrichment context is bounded and preserves source diversity" {
    run node - "$REPO/scripts/short-info-source-finalize.js" <<'NODE'
const { buildInfoSourceEnrichmentContext } = require(process.argv[2]);
const source_items = [];
for (let source = 1; source <= 6; source += 1) {
  for (let rank = 1; rank <= 4; rank += 1) {
    source_items.push({
      capture_item_id: `s${source}-r${rank}`,
      source_id: `source-${source}`,
      source_name: `来源${source}`,
      title: `热点${source}-${rank}`,
      url: `https://example.com/${source}/${rank}`,
      rank,
      observed_at: '2026-07-28',
      heat_signal: 'public_hotlist_rank',
      heat_value: String(rank),
    });
  }
}
const context = buildInfoSourceEnrichmentContext({ capture_id: 'capture-1', source_items }, 12);
if (context.source_items.length !== 12) throw new Error(JSON.stringify(context));
if (new Set(context.source_items.map(item => item.source_id)).size !== 6) throw new Error(JSON.stringify(context));
if (!context.candidate_shape?.info_source_cards?.required_fields?.includes('material_score')) throw new Error(JSON.stringify(context));
if (context.candidate_shape.info_source_cards.count !== '3-8，宁缺毋滥；不足 3 张时如实返回，不得凑数') throw new Error(JSON.stringify(context));
if (!context.candidate_shape.info_source_cards.required_fields.includes('story_value_signals')) throw new Error(JSON.stringify(context));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "info source enrichment clusters duplicate events and ranks personal stakes ahead of macro bulletins" {
    run node - "$REPO/scripts/short-info-source-finalize.js" <<'NODE'
const { buildInfoSourceEnrichmentContext } = require(process.argv[2]);
const capture = { source_items: [
  {capture_item_id:'ctrip-1',source_id:'baidu',source_name:'百度热搜',title:'携程被罚后内部全员信曝光',rank:1,url:'https://example.com/1'},
  {capture_item_id:'ctrip-2',source_id:'weibo',source_name:'微博热搜',title:'携程全员信曝光',rank:2,url:'https://example.com/2'},
  {capture_item_id:'wage-1',source_id:'local',source_name:'地方新闻',title:'老板扣下三百人工资，员工实名举报',rank:3,url:'https://example.com/3'},
  {capture_item_id:'policy-1',source_id:'policy',source_name:'综合热榜',title:'推动产业高质量发展进入新阶段',rank:1,url:'https://example.com/4'},
] };
const context = buildInfoSourceEnrichmentContext(capture, 12);
if (context.source_items.length !== 3) throw new Error(JSON.stringify(context.source_items));
const ctrip = context.source_items.find(item => item.title.includes('携程'));
if (!ctrip || ctrip.corroboration_count !== 2 || ctrip.capture_refs.length !== 2) throw new Error(JSON.stringify(ctrip));
if (!context.source_items[0].title.includes('工资')) throw new Error(JSON.stringify(context.source_items));
if (context.source_items.at(-1).title !== '推动产业高质量发展进入新阶段') throw new Error(JSON.stringify(context.source_items));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "generic story labels cannot promote a hot topic into the visible write pool" {
    run node - "$REPO/scripts/short-info-source-finalize.js" <<'NODE'
const { normalizeCandidatePayload, assessInfoSourcePool } = require(process.argv[2]);
const capture = { source_items: [
  {capture_item_id:'ref-1',source_id:'hot',source_name:'热榜',title:'宏观热点',url:'https://example.com/1',rank:1},
  {capture_item_id:'ref-2',source_id:'hot',source_name:'热榜',title:'工资被扣',url:'https://example.com/2',rank:2},
] };
const payload = normalizeCandidatePayload({info_source_cards:[
  {info_id:'generic',capture_refs:['ref-1'],title:'宏观热点',material_score:9,verdict:'write',story_value_signals:{immediate_stakes:'人物面临冲突',protagonist_action:'公开真相',escalation_path:'矛盾逐渐升级',credible_payoff:'完成反转'}},
  {info_id:'actionable',capture_refs:['ref-2'],title:'工资被扣',material_score:9,verdict:'write',story_value_signals:{immediate_stakes:'三百名工人当天拿不到工资，女会计也会被当成替罪羊',protagonist_action:'女会计复制工资表并在复工直播中公开老板截留记录',escalation_path:'老板先冻结她的账号，再逼工人签自愿延期，最后让她承担煽动停工的责任',credible_payoff:'监管调取账本后责令补发工资，老板当众失去项目控制权'}},
]}, capture);
if (payload.info_source_cards.length !== 1 || payload.info_source_cards[0].info_id !== 'actionable') throw new Error(JSON.stringify(payload));
if (payload.rejected_summary.discarded !== 1) throw new Error(JSON.stringify(payload.rejected_summary));
const assessment = assessInfoSourcePool(payload.info_source_cards);
if (assessment.write_count !== 1 || assessment.status !== 'partial') throw new Error(JSON.stringify(assessment));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "info source pool distinguishes partial value from a zero-value retry loop" {
    run node - "$REPO/scripts/short-info-source-finalize.js" <<'NODE'
const { assessInfoSourcePool } = require(process.argv[2]);
const partial = assessInfoSourcePool([{ verdict: 'write', story_value_valid: true }]);
const empty = assessInfoSourcePool([{ verdict: 'discard', story_value_valid: false }]);
if (partial.status !== 'partial' || partial.visible_count !== 1) throw new Error(JSON.stringify(partial));
if (empty.status !== 'insufficient' || empty.visible_count !== 0) throw new Error(JSON.stringify(empty));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "info source normalization keeps only the strongest eight compact cards" {
    run node - "$REPO/scripts/short-info-source-finalize.js" <<'NODE'
const { normalizeCandidatePayload } = require(process.argv[2]);
const source_items = Array.from({ length: 12 }, (_, index) => ({
  capture_item_id: `ref-${index + 1}`, source_id: `source-${index + 1}`,
  source_name: `来源${index + 1}`, title: `热点${index + 1}`,
  url: `https://example.com/${index + 1}`, observed_at: '2026-07-28',
  heat_signal: 'public_hotlist_rank', heat_value: String(index + 1),
}));
const hot_topics = source_items.map((item, index) => ({
  hot_topic_id: `hot-${index + 1}`, title: item.title, capture_refs: [item.capture_item_id],
  summary: `事实${index + 1}`, character_conflict: `冲突${index + 1}`,
  material_score: index + 1, judgment: index + 1 >= 8 ? 'write' : 'backup',
  route_fit: ['番茄'], angle_candidates: [`主角行动${index + 1}`],
  story_value_signals: {
    immediate_stakes: `主角当天会失去工作和第${index + 1}笔工资`,
    protagonist_action: `主角保存第${index + 1}份证据并公开追责`,
    escalation_path: `对方先删记录，再冻结账号，最后逼主角承担第${index + 1}次损失`,
    credible_payoff: `监管核验第${index + 1}份证据后责令退款并公开责任人`,
  },
}));
const payload = normalizeCandidatePayload({ hot_topics, info_cards: hot_topics }, { source_items });
if (payload.info_source_cards.length !== 7) throw new Error(JSON.stringify(payload));
if (payload.info_source_cards[0].scorecard.material_score !== 12) throw new Error(JSON.stringify(payload.info_source_cards));
if (payload.info_source_cards.at(-1).scorecard.material_score !== 6) throw new Error(JSON.stringify(payload.info_source_cards));
if (payload.rejected_summary.discarded !== 5) throw new Error(JSON.stringify(payload.rejected_summary));
if ('hot_topics' in payload || 'info_cards' in payload) throw new Error(JSON.stringify(Object.keys(payload)));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "story card contract keeps brainstorm generation compact and supports compact value scores" {
    run python3 - "$PIPELINE" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("card_pipeline", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
contract = module.story_contract()
shape = contract["candidate_shape"]
if shape["topic_cards"]["count"] != "3-5 total":
    raise SystemExit(json.dumps(contract, ensure_ascii=False))
for field in ("core_payoff", "target_reader", "risk_notes", "opening_advice"):
    if field not in shape["topic_cards"]["required_fields"]:
        raise SystemExit(json.dumps(contract, ensure_ascii=False))
if shape["material_cards"]["count"] != "one per selected info card":
    raise SystemExit(json.dumps(contract, ensure_ascii=False))
scorecard = {field: 8 for field in module.VALUE_SCORE_FIELDS}
scorecard["writing_difficulty"] = 4
card = {
    "value_scorecard": scorecard,
    "value_reason": "冲突可视、主角能行动，终局有现实兑现",
    "value_verdict": "primary",
    "payoff_mechanism": "公开纠错",
    "conflict_domain": "职场与隐私",
    "relationship_engine": "前任与旧同事",
    "reversal_mechanism": "证据反转",
}
errors = module.topic_value_contract_errors(card, "topic-1")
if errors:
    raise SystemExit(json.dumps(errors, ensure_ascii=False))
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "hot source discovery plan is platform-first and does not seed fiction tropes" {
    run node "$DISCOVERY_PLAN" \
        --profiles "$PRIVATE_SKILL/references/hot-source-profiles.json" \
        --window-days 7 \
        --as-of 2026-07-26 \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"hot_source_discovery_plan_ready"'* ]]
    [[ "$output" == *'"source_id":"baidu_realtime"'* ]]
    [[ "$output" == *'"source_id":"tencent_news"'* ]]
    [[ "$output" == *'"source_id":"sina_news_ent"'* ]]
    [[ "$output" == *'"source_id":"netease_news"'* ]]
    [[ "$output" == *'"source_id":"douyin_hot"'* ]]
    [[ "$output" == *'"source_id":"toutiao_hot"'* ]]
    [[ "$output" == *'"source_id":"weibo_hot"'* ]]
    [[ "$output" == *'"source_id":"zhihu_hot"'* ]]
    [[ "$output" == *'"source_id":"bilibili_popular"'* ]]
    [[ "$output" == *'"source_id":"kuaishou_hot"'* ]]
    [[ "$output" == *'"source_id":"xiaohongshu_explore"'* ]]
    [[ "$output" == *'"source_id":"ifeng_news"'* ]]
    [[ "$output" == *'"source_id":"hupu_hot"'* ]]
    [[ "$output" == *'"source_id":"thepaper_hot"'* ]]
    [[ "$output" == *'"source_id":"qihoo_hot"'* ]]
    [[ "$output" == *'"source_id":"cover_news"'* ]]
    [[ "$output" == *'"source_id":"jimu_news"'* ]]
    [[ "$output" == *'"maximum_selected_sources":12'* ]]
    [[ "$output" == *'"unselected_sources_require_status":false'* ]]
    [[ "$output" == *'"selected_expansion_groups"'* ]]
    [[ "$output" == *'"reserve_sources"'* ]]
    [[ "$output" == *'"discovery_mode":"source_first_no_genre_filter"'* ]]
    [[ "$output" != *'彩礼'* ]]
    [[ "$output" != *'断亲'* ]]
    [[ "$output" != *'打脸'* ]]
    [[ "$output" != *'反杀'* ]]
}

@test "deployed project runtime discovers private hot source profiles from host skill" {
    runtime="$TMPDIR/story-trend-runtime-$$"
    mkdir -p "$runtime/scripts"
    cp "$DISCOVERY_PLAN" "$runtime/scripts/hot-source-discovery-plan.js"
    cp -R "$REPO/scripts/lib" "$runtime/scripts/lib"

    run env NOVEL_ASSISTANT_SKILL_DIR="$REPO/skills/novel-assistant" \
        node "$runtime/scripts/hot-source-discovery-plan.js" \
        --window-days 7 \
        --as-of 2026-07-26 \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"hot_source_discovery_plan_ready"'* ]]
    [[ "$output" == *'"source_id":"baidu_realtime"'* ]]
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
    grep -q "structured_provider" "$SEARCH"
    grep -q "WebSearch.*不能.*当前热点" "$SEARCH"
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
    grep -q '360 热榜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '澎湃新闻热榜' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '界面新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '新京报' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '封面新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '九派新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '极目新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '上游新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q '扬子晚报与紫牛新闻' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'balanced_fixed_budget' "$PRIVATE_SKILL/references/hot-source-profiles.json"
    grep -q 'max_sources_per_round' "$PRIVATE_SKILL/references/hot-source-profiles.json"
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
      "emotion_trigger": "羞辱到反击",
      "protagonist_seed": "被母亲公开标价的女儿",
      "immediate_stakes": "不反击就会被当场安排婚事并失去工作选择",
      "actionable_choice": "当众撕掉母亲准备的相亲简历并接过话筒",
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
      "emotional_entry": "公开羞辱",
      "power_relation": "控制型母亲对成年女儿",
      "oppressor": "母亲和围观亲戚",
      "protagonist_action": "女儿夺过话筒公开自己的真实条件",
      "escalation_trigger": "母亲当众接受对方压价并准备收定金",
      "counterattack_method": "公开证据反证并夺回婚恋决定权",
      "reversal_method": "被标价者反向审问标价者隐瞒的债务",
      "payoff_shape": "公开打脸并夺回选择权",
      "reusable_scene": "相亲角黑板前夺过话筒",
      "platform_fit": ["番茄短篇"]
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
      "title_candidates": ["我妈在相亲角给我标价28万"],
      "opening_scene": "母亲在相亲角黑板上写下女儿身价并收下男方定金",
      "story_promise": "女儿如何在公开羞辱中夺回自己的人生定价权",
      "protagonist_pressure": "母亲用亲情和债务逼她接受婚事",
      "antagonist_pressure": "男方家庭压价，亲戚围观起哄",
      "irreversible_choice": "女儿当众撕毁婚约并公开母亲隐瞒的债务",
      "escalation_beats": ["男方压价", "母亲收定金", "亲戚曝光女儿工作隐私"],
      "first_reversal": "女儿拿出转账记录证明所谓彩礼其实在替母亲还债",
      "final_payoff": "女儿公开证据终止婚约，追回被挪用的钱并搬离家庭控制",
      "expected_length": "8000-10000字"
    }
  ]
}
JSON
    run python3 "$PIPELINE" validate "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"ok"'* ]]
}

@test "card pipeline rejects commentary cards without executable plot" {
    tmp="${TMPDIR:-/tmp}/cards-commentary-bad-$$.json"
    cat > "$tmp" <<'JSON'
{
  "info_source_cards": [],
  "material_cards": [
    {
      "card_type": "material_card",
      "canonical_id": "mat_observe",
      "source_type": "local",
      "title": "制度善意与结构性无力",
      "event_summary": "两个社会议题的对照。",
      "human_conflict": "制度与个体的错位",
      "emotion_trigger": "焦虑到自省",
      "extractable_hotspots": ["hot_observe"]
    }
  ],
  "hotspot_cards": [
    {
      "card_type": "hotspot_card",
      "hotspot_id": "hot_observe",
      "source_material_ids": ["mat_observe"],
      "hotspot_line": "制度的善意来得太慢",
      "reader_desire": "看见结构",
      "counterattack_method": "无——这是观察型爽感",
      "payoff_shape": "自省"
    }
  ],
  "topic_cards": [
    {
      "card_type": "topic_card",
      "topic_id": "top_observe",
      "primary_hotspot_id": "hot_observe",
      "hotspot_ids": ["hot_observe"],
      "target_platform": "番茄短篇",
      "title_candidates": ["仰望后自省"],
      "genre_lane": "现代观察",
      "first_reversal": "主角意识到结构存在",
      "final_payoff": "主角在日记里写下自己的自省"
    }
  ]
}

JSON
    run python3 "$PIPELINE" validate "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"passive_hotspot_without_protagonist_action"* ]]
    [[ "$output" == *"insufficient_plot_escalation"* ]]
    [[ "$output" == *"commentary_payoff_not_story_payoff"* ]]
}

@test "workspace card quality gate blocks weak cards with one deterministic command" {
    workspace="${TMPDIR:-/tmp}/story-card-workspace-$$"
    cards="$workspace/追踪/private-short-extension/cards"
    mkdir -p "$cards"
    printf '%s\n' '{"card_type":"material_card","canonical_id":"mat_weak","source_type":"local","title":"结构观察","event_summary":"议题对照","human_conflict":"制度错位","emotion_trigger":"自省","extractable_hotspots":["hot_weak"]}' > "$cards/material-cards.jsonl"
    printf '%s\n' '{"card_type":"hotspot_card","hotspot_id":"hot_weak","source_material_ids":["mat_weak"],"hotspot_line":"制度来得太慢","reader_desire":"看见结构","counterattack_method":"无——观察型爽感","payoff_shape":"自省"}' > "$cards/hotspot-cards.jsonl"
    printf '%s\n' '{"card_type":"topic_card","topic_id":"top_weak","primary_hotspot_id":"hot_weak","hotspot_ids":["hot_weak"],"target_platform":"番茄短篇","title_candidates":["仰望后自省"],"genre_lane":"现代观察","first_reversal":"意识到结构","final_payoff":"日记里写下自省"}' > "$cards/topic-cards.jsonl"

    run python3 "$PIPELINE" validate-workspace --workspace "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *'"status":"blocked_card_story_engine"'* ]]
    [[ "$output" == *'"recovery":"只修订未通过的素材卡/爆点卡/选题卡'* ]]
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
    test -f "$BUNDLE_PRIVATE/references/hot-source-providers.json"
    test -f "$BUNDLE_PRIVATE/scripts/card_pipeline.py"
    test -f "$BUNDLE_PRIVATE/scripts/hot_source_capture.js"
    grep -q "素材卡 -> 爆点卡 -> 选题卡" "$BUNDLE_PRIVATE/references/card-composition-system.md"
    grep -q "validate-fresh" "$BUNDLE_PRIVATE/references/search-strategy.md"
    grep -q "网易新闻" "$BUNDLE_PRIVATE/references/hot-source-profiles.json"
}
