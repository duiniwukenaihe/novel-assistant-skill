#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
}

@test "production command emitters do not return compound shell orchestration" {
  node - "$REPO" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const findings = [];
const assignment = /(?:execution_command|context_read_command|quality_command|stage_completion_command|activation_command)\s*[:=]\s*[`'"]/u;
const unsafe = /(?:&&|\|\||\$\(|\|(?!\|)|(?:^|\s)(?:\d?>|&>)|;\s*(?:node|bash|sh)\b)/u;

function stripTemplateExpressions(value) {
  let output = '';
  for (let index = 0; index < value.length; index += 1) {
    if (value[index] !== '$' || value[index + 1] !== '{') {
      output += value[index];
      continue;
    }
    index += 2;
    let depth = 1;
    for (; index < value.length && depth > 0; index += 1) {
      if (value[index] === '{') depth += 1;
      else if (value[index] === '}') depth -= 1;
    }
    output += 'VALUE';
    index -= 1;
  }
  return output;
}

for (const entry of fs.readdirSync(path.join(root, 'scripts'), { withFileTypes: true })) {
  if (!entry.isFile() || !/\.(?:c?js|mjs)$/u.test(entry.name)) continue;
  const file = path.join(root, 'scripts', entry.name);
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/u);
  lines.forEach((line, index) => {
    const emittedShape = stripTemplateExpressions(line);
    if (assignment.test(line) && unsafe.test(emittedShape)) findings.push(`${file}:${index + 1}:${line.trim()}`);
  });
}

if (findings.length) {
  process.stderr.write(`${findings.join('\n')}\n`);
  process.exit(1);
}
NODE
}
