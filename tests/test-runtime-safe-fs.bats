#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SAFE_FS="$REPO/scripts/lib/runtime-safe-fs.js"
    TMP_DIR="$(mktemp -d)"
    TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "safe filesystem rejects parent traversal before writing" {
    run node - "$SAFE_FS" "$PROJECT" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'ready') process.exit(10);
try {
  safeFs.writeFile('../escaped.txt', Buffer.from('escaped\n'), 0o600);
  process.exit(1);
} catch (error) {
  if (!/invalid|relative|safe filesystem/i.test(error.message)) process.exit(2);
}
if (fs.existsSync(`${root}/../escaped.txt`)) process.exit(3);
NODE

    [ "$status" -eq 0 ]
}

@test "safe filesystem rejects a symlinked path component" {
    mkdir -p "$TMP_DIR/outside"
    printf 'outside remains\n' > "$TMP_DIR/outside/managed.txt"
    ln -s "$TMP_DIR/outside" "$PROJECT/runtime"

    run node - "$SAFE_FS" "$PROJECT" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'ready') process.exit(10);
try {
  safeFs.writeFile('runtime/managed.txt', Buffer.from('changed\n'), 0o600);
  process.exit(1);
} catch (error) {
  if (!/symlink|safe filesystem|not a directory/i.test(error.message)) process.exit(2);
}
if (fs.readFileSync(`${root}/../outside/managed.txt`, 'utf8') !== 'outside remains\n') process.exit(3);
NODE

    [ "$status" -eq 0 ]
}

@test "safe filesystem rejects a project root with a symlinked ancestor" {
    local outside_root="$TMP_DIR/outside/book"
    local linked_root="$TMP_DIR/linked-ancestor/book"
    mkdir -p "$outside_root/snapshots/delete-me"
    printf 'outside remains\n' > "$outside_root/managed.txt"
    printf 'source remains\n' > "$outside_root/source.txt"
    printf 'delete remains\n' > "$outside_root/delete.txt"
    printf 'tree remains\n' > "$outside_root/snapshots/delete-me/keep.txt"
    ln -s "$TMP_DIR/outside" "$TMP_DIR/linked-ancestor"

    run node - "$SAFE_FS" "$linked_root" "$outside_root" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const outsideRoot = process.argv[4];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'blocked_runtime_safe_fs_unavailable') process.exit(1);

const operations = [
  () => safeFs.writeFile('managed.txt', Buffer.from('changed\n'), 0o600),
  () => safeFs.copyFile('source.txt', 'copied.txt', 0o600),
  () => safeFs.deleteFile('delete.txt'),
  () => safeFs.removeTree('snapshots/delete-me'),
];
for (const operation of operations) {
  try {
    operation();
    process.exit(2);
  } catch (error) {
    if (error.code !== 'blocked_runtime_safe_fs_unavailable') process.exit(3);
  }
}

if (fs.readFileSync(`${outsideRoot}/managed.txt`, 'utf8') !== 'outside remains\n') process.exit(4);
if (fs.readFileSync(`${outsideRoot}/source.txt`, 'utf8') !== 'source remains\n') process.exit(5);
if (fs.readFileSync(`${outsideRoot}/delete.txt`, 'utf8') !== 'delete remains\n') process.exit(6);
if (fs.readFileSync(`${outsideRoot}/snapshots/delete-me/keep.txt`, 'utf8') !== 'tree remains\n') process.exit(7);
if (fs.existsSync(`${outsideRoot}/copied.txt`)) process.exit(8);
NODE

    [ "$status" -eq 0 ]
}

@test "safe filesystem atomically replaces a regular file" {
    mkdir -p "$PROJECT/runtime"
    printf 'before\n' > "$PROJECT/runtime/managed.txt"

    node - "$SAFE_FS" "$PROJECT" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'ready') process.exit(10);
safeFs.writeFile('runtime/managed.txt', Buffer.from('after\n'), 0o640);
const stat = fs.statSync(`${root}/runtime/managed.txt`);
if (!stat.isFile()) process.exit(1);
if ((stat.mode & 0o777) !== 0o640) process.exit(2);
if (fs.readdirSync(`${root}/runtime`).some(name => name.includes('.novel-assistant-safe-fs-'))) process.exit(3);
NODE

    [ "$(cat "$PROJECT/runtime/managed.txt")" = 'after' ]
}

