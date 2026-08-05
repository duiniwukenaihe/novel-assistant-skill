#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "story-gate evidence schema exposes readable outline obligations" {
    node - "$REPO" <<'NODE'
const assert = require('assert');
const path = require('path');
const repo = process.argv[2];
const { buildShortQualityEvidenceSchema } = require(path.join(repo, 'scripts/lib/short-section-quality-evidence.js'));

const schema = buildShortQualityEvidenceSchema({
  workflowId: 'wf-neutral',
  sectionIndex: 2,
  draftDigest: 'sha256:draft',
  outlineContract: {
    contract_digest: 'outline-digest',
    section_role: 'middle',
    obligations: [
      {
        id: 'B01',
        kind: 'beat',
        source_text: '主角当众核对记录，并承担公开选择的后果。',
        required_in_draft: true,
      },
    ],
  },
  readerMilestone: { required: false },
});

assert.deepEqual(schema.outline_coverage, [{
  id: 'B01',
  kind: 'beat',
  requirement: '主角当众核对记录，并承担公开选择的后果。',
  status: 'pass|revise',
  evidence_quote: '正文中兑现该大纲义务的原句',
}]);
NODE
}
