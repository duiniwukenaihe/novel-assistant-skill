# 发布前检查清单

发布前按顺序执行以下检查。所有命令都在仓库根目录运行。

## 必跑验证

```bash
bash scripts/run-bats-tests.sh
bash scripts/check-story-setup-deployment.sh
bash scripts/check-shared-files.sh
bash scripts/static-check.sh
bash scripts/check-python-invocation.sh
bash scripts/check-hook-regex-sync.sh
bash scripts/test-charcount-portable.sh --stub
git diff --check
```

GitHub 净化分支不包含本地扩展和维护者资产，因此其 CI 不运行依赖这些资产的内部测试。公开分支使用：

```bash
bash scripts/run-public-release-tests.sh
```

该矩阵会先执行公开隐私审计、维护性审计和生产 smoke，再运行公开 Workflow、Memory、短篇逐节、状态恢复与宿主边界的聚焦 Bats。GitLab `main` 仍以 `run-bats-tests.sh` 承担完整内部回归；两套矩阵用途不同，公开矩阵不得通过要求私有文件存在来“验证”隐私隔离。

## 行为验收门禁

发布候选必须有当前 bundle 的真实宿主行为证据。门禁只读取报告，不自动启动 Claude/Codex/ZCode：

```bash
node scripts/behavior-eval-release-gate.js --json
node scripts/release-status.js --json
```

需要补报告时，先生成 dry-run 计划，再显式确认 paid run：

```bash
node scripts/na-dev.js behavior-eval-plan --scenario route-single-entry --hosts claude,codex,zcode --json
RUN_ID=paid-route-single-entry-001
node scripts/na-dev.js behavior-eval-run --execute-paid --paid-confirmation "$RUN_ID" --max-budget-usd 10 --scenario route-single-entry --hosts claude,codex,zcode --run-id "$RUN_ID" --json
```

必须覆盖六类场景：单入口路由、只写指定节、审阅范围恢复、退化早停、阶段修复门、章节提交冲突。任一场景缺失、非 paid、bundle 过期、host usage/cost 不是宿主实测，均不能发布。

## 结果判定

- `run-bats-tests.sh` 必须全部通过。
- `check-story-setup-deployment.sh` 必须通过，确保 `/novel-assistant 准备写书` 部署包完整。
- `check-shared-files.sh` 必须显示 `Mismatches: 0`。
- `static-check.sh` 必须 `Fail: 0`；历史 warning 可保留，但不能新增破坏性错误。
- `behavior-eval-release-gate.js` 必须 `status=pass`，除非本次明确不是发布候选。
- `git diff --check` 必须无输出。

## 长篇稳定性抽查

至少确认以下脚本有测试覆盖并能在 fixture 上运行：

```bash
bash scripts/chapter-index-build.sh tests/fixtures/longform-stability-mini
bash scripts/chapter-stability-check.sh tests/fixtures/longform-stability-mini 001
bash scripts/longform-daily-stability-audit.sh --write tests/fixtures/longform-stability-mini 001 002
bash scripts/stability-repair-loop.sh --write tests/fixtures/longform-stability-mini 001 002
bash scripts/stability-agent-dispatch-prompt.sh --json tests/fixtures/longform-stability-mini 001 002
```

## 发布说明建议

发布说明至少覆盖：

- 长篇稳定性闭环：`Chapter Contract -> Plot Drift Gate -> State Delta -> Handoff -> Daily Audit`
- 回炉复检：`revision-stability-recheck.sh`
- agent 分派：`current_owner`、`current_action`、`agent_call`
- 长篇索引：`追踪/章节索引.tsv`
- 已跑验证命令和结果