@test "safe filesystem creates metadata only when the target is missing" {
    mkdir -p "$PROJECT/runtime"
    printf 'user metadata\n' > "$PROJECT/runtime/existing.txt"

    node - "$SAFE_FS" "$PROJECT" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'ready') process.exit(10);
safeFs.writeFileIfMissing('runtime/existing.txt', Buffer.from('replacement\n'), 0o600);
safeFs.writeFileIfMissing('runtime/created.txt', Buffer.from('created\n'), 0o640);
if (fs.readFileSync(`${root}/runtime/existing.txt`, 'utf8') !== 'user metadata\n') process.exit(1);
if (fs.readFileSync(`${root}/runtime/created.txt`, 'utf8') !== 'created\n') process.exit(2);
if ((fs.statSync(`${root}/runtime/created.txt`).mode & 0o777) !== 0o640) process.exit(3);
NODE
}

@test "safe filesystem atomically restores from a project-relative backup" {
    mkdir -p "$PROJECT/runtime" "$PROJECT/追踪/runtime-snapshots/s1/files/runtime"
    printf 'current\n' > "$PROJECT/runtime/managed.txt"
    printf 'snapshot\n' > "$PROJECT/追踪/runtime-snapshots/s1/files/runtime/managed.txt"

    node - "$SAFE_FS" "$PROJECT" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'ready') process.exit(10);
safeFs.copyFile(
  '追踪/runtime-snapshots/s1/files/runtime/managed.txt',
  'runtime/managed.txt',
  0o600,
);
if (fs.readdirSync(`${root}/runtime`).some(name => name.includes('.novel-assistant-safe-fs-'))) process.exit(1);
NODE

    [ "$(cat "$PROJECT/runtime/managed.txt")" = 'snapshot' ]
}

@test "safe filesystem deletes only the descriptor-relative regular file" {
    mkdir -p "$PROJECT/runtime"
    printf 'managed\n' > "$PROJECT/runtime/managed.txt"
    printf 'keep\n' > "$PROJECT/runtime/keep.txt"

    node - "$SAFE_FS" "$PROJECT" <<'NODE'
const runtimeSafeFs = require(process.argv[2]);
const safeFs = runtimeSafeFs.createRuntimeSafeFs(process.argv[3]);
if (safeFs.capability.status !== 'ready') process.exit(10);
safeFs.deleteFile('runtime/managed.txt');
NODE

    [ ! -e "$PROJECT/runtime/managed.txt" ]
    [ "$(cat "$PROJECT/runtime/keep.txt")" = 'keep' ]
}

@test "safe filesystem capability failure blocks before mutation" {
    run env NOVEL_ASSISTANT_SAFE_FS_DISABLE=1 node - "$SAFE_FS" "$PROJECT" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'blocked_runtime_safe_fs_unavailable') process.exit(1);
try {
  safeFs.writeFile('runtime/managed.txt', Buffer.from('blocked\n'), 0o600);
  process.exit(2);
} catch (error) {
  if (error.code !== 'blocked_runtime_safe_fs_unavailable') process.exit(3);
}
if (fs.existsSync(`${root}/runtime/managed.txt`)) process.exit(4);
NODE

    [ "$status" -eq 0 ]
}

@test "safe filesystem rejects every invalid relative path form" {
    run node - "$SAFE_FS" "$PROJECT" <<'NODE'
const runtimeSafeFs = require(process.argv[2]);
const safeFs = runtimeSafeFs.createRuntimeSafeFs(process.argv[3]);
if (safeFs.capability.status !== 'ready') process.exit(10);
for (const relativePath of ['', '.', '..', '/absolute', 'runtime//managed.txt', 'runtime/./managed.txt']) {
  try {
    safeFs.writeFile(relativePath, Buffer.from('invalid\n'), 0o600);
    process.exit(1);
  } catch (error) {
    if (!/invalid|relative|safe filesystem/i.test(error.message)) process.exit(2);
  }
}
NODE

    [ "$status" -eq 0 ]
    [ ! -e "$PROJECT/runtime/managed.txt" ]
}

