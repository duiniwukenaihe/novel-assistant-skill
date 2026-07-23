'use strict';

const ACCEPTED_STATUSES = new Set(['pass', 'pass_with_advisory']);

function projectAcceptedQuality(result) {
  const quality = result && typeof result === 'object' && !Array.isArray(result) ? result : {};
  if (!ACCEPTED_STATUSES.has(String(quality.status || ''))) {
    return { beatSheetQualityGate: null, contractProjection: [], memoryProjection: [] };
  }

  return {
    beatSheetQualityGate: {
      version: 'detail_outline_quality_v1',
      status: quality.status,
      outlinePath: quality.outline_path,
      outlineSha256: quality.outline_sha256,
      activatedDimensions: Array.isArray(quality.activated_dimensions) ? quality.activated_dimensions : [],
      acceptedAt: quality.execution && quality.execution.completed_at || '',
    },
    contractProjection: Array.isArray(quality.contract_projection) ? quality.contract_projection : [],
    memoryProjection: Array.isArray(quality.memory_projection) ? quality.memory_projection : [],
    narrativeContract: quality.narrative_contract && typeof quality.narrative_contract === 'object'
      ? quality.narrative_contract
      : null,
  };
}

module.exports = { projectAcceptedQuality };
