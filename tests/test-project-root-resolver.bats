#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "project root resolver keeps book_only resolution at the exact requested directory" {
    mkdir -p "$TMP_DIR/library/book-a" "$TMP_DIR/library/book-a/nested-book" "$TMP_DIR/empty" "$TMP_DIR/parent/child" "$TMP_DIR/child-parent/book-child"
    printf 'deployed_at: now\n' > "$TMP_DIR/library/book-a/.story-deployed"
    printf 'deployed_at: now\n' > "$TMP_DIR/library/book-a/nested-book/.story-deployed"
    printf 'deployed_at: now\n' > "$TMP_DIR/parent/.story-deployed"
    printf 'deployed_at: now\n' > "$TMP_DIR/child-parent/book-child/.story-deployed"

    node - "$REPO" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const path = require('path');
const { resolveProjectRoot } = require(path.join(process.argv[2], 'scripts/lib/project-root-resolver'));
const root = process.argv[3];

const exactBook = resolveProjectRoot({ cwd: path.join(root, 'library/book-a') });
assert.deepStrictEqual(
  pick(exactBook),
  { status: 'resolved', root_kind: 'book', workspace_root: '', book_root: path.join(root, 'library/book-a') },
);
assert(exactBook.evidence.includes('.story-deployed'));

const empty = resolveProjectRoot({ cwd: path.join(root, 'empty') });
assert.deepStrictEqual(
  pick(empty),
  { status: 'resolved', root_kind: 'book', workspace_root: '', book_root: path.join(root, 'empty') },
);

const nested = resolveProjectRoot({ cwd: path.join(root, 'library/book-a') });
assert.strictEqual(nested.book_root, path.join(root, 'library/book-a'));
assert(!nested.candidates.includes(path.join(root, 'library/book-a/nested-book')));

const parentSentinel = resolveProjectRoot({ cwd: path.join(root, 'parent/child') });
assert.strictEqual(parentSentinel.book_root, path.join(root, 'parent/child'));
assert(!parentSentinel.evidence.includes('parent:.story-deployed'));

const childBook = resolveProjectRoot({ cwd: path.join(root, 'child-parent') });
assert.strictEqual(childBook.book_root, path.join(root, 'child-parent'));
assert(!childBook.candidates.includes(path.join(root, 'child-parent/book-child')));

function pick(result) {
  return {
    status: result.status,
    root_kind: result.root_kind,
    workspace_root: result.workspace_root,
    book_root: result.book_root,
  };
}
NODE
}

@test "project root resolver rejects explicitly identified library, ambiguity, and symlink escape" {
    mkdir -p "$TMP_DIR/library/book-a" "$TMP_DIR/library/book-b" "$TMP_DIR/library/notes" "$TMP_DIR/book-a" "$TMP_DIR/book-b" "$TMP_DIR/outside" "$TMP_DIR/outside-host/book"
    printf 'deployed_at: now\n' > "$TMP_DIR/library/book-a/.story-deployed"
    printf 'deployed_at: now\n' > "$TMP_DIR/library/book-b/.story-deployed"
    ln -s "$TMP_DIR/outside" "$TMP_DIR/escaped-book"
    ln -s "$TMP_DIR/outside-host" "$TMP_DIR/host-escape"

    node - "$REPO" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const path = require('path');
const { resolveProjectRoot } = require(path.join(process.argv[2], 'scripts/lib/project-root-resolver'));
const root = process.argv[3];

const library = resolveProjectRoot({ cwd: path.join(root, 'library'), mode: 'library' });
assert.strictEqual(library.status, 'rejected');
assert.strictEqual(library.root_kind, 'library');
assert.strictEqual(library.workspace_root, path.join(root, 'library'));
assert.strictEqual(library.book_root, '');

const ambiguous = resolveProjectRoot({
  cwd: path.join(root, 'library'),
  mode: 'auto',
});
assert.strictEqual(ambiguous.status, 'ambiguous');
assert.strictEqual(ambiguous.root_kind, 'ambiguous');
assert.deepStrictEqual(ambiguous.candidates, [
  path.join(root, 'library/book-a'),
  path.join(root, 'library/book-b'),
]);

const escaped = resolveProjectRoot({ cwd: path.join(root, 'escaped-book') });
assert.strictEqual(escaped.status, 'rejected');
assert.strictEqual(escaped.root_kind, 'symlink_escape');
assert.strictEqual(escaped.book_root, '');

const ancestorEscaped = resolveProjectRoot({ cwd: path.join(root, 'host-escape/book') });
assert.strictEqual(ancestorEscaped.status, 'rejected');
assert.strictEqual(ancestorEscaped.root_kind, 'symlink_escape');
assert.strictEqual(ancestorEscaped.book_root, '');
NODE
}
