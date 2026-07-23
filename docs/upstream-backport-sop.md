# 上游反哺半自动流程

本流程用于定期检查 `worldwonderer/oh-story-claudecode` 上游更新，并判断哪些内容值得反哺到本项目。

核心原则：脚本只负责取数、对比、留痕；是否吸收由人工判断，避免把上游旧结构、旧 release 文档或不适合本项目的设计误合进来。

## 1. 生成对比报告

```bash
bash scripts/check-upstream.sh --write
```

默认检查：

- 上游仓库：`https://github.com/worldwonderer/oh-story-claudecode.git`
- 上游分支：`main`
- 报告目录：`reports/upstream/`

指定其他上游：

```bash
bash scripts/check-upstream.sh \
  --repo https://github.com/worldwonderer/oh-story-claudecode.git \
  --branch main \
  --write
```

脚本会 fetch 到 `refs/remotes/upstream-check/main`，不会 merge、cherry-pick、push，也不会创建本地 tag。

## 2. 阅读报告

重点看四块：

| 报告区块 | 用途 |
|---|---|
| Summary | 判断是否存在上游新提交、tag 缺失或 tag 漂移 |
| Upstream-Only Commits | 上游有、本地没有的提交 |
| Upstream Changed Files Since Merge Base | 上游新提交影响了哪些文件 |
| Novel Assistant Backport Target Mapping | 上游文件应反哺到 `novel-assistant` 内部模块的目标路径 |
| Tag Comparison | 上游 tag 是否完整、本地是否缺 tag 或同名 tag 指向不同 |

如果 `Upstream-only commits = 0` 且 tag 无缺失/漂移，则本轮无需反哺。

## 3. 人工三分类

对每个 upstream-only commit 做三分类：

| 分类 | 标准 | 操作 |
|---|---|---|
| absorb | 修复生产问题、提升稳定性、兼容性、安全性，且不冲突本项目路线 | 小批量手工反哺 |
| already-covered | 本项目已有等价或更强实现 | 在报告备注原因，不改代码 |
| skip | 只改上游 release、社群、旧安装结构，或与本项目单包策略冲突 | 在报告备注原因，不改代码 |

本项目优先级：

1. 长篇写作稳定性、100+ 章不跑题、回炉可控。
2. 去 AI 味、正文洁净、标点/格式确定性修复。
3. Codex / Claude Code / OpenClaw 兼容。
4. `oh-story` 单目录安装包不被破坏。

## 4. 反哺执行规则

- 一次只吸收一个主题，不做大杂烩。
- 不直接 merge 上游 `main`。
- 优先 cherry-pick 思想和小补丁，必要时手工移植。
- 上游 `skills/story-*`、`skills/story`、`skills/browser-cdp` 的变化，先看报告里的 `Novel Assistant Backport Target Mapping`。它会给出 `src/internal-skills/...` canonical source target 和 `skills/novel-assistant/references/internal-skills/...` generated install target。
- 当前源码布局下，`src/internal-skills/story-*` 是 canonical source；直接改 `skills/novel-assistant/references/internal-skills/...` 会在下次 `build-oh-story-bundle.sh` 时被覆盖。反哺应改 `Current canonical source target`，再运行 bundle 构建。
- 每次吸收都必须保留版本证据链：报告头部记录 `Upstream HEAD`、`Merge base`、本地 HEAD；报告尾部填写每个 upstream-only commit 的 `absorb / already-covered / skip` 决策。
- 每次吸收都必须在 `README.md` 的「上游反哺记录」追加一行，记录日期、上游 HEAD、报告文件、本地分支/提交、吸收主题和跳过原因。
- 所有子 skill 源码改完后，运行：

```bash
bash scripts/build-oh-story-bundle.sh
```

保证 `skills/novel-assistant/` 单包同步。

## 5. 验证命令

反哺后至少运行：

```bash
bash scripts/run-bats-tests.sh
bash scripts/static-check.sh
git diff --check
```

如果涉及共享 references/scripts，还要运行：

```bash
bash scripts/check-shared-files.sh
```

## 6. 提交与记录

推荐提交格式：

```bash
git commit -m "feat(scope): backport upstream <topic>"
```

报告文件保留在 `reports/upstream/`，并随反哺代码一起提交。报告不是临时日志，而是之后判断“这个上游版本是否已经吸收”的审计凭证。

每次提交前检查：

- `reports/upstream/YYYYMMDD-*-upstream-check.md` 已填写 triage 表，不保留 TODO。
- `README.md` 已追加「上游反哺记录」行，能从 README 快速定位对应 report。
- commit message 说明本次吸收主题，例如 `feat(upstream): backport narrative quality gates`。

## 7. tag 处理

`scripts/check-upstream.sh` 只报告 tag 差异，不自动创建 tag。

tag 处理策略：

- 上游 release tag 如果对应提交已完整进入本项目，可考虑补 tag。
- 如果本项目在上游基础上有自研提交，不建议复用上游 tag 指向本地不同提交。
- 同名 tag 指向不同提交属于高风险，必须人工确认，不允许脚本自动覆盖。
