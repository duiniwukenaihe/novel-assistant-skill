# Panlong Benchmark

This benchmark compares the current `novel-assistant` long-form deconstruction workflow against the existing Panlong demo baseline.

It is intentionally separated from normal tests because it uses Claude Code and may be long-running.

## Baseline

Baseline output:

```text
demo/拆文库-盘龙
```

Input source:

```text
demo/拆文库-盘龙/原文/原文.txt
```

The baseline contains 23 chapter summaries, golden-three deep analysis, report, style, character, plot, and setting artifacts.

The old demo uses `设定/世界观/力量体系.md`. Current `novel-assistant` may output the newer neutral artifact name `设定/世界观/能力与规则.md`; the benchmark treats these as equivalent because the project deliberately avoids forcing every genre into a "power system" label.

## Candidate Output

Each new run writes to:

```text
benchmarks/panlong/novel-assistant-YYYYMMDD-HHMMSS/
```

Do not overwrite the baseline demo. Do not write candidate outputs directly under `demo/`.

## Claude Code Run

Run from a clean temporary benchmark workspace or a dedicated benchmark directory:

```text
/novel-assistant 完整拆解 demo/拆文库-盘龙/原文/原文.txt，输出到 benchmarks/panlong/novel-assistant-YYYYMMDD-HHMMSS/
```

The run should use `novel-assistant`, not internal `/story-long-analyze`.

Record:

- model/provider
- start time and end time
- whether recap occurred
- whether API retry occurred
- whether the workflow asked for manual continuation
- final checkpoint and progress files

## Comparison Checklist

After the Claude Code run finishes, run the structural comparison:

```bash
node scripts/na-dev.js panlong --candidate benchmarks/panlong/novel-assistant-YYYYMMDD-HHMMSS --json
```

This does not judge prose taste by itself; it checks the baseline structural contract first so obvious regressions are caught before manual reading.

### Chapter coverage

Expected:

- 23 chapter summaries
- golden-three deep analysis for chapters 1-3
- no missing chapter files
- no extra hallucinated chapters

### Source grounding

Expected:

- key entities trace back to `demo/拆文库-盘龙/原文/原文.txt`
- quoted details appear in the source chapter slice
- no mixed content from another novel
- no unsupported character, faction, place, or ability

### Artifact completeness

Expected artifact groups:

- overview
- deconstruction report
- style report
- chapter summaries
- characters
- plot lines
- rhythm/emotion modules
- setting/world rules
- factions

For world rules, either `设定/世界观/力量体系.md` or `设定/世界观/能力与规则.md` is acceptable. The latter is preferred for new outputs unless the source work itself strongly calls for a more specific title.

For this Panlong benchmark, standalone role files are expected for emotionally or structurally critical characters: `林雷`, `霍格`, `沃顿`, `希尔曼`, `希里`, and `德林柯沃特`（full-name variants such as `林雷·巴鲁克.md` are accepted）. Missing `沃顿` or `希里` is a regression because they carry the brotherhood sacrifice chain, guardian function, and gold-finger activation context.

### Author absorption quality

The candidate output should explain:

- reader desire
- technique mechanism
- transferable skeleton
- local reinterpretation
- anti-copy notes

It should not mechanically copy plot, names, dialogue, or proprietary scene construction.

### Runtime behavior

Runtime behavior is part of the benchmark:

- Did it ask for repeated manual continuation?
- Did it stall after a batch?
- Did it recover from recap?
- Did it write polluted output?
- Did it create usable checkpoint files?
- Did it finish without requiring the user to supervise every few minutes?

### Cost/time notes

Record:

- elapsed time
- approximate number of user turns
- approximate number of agent/tool batches
- interruption count
- retry count
- final status

## Result Summary Template

```markdown
# Panlong Benchmark Result

Run: benchmarks/panlong/novel-assistant-YYYYMMDD-HHMMSS/
Model:
Started:
Finished:
Status:

| Dimension | Baseline | Candidate | Verdict |
|---|---|---|---|
| Chapter coverage | 23 summaries + golden three |  |  |
| Source grounding | Existing demo |  |  |
| Artifact completeness | Existing demo |  |  |
| Author absorption quality | Existing demo |  |  |
| Runtime behavior | Existing demo was static baseline |  |  |
| Cost/time | n/a |  |  |

## Notes

- Strengths:
- Regressions:
- Follow-up fixes:
```

## When To Run

Run this benchmark after:

- major `story-long-analyze` changes
- workflow runtime guard changes
- output health gate changes
- large upstream deconstruction backports
- script/path restructuring that could affect long analyze

Do not run it as part of ordinary fast CI.
