# 参考项目观察报告

- Checked at: `2026-07-15T13:32:29.021Z`
- Registry: `docs/reference-projects.json`
- 主上游仍优先: `worldwonderer/oh-story-claudecode`
- 主上游命令: `node scripts/na-dev.js upstream --write`
- 参考项目命令: `node scripts/na-dev.js reference-watch --write`

## Summary

- total: 15
- changed: 4
- current: 11
- untracked: 0
- error: 0
- manual knowledge sources: 5
- data sources: 4
- excluded/special sources: 3

## Policy

- `worldwonderer/oh-story-claudecode` 是主上游，仍按 `reports/upstream/` 和上游反哺 SOP 高频跟踪。
- 本报告覆盖参考 GitHub 项目、手工知识来源、数据来源和排除/特殊来源，输出到 `reports/research/`，用于低频观察和设计候选。
- 参考项目默认不 merge、不 cherry-pick、不复制代码；GPL/AGPL/未知许可项目只做 clean-room 设计吸收。

## Projects

| Status | Project | Branch | Head | Head status | Latest tag | Tag status | Last reviewed | Last observed | Priority | License | Absorb mode | Recommended action | Focus |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `current` | lingfengQAQ/webnovel-writer | `master` | `59654ccaa17f` | `current` | v6.2.1 | `current` | `59654ccaa17f` | `59654ccaa17f` | `reference-high` | `GPL-3.0` | `clean-room-design-only` | `no_action` | chapter_commit, story_system, projection_replay, author_report, long_term_memory |
| `current` | ExplosiveCoderflome/AI-Novel-Writing-Assistant | `main` | `7785b0569bb0` | `current` | v0.4.2 | `current` | `-` | `7785b0569bb0` | `reference-medium` | `unknown-check-before-use` | `design-triage-only` | `no_action` | auto_director, quality_debt, character_resource_ledger, style_engine |
| `current` | op7418/humanizer-zh | `main` | `91f3d394db84` | `current` | - | `none` | `-` | `91f3d394db84` | `reference-low` | `unknown-check-before-use` | `ideas-and-tests-only` | `no_action` | anti_ai_diagnosis, humanized_prose_metrics, style_rewrite_checks |
| `changed` | wen1701/FanqieRankTracker | `main` | `e045fe7715de` | `changed` | - | `none` | `-` | `0f0bad08cb15` | `reference-high` | `MIT-confirmed-in-private-download-docs` | `compatible-implementation-review` | `triage_for_possible_backport` | fanqie_font_decode, ranking_scrape, book_id_extraction, anti_scraping_boundary |
| `current` | SillyTavern/SillyTavern | `release` | `8172dcd0ee67` | `current` | 1.18.0 | `current` | `-` | `8172dcd0ee67` | `reference-medium` | `unknown-check-before-use` | `clean-room-design-only` | `no_action` | lorebook, dynamic_context, prompt_ordering, memory_activation, context_budget |
| `current` | penglonghuang/chinese-novelist-skill | `main` | `eb1185649437` | `current` | v1.0 | `current` | `-` | `eb1185649437` | `reference-low` | `unknown-check-before-use` | `prompt-pattern-review` | `no_action` | chinese_writing_flow, skill_packaging |
| `current` | junaid18183/novel-architect-skills | `main` | `8c1a48b64f60` | `current` | - | `none` | `-` | `8c1a48b64f60` | `reference-low` | `unknown-check-before-use` | `prompt-pattern-review` | `no_action` | novel_architecture, outline_design, character_design |
| `current` | wordflowlab/novel-writer-skills | `main` | `5bc9b373ff60` | `current` | v1.0.3 | `current` | `-` | `5bc9b373ff60` | `reference-low` | `unknown-check-before-use` | `prompt-pattern-review` | `no_action` | writing_skills, workflow_steps |
| `changed` | yangsonhung/awesome-agent-skills | `main` | `4218665667b6` | `changed` | - | `none` | `-` | `0b9631548f26` | `reference-low` | `curated-links-check-target-license` | `discovery-index-only` | `research_report_then_clean_room_triage` | skill_discovery, agent_skill_patterns |
| `current` | aradotso/trending-skills | `main` | `2384a003145a` | `current` | - | `none` | `-` | `2384a003145a` | `reference-low` | `curated-links-check-target-license` | `discovery-index-only` | `no_action` | skill_discovery, trend_monitoring |
| `current` | leenbj/novel-creator-skill | `main` | `a327428ea269` | `current` | - | `none` | `-` | `a327428ea269` | `reference-low` | `unknown-check-before-use` | `prompt-pattern-review` | `no_action` | novel_creation_flow, skill_packaging |
| `changed` | EdwardAThomson/NovelWriter | `main` | `aa893e1c29fd` | `changed` | - | `none` | `-` | `7596f9f2e923` | `reference-medium` | `unknown-check-before-use` | `clean-room-design-only` | `research_report_then_clean_room_triage` | scene_chapter_batch_review, quality_trend |
| `current` | ARMANDSnow/make-ur-Agent-writer | `main` | `25ea285fbf62` | `current` | aeloon-handoff-iter057 | `untracked` | `-` | `25ea285fbf62` | `reference-high` | `unknown-check-before-use` | `clean-room-design-only` | `no_action` | mock_first, fail_closed_review, cost_budget, detached_resume |
| `changed` | Narcooo/inkos | `master` | `7dce95748575` | `changed` | v1.7.0 | `current` | `7ac8d5305571` | `7ac8d5305571` | `reference-high` | `AGPL-3.0` | `clean-room-design-only` | `light_commit_log_only_until_tag_changes` | audit_dimensions, bounded_revision, snapshot_lock, structured_delta |
| `current` | iLearn-Lab/NovelClaw | `main` | `226d50d3ec28` | `current` | - | `none` | `-` | `226d50d3ec28` | `reference-medium` | `MIT` | `clean-room-design-only` | `no_action` | dynamic_memory, longform_continuity |

