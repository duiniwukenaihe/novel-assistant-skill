# Task 5 Canonical Write Policy Verification

- Date: 2026-07-10
- Base source commit: `5b9bd817e9151aeded61e712ef028509507fa1ea`
- Scope: `scripts/canonical-write-policy.js`, `scripts/lib/canonical-write-policy.js`, `scripts/lib/workflow-state-store.js`, and Task 5 Bats coverage only.

## RED

Command: `bats tests/test-canonical-write-policy.bats`

Result: expected failure before implementation. The run failed on legacy migration metadata, the added strict roots, unsafe canonical targets, concurrent stale takeover, and stale per-lease guard recovery.

## GREEN

Canonical targets resolve against the real project root. In-project absolute targets are stored as relative POSIX paths; traversal outside the root, outside absolute paths, and symlink escapes return `blocked_unsafe_target`.

Strict mode now protects prose, outlines, hook ledger, timeline, character state, context, memory subtree, and handoff subtree. Legacy canonical writes return `allowed_with_risk`, `legacy_canonical_write_unprotected`, and a strict-policy migration hint; noncanonical legacy writes remain `allowed`.

Chapter acquire, stale takeover, and release use a per-lease atomic directory guard. The guarded section performs the lease read, token comparison, replacement, or deletion. Stale guard directories are atomically retired and removed before retrying. Bats coverage uses separate Node processes to verify an old release preserves a live replacement lease and only one concurrent stale takeover succeeds.

## Acceptance Commands

```bash
bats tests/test-canonical-write-policy.bats tests/test-chapter-commit.bats tests/test-chapter-commit-integration.bats
```

Result: exit `0`; `27/27` tests passed.
