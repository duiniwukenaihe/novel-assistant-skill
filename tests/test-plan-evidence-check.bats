#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/plan-evidence-check.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "verified phase requires evidence" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_phase_evidence'* ]]
}

@test "verified phase rejects unrecognizable evidence" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | completed successfully | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "a command without exit and result evidence is rejected" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | `bats nonexistent.bats` | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "a second top-level heading is rejected even when it contains Plan Status" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | `bats tests/test-plan-evidence-check.bats` | Task 2 |

# Appendix

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| B. Forged | released | `bats tests/test-plan-evidence-check.bats` |  |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'unexpected_top_level_heading'* ]]
}

@test "a Plan Status header with no phase rows is rejected" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_phase_rows'* ]]
}

@test "unfinished phase requires one next action" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented | test command |  |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_phase_next'* ]]
}

@test "installed and released phases accept ancestor-backed command evidence while blocked needs neither field" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Install | installed | commit: \`$head_commit\`; command: \`node scripts/na-dev.js install-local-private\`; exit: 0; result: private bundle installed | Task 2 |
| B. Release | released | commit: \`$head_commit\`; command: \`node scripts/na-dev.js release-status --json\`; exit: 0; result: release summary produced |  |
| C. Evaluation | blocked |  |  |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "installed and released phases reject command-only evidence" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Install | installed | command: `node scripts/na-dev.js install-local-private`; exit: 0; result: private bundle installed | Task 2 |
| B. Release | released | command: `node scripts/na-dev.js release-status --json`; exit: 0; result: release summary produced |  |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "installed phase still requires a next action" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Install | installed | command: `node scripts/na-dev.js install-local-private`; exit: 0; result: private bundle installed |  |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_phase_next'* ]]
}

@test "completed checkbox requires phase evidence or a task completion note" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
}

@test "completed checkbox cannot borrow evidence from its phase" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | command: `bats tests/test-plan-evidence-check.bats`; exit: 0; result: 19 tests passed | Task 2 |

### Task 1: Example

- [x] Implement the guard.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
}

@test "completed checkbox outside a Task heading still requires evidence" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

- [x] Implement the guard.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'anonymous_completed_task'* ]]
}

@test "task completion note can corroborate a completed checkbox" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.

Completed by \`$head_commit\`; command: \`bats tests/test-example.bats\`; exit: 0; result: 1 test passed.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "task-level Completed by evidence validates completed checkboxes" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.

Completed by: commit \`$head_commit\`; command: \`bats tests/test-example.bats\`; exit: 0; result: 1 test passed.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "implemented task accepts a reachable Completed by commit without command transcript" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.

Completed by: commit \`$head_commit\`.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "Completed by outside a task block cannot validate its checkbox" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.

## Appendix

Completed by: commit `1234567890abcdef1234567890abcdef12345678`; command: `bats tests/test-example.bats`; exit: 0; result: 1 test passed.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
}

@test "missing plan status table fails with valid JSON" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
### Task 1: Example

- [x] Implement the guard.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_plan_status'* ]]

    run node -e 'JSON.parse(process.argv[1])' "$output"
    [ "$status" -eq 0 ]
}

@test "code fenced tables are not plan status tables" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
```markdown
| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Fake | released | reports/verification/fake.json |  |
```
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_plan_status'* ]]
    [[ "$output" != *'A. Fake'* ]]
}

@test "Appendix status table is not a formal Plan Status section" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
## Appendix

### Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Fake | released | reports/verification/fake.json |  |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_plan_status'* ]]
    [[ "$output" != *'A. Fake'* ]]
}

@test "nested Appendix status table after Plan Status heading is not accepted" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

   ### Appendix: copied status table

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Fake | released | reports/verification/fake.json |  |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_plan_status'* ]]
    [[ "$output" != *'A. Fake'* ]]
}

@test "escaped pipes remain inside a phase evidence cell" {
    mkdir -p "$TMP_DIR/reports/verification"
    cat > "$TMP_DIR/reports/verification/summary|current.json" <<'JSON'
{"status":"pass","sourceTreeId":"tree-123","bundleId":"bundle-123"}
JSON

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | {"report":"reports/verification/summary\|current.json","status":"pass","sourceTreeId":"tree-123","bundleId":"bundle-123"} |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]

    run node -e 'const result = JSON.parse(process.argv[1]); if (JSON.parse(result.phases[0].evidence).report !== "reports/verification/summary|current.json") process.exit(1)' "$output"
    [ "$status" -eq 0 ]
}

@test "report evidence must name a regular file below the repository root" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass"}\n' > "$TMP_DIR/reports/verification/summary.json"
    printf 'current verification report\n' > "$TMP_DIR/current-report.md"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | {"report":"reports/verification/summary.json","status":"pass"} |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]

    sed 's#{"report":"reports/verification/summary.json","status":"pass"}#report: current-report.md#' "$TMP_DIR/plan.md" > "$TMP_DIR/plan.next"
    mv "$TMP_DIR/plan.next" "$TMP_DIR/plan.md"
    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]

    sed 's#current-report.md#../outside.json#' "$TMP_DIR/plan.md" > "$TMP_DIR/plan.next"
    mv "$TMP_DIR/plan.next" "$TMP_DIR/plan.md"
    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "HTML comments hide Plan Status checkboxes and Completed by notes" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
<!--
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| Hidden | released | command: \`bats hidden.bats\`; exit: 0; result: hidden |  |

- [x] Hidden anonymous completion.
-->

# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| Visible | implemented |  | Task 2 |

### Task 1: Visible task

- [x] Implement the guard.

<!-- Completed by: commit \`$head_commit\`; command: \`bats tests/test-example.bats\`; exit: 0; result: hidden. -->
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
    [[ "$output" != *'anonymous_completed_task'* ]]
    [[ "$output" != *'Hidden'* ]]
}

@test "fenced checkboxes and Completed by notes are invisible" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| Visible | implemented |  | Task 2 |

   ~~~markdown
- [x] Hidden anonymous completion.
Completed by: commit `1234567890abcdef1234567890abcdef12345678`; command: `bats hidden.bats`; exit: 0; result: hidden.
   ~~~
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
    [[ "$output" != *'anonymous_completed_task'* ]]
    [[ "$output" != *'missing_checkbox_evidence'* ]]
}

@test "phase table requires a legal four-column Markdown separator" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|--|---|---|---|
| A. Plan truth | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_separator'* ]]
}

@test "phase rows require non-empty phase names and at least one valid phase" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
|  | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'empty_phase'* ]]
    [[ "$output" == *'missing_phase_rows'* ]]
}

@test "unknown phase status produces an explicit finding" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | complete |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'unknown_phase_status'* ]]
}

@test "duplicate phase names produce an explicit finding" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | planned |  | Task 2 |
| a. plan truth | implemented |  | Task 3 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'duplicate_phase'* ]]
}

@test "report JSON requires a successful top-level status" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"fail"}\n' > "$TMP_DIR/reports/verification/failed.json"
    printf '{"sourceTreeId":"tree-123"}\n' > "$TMP_DIR/reports/verification/missing-status.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | report: reports/verification/failed.json |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]

    sed 's#failed.json#missing-status.json#' "$TMP_DIR/plan.md" > "$TMP_DIR/plan.next"
    mv "$TMP_DIR/plan.next" "$TMP_DIR/plan.md"
    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "report JSON rejects invalid declared source identifiers" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass","sourceTreeId":"","bundleId":"bundle id"}\n' > "$TMP_DIR/reports/verification/invalid-identifiers.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | report: reports/verification/invalid-identifiers.json |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "report evidence rejects symlinks even when their target is valid JSON" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass"}\n' > "$TMP_DIR/reports/verification/real.json"
    ln -s real.json "$TMP_DIR/reports/verification/link.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | report: reports/verification/link.json |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "Completed by rejects a nonexistent commit" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.

Completed by: commit `0000000000000000000000000000000000000000`; command: `bats tests/test-example.bats`; exit: 0; result: 1 test passed.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
}

@test "Completed by rejects a Git object that is not a commit" {
    tree_id="$(git -C "$REPO" rev-parse HEAD^{tree})"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.

Completed by: commit \`$tree_id\`; command: \`bats tests/test-example.bats\`; exit: 0; result: 1 test passed.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
}

@test "only exact level-three numbered Task headings own completed checkboxes" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

## Task 1: Wrong level

- [x] Implement the first guard.

### Task Example: Missing number

- [x] Implement the second guard.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'anonymous_completed_task'* ]]
}

@test "a completed task cannot borrow Completed by evidence from another task" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: First

- [x] Implement the first guard.

Completed by: commit \`$head_commit\`; command: \`bats tests/test-example.bats\`; exit: 0; result: 1 test passed.

### Task 2: Second

- [x] Implement the second guard.
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
}

@test "JSON evidence preserves and validates declared source identifiers" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass","sourceTreeId":"tree-123","bundleId":"bundle-123"}\n' > "$TMP_DIR/reports/verification/summary.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | {"report":"reports/verification/summary.json","status":"pass","sourceTreeId":"tree-123","bundleId":"bundle-123"} |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]

    sed 's/"bundle-123"/"not a bundle id"/' "$TMP_DIR/plan.md" > "$TMP_DIR/plan.next"
    mv "$TMP_DIR/plan.next" "$TMP_DIR/plan.md"
    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "plan requires exactly one ATX H1" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_top_level_heading'* ]]
}

@test "Plan Status must follow the single ATX H1" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

# Plan
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'plan_status_before_top_level_heading'* ]]
}

@test "Setext H1 is forbidden even when Plan Status is otherwise valid" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
Plan
====

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'setext_top_level_heading'* ]]
}

@test "four-space indented fence marker does not enter fenced-code state" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

    ```markdown
## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "escaped HTML comment opener does not hide following Markdown" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

\<!-- literal marker

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "inline-code HTML comment opener does not hide following Markdown" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

`<!--` literal marker

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "unclosed backtick does not turn a real HTML comment into inline code" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

`literal prefix
<!--
# Hidden comment heading
- [x] Hidden anonymous completion.
-->

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "command flags cannot supply independent exit and result fields" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | command: `bats tests/example.bats --exit=0 --result=27/27-passed` | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "empty backtick command is invalid even when result contains a command name" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | command: ``; exit=0; result: bats tests/example.bats passed | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "empty backtick result is invalid" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | command: `bats tests/example.bats --exit=0`; exit: 0; result: `` | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "invalid declared report cannot be masked by valid command evidence" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"fail"}\n' > "$TMP_DIR/reports/verification/failed.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | command: `bats tests/example.bats --exit=0`; exit: 0; result: passed; report: reports/verification/failed.json |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "Completed by cannot mask an invalid declared report with command evidence" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"

    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

### Task 1: Example

- [x] Implement the guard.

Completed by: commit \`$head_commit\`; command: \`bats tests/example.bats --exit=0\`; exit: 0; result: passed; report: reports/verification/does-not-exist.json
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing_checkbox_evidence'* ]]
}

@test "JSON evidence requires every declared command and report to be valid" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass"}\n' > "$TMP_DIR/reports/verification/passed.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | {"command":"","exit":0,"result":"passed","report":"reports/verification/passed.json"} |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "JSON evidence cannot mask an empty report field with a valid path alias" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass"}\n' > "$TMP_DIR/reports/verification/passed.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | {"report":"","path":"reports/verification/passed.json"} |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "valid independent command and report fields are jointly accepted" {
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass"}\n' > "$TMP_DIR/reports/verification/passed.json"

    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Release | released | command: `bats tests/example.bats`; exit: 0; result: 1/1 passed; report: reports/verification/passed.json |  |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "multiple formal Plan Status sections are rejected" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | implemented |  | Task 2 |

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| B. Duplicate truth | implemented |  | Task 3 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'duplicate_plan_status_section'* ]]
}

@test "verified phase rejects command-only evidence" {
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | command: `bats tests/test-example.bats`; exit: 0; result: 1 test passed | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "verified phase accepts a commit reachable from current HEAD" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | commit: \`$head_commit\` | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 0 ]
}

@test "verified phase rejects a commit unreachable from current HEAD" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    tree_id="$(git -C "$REPO" rev-parse HEAD^{tree})"
    unreachable_commit="$(printf 'unreachable evidence\n' | env GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com git -C "$REPO" commit-tree "$tree_id" -p "$head_commit")"
    cat > "$TMP_DIR/plan.md" <<MARKDOWN
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | commit: \`$unreachable_commit\`; command: \`bats tests/test-example.bats\`; exit: 0; result: 1 test passed | Task 2 |
MARKDOWN

    run node "$SCRIPT" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}

@test "report JSON rejects a sourceCommit unreachable from current HEAD" {
    head_commit="$(git -C "$REPO" rev-parse HEAD)"
    tree_id="$(git -C "$REPO" rev-parse HEAD^{tree})"
    unreachable_commit="$(printf 'unreachable report source\n' | env GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com git -C "$REPO" commit-tree "$tree_id" -p "$head_commit")"
    mkdir -p "$TMP_DIR/reports/verification"
    printf '{"status":"pass","sourceCommit":"%s"}\n' "$unreachable_commit" > "$TMP_DIR/reports/verification/summary.json"
    cat > "$TMP_DIR/plan.md" <<'MARKDOWN'
# Plan

## Plan Status

| Phase | Status | Evidence | Next |
|---|---|---|---|
| A. Plan truth | verified | report: reports/verification/summary.json | Task 2 |
MARKDOWN

    run node "$SCRIPT" --repo-root "$TMP_DIR" --plan "$TMP_DIR/plan.md" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid_phase_evidence'* ]]
}
