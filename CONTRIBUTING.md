# 贡献指南

感谢你对网文写作 skill 包的关注，欢迎贡献。

## 仓库结构

当前源码仓库名以 `novel-assistant-skill` 为准；`oh-story-claudecode` 只作为上游仓库名或历史命名出现。维护脚本、文档示例和本地操作不要把旧名当作默认工作目录，避免在已重命名仓库中误用失效路径。

维护硬约束：

- 真实开发仓库以 `<local-user-path>/data/skill/novel-assistant-skill` 为准；旧路径或旧仓库名只用于上游对比、历史说明或兼容脚本，不作为当前工作目录。
- 本地/GitLab 自用安装包含 private internal skills。短篇写作、短篇素材卡、短篇正文、短篇回炉和短篇去 AI 味必须先检查 `private-short-extension/workflow-registry.json`；若 `short_write` owner 为 `private-short-extension`，本地运行必须走 private `private-short-extension`，公开 `story-short-write` 只作为被吸收的方法包和 GitHub fallback。
- GitHub public release 必须剥离 `src/private-internal-skills/` 与 `skills/novel-assistant/references/private-internal-skills/`。公开版没有 private registry 时，才由 public `story-short-write` 接管短篇。

```
skills/
├── story/                   # 工具箱路由
├── story-setup/             # 环境部署
├── story-import/            # 逆向导入
├── story-long-write/        # 长篇写作
├── story-long-analyze/      # 长篇拆文
├── story-long-scan/         # 长篇扫榜
├── story-short-write/       # 短篇写作
├── story-short-analyze/     # 短篇拆文
├── story-short-scan/        # 短篇扫榜
├── story-deslop/            # 去AI味
├── story-review/            # 多视角审查
├── story-cover/             # 封面生成
└── browser-cdp/             # 浏览器操控
scripts/                     # 开发守卫 / 测试 / 代码生成 / 上游反哺脚本
```

每个 skill 由一个 `SKILL.md`（入口）和 `references/` 目录（知识库）组成。`scripts/` 的完整索引见 [scripts/README.md](scripts/README.md)；运行时脚本以各 skill 自己的 `scripts/` 为准，根目录 `scripts/` 主要服务 CI、维护者和构建同步。

## Skill 格式

`SKILL.md` 开头必须有 frontmatter：

```yaml
---
name: skill-name
description: |
  一句话描述。
  触发方式：/skill-name、触发词1、触发词2
---
```

`references/` 中的文件由 skill 按需加载，不会全部塞进上下文。

## 如何贡献

### 改进现有 skill

1. Fork 仓库
2. 从 `main` 创建分支：`git checkout -b feat/your-feature main`
3. 修改对应的 `SKILL.md` 或 `references/` 文件
4. 提交 PR，说明改了什么、为什么改

### 新增 skill

1. 在 `skills/` 下创建目录，包含 `SKILL.md` 和 `references/`
2. 确保在仓库根目录运行 `npx skills validate` 无报错
3. 提交 PR

## CI 检查

PR 自动运行 `.github/workflows/cross-platform.yml`。CI 以 workflow 为准，下面是提交前最常用的本地检查：

- `scripts/static-check.sh` — frontmatter、引用路径、死文件、references 交叉引用
- `scripts/check-hook-regex-sync.sh` — hook 伏笔状态检测行为
- `scripts/check-shared-files.sh` — 跨 skill 同名副本字节一致性
- `scripts/check-story-setup-deployment.sh` — story-setup 部署完整性
- `scripts/run-bats-tests.sh` — bats 测试；本机无 bats 时自动回退 lite runner

另有 windows / macos job 验证 cdp-utils 加载与 setup 脚本 dry-run。

提交前建议本地全部跑一遍：

```bash
bash scripts/static-check.sh
bash scripts/check-hook-regex-sync.sh
bash scripts/check-shared-files.sh
bash scripts/check-story-setup-deployment.sh
bash scripts/run-bats-tests.sh
```

更多脚本分组、运行时边界和上游反哺入口见 [scripts/README.md](scripts/README.md)。

## 共享文件规范

部分文件跨 skill 共享（如 banned-words.md、anti-ai-writing.md），修改时必须同步所有副本。
运行 `bash scripts/check-shared-files.sh` 检查一致性。

### 知识库贡献

最有价值的贡献类型：

- **实战数据**：各平台最新榜单分析、题材趋势变化
- **新题材框架**：新的题材写作公式、结构模板
- **去AI味规则**：新的 AI 痕迹模式、改写范例
- **平台规则更新**：投稿要求、推荐机制的变化

## 质量要求

- **操作性**：内容必须能让 AI agent 直接执行，不要写教程
- **简洁**：用表格和模板，不要长篇叙述
- **无冗余**：不同 skill 的 `references/` 之间可以共享文件（通过路径引用），但同一 skill 内不要重复
- **中文**：所有内容用中文

## 提交流程

```
fork → branch → commit → PR → review → merge
```

- 一个 PR 聚焦一个改动
- commit message 用中文，格式：`类型: 简短描述`
- 类型：`feat`（新增）/ `fix`（修复）/ `docs`（文档）/ `refactor`（重构）
