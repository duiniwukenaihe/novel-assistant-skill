#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "assembly integrity creates a focused recheck queue for changed accepted sections" {
    node - "$REPO/scripts/lib/short-feedback-revision-queue.js" <<'NODE'
const { initializeAssemblyIntegrityRevisionQueue } = require(process.argv[2]);
const task = {
  workflow_type: 'private_short_startup',
  scope: '全篇',
  feedback_revision_queue: { queue_id: 'old.queue', status: 'completed', revision_round: 2 },
};
const result = initializeAssemblyIntegrityRevisionQueue(task, {
  invalid_sections: [
    { section_index: 7, reason: 'short_section_canonical_sha256_mismatch' },
    { section_index: 6, reason: 'short_section_canonical_sha256_mismatch' },
  ],
});
if (result.status !== 'assembly_integrity_revision_queue_created') throw new Error(JSON.stringify(result));
if (result.queue.current_section_index !== 6) throw new Error(JSON.stringify(result.queue));
if (task.scope !== '第6节') throw new Error(task.scope);
if (result.queue.items.some(item => item.brief_status !== 'current' || item.prose_status !== 'pending_recheck')) throw new Error(JSON.stringify(result.queue.items));
if (result.queue.checkpoints[0].previous_queue_id !== 'old.queue') throw new Error(JSON.stringify(result.queue.checkpoints));
NODE
}

@test "assembly integrity distinguishes missing sections from changed prose" {
    node - "$REPO/scripts/lib/short-feedback-revision-queue.js" <<'NODE'
const { initializeAssemblyIntegrityRevisionQueue } = require(process.argv[2]);
const task = { workflow_type: 'short_write' };
const result = initializeAssemblyIntegrityRevisionQueue(task, {
  missing_sections: [2],
  invalid_sections: [{ section_index: 4, reason: 'invalid_acceptance' }],
});
const missing = result.queue.items.find(item => item.section_index === 2);
const changed = result.queue.items.find(item => item.section_index === 4);
if (missing.brief_status !== 'missing' || missing.prose_status !== 'missing') throw new Error(JSON.stringify(missing));
if (changed.brief_status !== 'current' || changed.prose_status !== 'pending_recheck') throw new Error(JSON.stringify(changed));
NODE
}

@test "task overview renders non-contiguous preserved sections precisely" {
    grep -q "groups.map(group => group.length === 1" "$REPO/scripts/lib/workflow-action-renderer.js"
    grep -q "未受影响小节" "$REPO/scripts/lib/workflow-action-renderer.js"
    ! grep -q 'return `第 \${sections\[0\]}-\${sections\[sections.length - 1\]} 节`' "$REPO/scripts/lib/workflow-action-renderer.js"
}
