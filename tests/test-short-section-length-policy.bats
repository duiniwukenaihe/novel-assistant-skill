#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO/scripts/short-section-length-policy.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/追踪/private-short-extension"
}

teardown() {
  rm -rf "$TMP_DIR"
}

write_state() {
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{
  "accepted_sections": [
    {"section_index": 1, "length_chars": 2490, "section_role": "opening"}
  ]
}
JSON
}

@test "first accepted section establishes a provisional local baseline" {
  write_state
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --planned-target 2500 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.baseline_chars!==2490 || x.baseline_status!=="provisional" || x.verdict!=="within_story_band") process.exit(1)' "$output"
}

@test "ordinary section far below the accepted baseline blocks the next brief" {
  write_state
  node - "$BOOK/追踪/private-short-extension/project-state.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
state.accepted_sections.push({ section_index: 2, length_chars: 1724 });
fs.writeFileSync(file, JSON.stringify(state));
NODE
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --actual 1724 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="outside_story_band" || !x.blocking || x.baseline_chars!==2490 || x.sample_size!==1) process.exit(1)' "$output"
}

@test "explicit transition exception is allowed only with a story reason" {
  write_state
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --planned-target 1800 --section-role transition --json
  [ "$status" -eq 0 ]
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --planned-target 1800 --section-role transition --exception-reason "本节只承担撤离后的即时转场与新钩子" --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="explicit_story_exception" || x.blocking) process.exit(1)' "$output"
}

@test "three accepted sections switch the baseline to a rolling median" {
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"accepted_sections":[
  {"section_index":1,"length_chars":2490},
  {"section_index":2,"length_chars":2380},
  {"section_index":3,"length_chars":2520},
  {"section_index":4,"length_chars":3100,"section_role":"climax"}
]}
JSON
  run node "$SCRIPT" --project-root "$BOOK" --section-index 5 --planned-target 2450 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.baseline_status!=="stabilized" || x.baseline_chars!==2490 || x.sample_size!==3) process.exit(1)' "$output"
}

@test "public and private short workflows require the local length baseline before the next brief" {
  grep -q 'short-section-length-policy.js' "$REPO/src/internal-skills/story-short-write/SKILL.md"
  if [ -f "$REPO/src/private-internal-skills/private-short-extension/SKILL.md" ]; then
    grep -q 'short-section-length-policy.js' "$REPO/src/private-internal-skills/private-short-extension/SKILL.md"
    grep -q '作品内篇幅基准' "$REPO/src/private-internal-skills/private-short-extension/workflow-registry.json"
  fi
  grep -q 'short-section-length-policy.js' "$REPO/config/novel-assistant-bundle-files.json"
}

@test "accepted section proof requires fresh double gates and current canonical hash" {
  printf '%s\n' '第一节正文' > "$BOOK/正文.md"
  mkdir -p "$BOOK/追踪/private-short-extension"
  hash="$(shasum -a 256 "$BOOK/正文.md" | awk '{print $1}')"
  cat > "$BOOK/追踪/private-short-extension/section-001-anchor.json" <<JSON
{"workflow_id":"wf-short-proof","section_index":1,"status":"accepted","canonical_path":"正文.md","canonical_sha256":"$hash","quality_result":{"machine_gate":"pass","story_value_gate":"pass","repetition_gate":"pass","length_policy":{"blocking":false,"verdict":"baseline_not_established"}}}
JSON
  run node - "$REPO/scripts/lib/short-section-acceptance-proof.js" "$BOOK" "$hash" <<'NODE'
const assert = require('assert');
const { validateShortSectionAcceptanceProof } = require(process.argv[2]);
const root = process.argv[3];
const hash = process.argv[4];
const proof = { workflow_id: 'wf-short-proof', section_index: 1, anchor_path: '追踪/private-short-extension/section-001-anchor.json', canonical_path: '正文.md', canonical_sha256: hash };
assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-short-proof', proof }).status, 'accepted');
const anchor = require('fs').readFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, 'utf8');
require('fs').writeFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, anchor.replace('"story_value_gate":"pass"', '"story_value_gate":"pending"'));
assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-short-proof', proof }).code, 'short_section_story_value_gate_missing');
NODE
  [ "$status" -eq 0 ]
}
