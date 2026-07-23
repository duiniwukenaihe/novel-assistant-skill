#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO/scripts/workflow-session-id.js"
}

@test "Codex Desktop thread id becomes a stable codex session identity" {
  node - "$SCRIPT" <<'NODE'
const { resolveSessionId } = require(process.argv[2]);
const out = resolveSessionId({ CODEX_THREAD_ID: 'thread-123' }, 1);
if (out.session_id !== 'codex:thread-123' || out.host !== 'codex' || out.source !== 'environment') {
  throw new Error(JSON.stringify(out));
}
NODE
}

@test "Claude and explicit novel assistant session ids keep stable host identities" {
  node - "$SCRIPT" <<'NODE'
const { resolveSessionId } = require(process.argv[2]);
const claude = resolveSessionId({ CLAUDE_SESSION_ID: 'session-456' }, 1);
const explicit = resolveSessionId({ NOVEL_ASSISTANT_SESSION_ID: 'zcode:session-789' }, 1);
if (claude.session_id !== 'claude:session-456' || claude.host !== 'claude') throw new Error(JSON.stringify(claude));
if (explicit.session_id !== 'zcode:session-789' || explicit.host !== 'zcode') throw new Error(JSON.stringify(explicit));
NODE
}