## Manual Knowledge Sources

| Source | Type | Watch mode | Priority | Absorb mode | Focus | Notes / Reason |
|---|---|---|---|---|---|---|
| GitHub Spec Kit Fiction preset discussion | `conceptual` | `manual` | `reference-medium` | `design-pattern-only` | pre_draft_analysis, post_draft_continuity, surgical_revision | https://github.com/github/spec-kit/discussions/2211 / 只手工转译写前分析、写后连续性和小范围修订的职责分离；不把讨论内容作为可 merge 的项目或 prompt 模板。 |
| Trellis task persistence pattern | `conceptual` | `manual` | `reference-high` | `design-pattern-only` | spec_task_journal, durable_task_state, rpd, workflow_recovery | docs/superpowers/specs/2026-07-08-trellis-rpd-task-persistence-design.md / 本项目只吸收 spec/task/workspace journal 分层思想，不照搬 Trellis 目录或实现。 |
| SillyTavern World Info / Lorebook design notes | `conceptual` | `manual` | `reference-medium` | `design-pattern-only` | story_memory, lore_activation, prompt_order, context_injection | docs/superpowers/specs/2026-07-05-sillytavern-memory-context-design.md / 本项目只吸收动态记忆与上下文注入思想，不复制角色扮演 UI。 |
| 微信文章：短篇选题/卡片选择参考 | `article` | `manual` | `reference-medium` | `idea-summary-only` | shortform_topic_cards, card_selection, local_material_examples | https://mp.weixin.qq.com/s/OKb3oQLbIFiz3FRbR25rjQ / 用于短篇资讯池、脑洞卡、平台爆点卡的交互参考；不可依赖稳定抓取。 |
| Token 成本治理经验：Caveman / RTK 启发 | `conceptual` | `manual` | `reference-high` | `design-pattern-only` | tool_output_filtering, context_budget, model_routing, failure_retry_control | user-provided-design-principles / 用于 workflow 成本观测、工具输出聚合、异常浪费主动提醒。 |

## Data Sources

| Source | Type | Watch mode | Priority | Absorb mode | Focus | Notes / Reason |
|---|---|---|---|---|---|---|
| 网文大数据 · 番茄首秀 | `market-data` | `domain-script` | `reference-high` | `data-protocol-only` | fanqie_debut, category, word_count, read_count, read_growth, book_id | https://www.wangwendashuju.com/fq/debut / 由 story-short-scan 的 wangwen-debut-scraper.js 采集，必须标记 third-party，不得称为番茄官方榜单。 |
| 番茄官方 Web 排行榜 | `platform-data` | `domain-script` | `reference-high` | `data-protocol-only` | official_rank, category_catalog, rank_url_pattern, book_id | https://fanqienovel.com/rank / 由 fanqie-category-catalog.js 探测公开 Web rank 分类；适合长篇/常规榜单，不能等同 App 内短篇分类。 |
| 番茄官方 book info 校验接口 | `platform-data` | `domain-script` | `reference-high` | `data-protocol-only` | book_info_verify, book_id, author, category, word_count, read_count | https://fanqienovel.com/api/book/info / 由 scan-download-hints.js --enrich-fanqie 使用 bookId 做官方详情回填。 |
| 番茄 App 分类 JSON/HAR 导入 | `user-provided-data` | `manual-import` | `reference-medium` | `data-protocol-only` | app_category_tree, shortform_category, official_app_api_import | user-provided-app-api-json-or-har / 只有用户合法提供 App API JSON/HAR 时才能标记 official_app_api_import；否则不得假称完整 App 分类。 |

## Excluded / Special Sources

| Source | Type | Watch mode | Priority | Absorb mode | Focus | Notes / Reason |
|---|---|---|---|---|---|---|
| worldwonderer/oh-story-claudecode | `primary-upstream` | `upstream-sop` | `primary` | `design-only` |  | https://github.com/worldwonderer/oh-story-claudecode.git / 主上游不走 reference-watch，必须继续使用 node scripts/na-dev.js upstream --write。 |
| duiniwukenaihe/novel-assistant-skill | `release-target` | `release-sop` | `release` | `design-only` |  | https://github.com/duiniwukenaihe/novel-assistant-skill.git / 这是本项目公开发布目标，不是外部参考项目。 |
| 私有短篇/下载/本地素材资产 | `private-local` | `private-overlay-only` | `private` | `design-only` |  | local-private-overlay / private-short-extension、private-download-extension、private-short-extension 等私有资产不能进入公开 GitHub registry；只在本地私有 overlay 或 GitLab 私有分支跟踪。 |

## 下一步

1. 对 `changed` 且 priority 为 `reference-high` 的项目，先写 `reports/research/<date>-<project>-absorption.md`。
2. 如果 `recommendedAction=light_commit_log_only_until_tag_changes`，只读提交摘要和 README 级变更，不 clone 深读、不做大规模吸收，等 tag/release 变化后再 deep triage。
3. 报告必须写清：可吸收设计、拒绝项、许可边界、与 `novel-assistant` 的映射、是否需要测试。
4. 对 `knowledgeSources` 只做手工摘要和设计转译；对 `dataSources` 走对应专项脚本，不用 git HEAD 判断数据有效性。
5. 只有通过 clean-room 设计评审后，才进入本项目脚本/skill 实现；仍不得复制参考项目源码或长段 prompt。
6. 主上游更新不走本报告，继续用 `node scripts/na-dev.js upstream --write`。
