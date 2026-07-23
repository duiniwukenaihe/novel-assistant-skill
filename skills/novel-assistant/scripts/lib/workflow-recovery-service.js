'use strict';

function createWorkflowRecoveryService(deps) {
  const exists = deps.exists;
  const resolveInsideProject = deps.resolveInsideProject;
  const durableTaskSnapshotPath = deps.durableTaskSnapshotPath;

  function isLiveWorkflowSessionLease(lease, now = new Date()) {
    if (!lease || !lease.holder_id) return false;
    const expiresAt = new Date(lease.expires_at || '').getTime();
    return Number.isFinite(expiresAt) && expiresAt > now.getTime();
  }

  function trustedRuntimeCheckpoint(task, root) {
    const recovery = task.repair_integrity_recovery || {};
    const archived = String(recovery.archived_candidate_dir || '');
    const current = String((((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact || ''));
    if (recovery.requires_current_text_recheck || (archived && current.includes(archived))) {
      const reviewPlan = String(task.review_plan_path || '');
      if (reviewPlan && exists(resolveInsideProject(root, reviewPlan))) return reviewPlan;
      const rpd = String(task.rpd_path || '');
      if (rpd && exists(resolveInsideProject(root, rpd))) return rpd;
      return durableTaskSnapshotPath(task);
    }
    return current || durableTaskSnapshotPath(task);
  }

  return {
    isLiveWorkflowSessionLease,
    trustedRuntimeCheckpoint,
  };
}

module.exports = { createWorkflowRecoveryService };