@test "safe filesystem removes a regular tree and refuses a tree containing a symlink" {
    mkdir -p "$PROJECT/snapshots/clean/nested" "$PROJECT/snapshots/unsafe/nested"
    printf 'remove\n' > "$PROJECT/snapshots/clean/nested/file.txt"
    printf 'keep\n' > "$PROJECT/snapshots/unsafe/keep.txt"
    ln -s "$TMP_DIR/outside" "$PROJECT/snapshots/unsafe/nested/link"

    run node - "$SAFE_FS" "$PROJECT" <<'NODE'
const fs = require('fs');
const runtimeSafeFs = require(process.argv[2]);
const root = process.argv[3];
const safeFs = runtimeSafeFs.createRuntimeSafeFs(root);
if (safeFs.capability.status !== 'ready') process.exit(10);
safeFs.removeTree('snapshots/clean');
if (fs.existsSync(`${root}/snapshots/clean`)) process.exit(1);
try {
  safeFs.removeTree('snapshots/unsafe');
  process.exit(2);
} catch (error) {
  if (!/symlink|non-regular|safe filesystem/i.test(error.message)) process.exit(3);
}
if (fs.readFileSync(`${root}/snapshots/unsafe/keep.txt`, 'utf8') !== 'keep\n') process.exit(4);
NODE

    [ "$status" -eq 0 ]
    [ -L "$PROJECT/snapshots/unsafe/nested/link" ]
}

@test "blocked safe filesystem rejects every operation with the capability code" {
    run env NOVEL_ASSISTANT_SAFE_FS_DISABLE=1 node - "$SAFE_FS" "$PROJECT" <<'NODE'
const runtimeSafeFs = require(process.argv[2]);
const safeFs = runtimeSafeFs.createRuntimeSafeFs(process.argv[3]);
const calls = [
  () => safeFs.writeFile('runtime/file', Buffer.from('x'), 0o600),
  () => safeFs.copyFile('source', 'target', 0o600),
  () => safeFs.deleteFile('runtime/file'),
  () => safeFs.removeTree('runtime/tree'),
];
for (const call of calls) {
  try {
    call();
    process.exit(1);
  } catch (error) {
    if (error.code !== 'blocked_runtime_safe_fs_unavailable') process.exit(2);
  }
}
NODE

    [ "$status" -eq 0 ]
}

@test "missing compiler blocks the capability" {
    mkdir -p "$TMP_DIR/no-compiler-tmp"

    run env TMPDIR="$TMP_DIR/no-compiler-tmp" CC="$TMP_DIR/missing-cc" node - "$SAFE_FS" "$PROJECT" <<'NODE'
const runtimeSafeFs = require(process.argv[2]);
const safeFs = runtimeSafeFs.createRuntimeSafeFs(process.argv[3]);
if (safeFs.capability.status !== 'blocked_runtime_safe_fs_unavailable') process.exit(1);
try {
  safeFs.deleteFile('runtime/file');
  process.exit(2);
} catch (error) {
  if (error.code !== 'blocked_runtime_safe_fs_unavailable') process.exit(3);
}
NODE

    [ "$status" -eq 0 ]
}

@test "cached helper self-test failure blocks the capability" {
    local helper_tmp="$TMP_DIR/self-test-tmp"
    local helper_cache="$helper_tmp/novel-assistant-safe-fs-$(id -u)"
    local source_hash
    source_hash="$(shasum -a 256 "$REPO/scripts/native/novel-assistant-safe-fs-posix.c" | awk '{print $1}')"
    mkdir -p "$helper_cache"
    printf '#!/bin/sh\nprintf "wrong-version\\n"\n' > "$helper_cache/novel-assistant-safe-fs-posix-$source_hash"
    chmod 700 "$helper_cache/novel-assistant-safe-fs-posix-$source_hash"

    run env TMPDIR="$helper_tmp" node - "$SAFE_FS" "$PROJECT" <<'NODE'
const runtimeSafeFs = require(process.argv[2]);
const safeFs = runtimeSafeFs.createRuntimeSafeFs(process.argv[3]);
if (safeFs.capability.status !== 'blocked_runtime_safe_fs_unavailable') process.exit(1);
try {
  safeFs.removeTree('runtime/tree');
  process.exit(2);
} catch (error) {
  if (error.code !== 'blocked_runtime_safe_fs_unavailable') process.exit(3);
}
NODE

    [ "$status" -eq 0 ]
}
