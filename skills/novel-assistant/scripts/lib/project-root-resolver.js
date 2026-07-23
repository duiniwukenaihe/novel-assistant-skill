'use strict';

const fs = require('fs');
const path = require('path');

const BOOK_EVIDENCE_NAMES = ['.story-deployed', '正文', '大纲', '追踪'];

function resolveProjectRoot({ cwd = process.cwd(), mode = 'book_only', explicitBookRoot = '' } = {}) {
  const workingRoot = path.resolve(cwd || process.cwd());
  const requestedRoot = explicitBookRoot
    ? path.resolve(workingRoot, explicitBookRoot)
    : workingRoot;
  const directory = inspectDirectory(requestedRoot);
  if (directory.status !== 'ok') return directory.result;

  if (mode === 'library') {
    return {
      status: 'rejected',
      root_kind: 'library',
      workspace_root: requestedRoot,
      book_root: '',
      evidence: ['explicit_library_mode'],
      candidates: directBookCandidates(requestedRoot),
    };
  }

  if (mode === 'auto') {
    const candidates = directBookCandidates(requestedRoot);
    if (candidates.length > 0) {
      return {
        status: 'ambiguous',
        root_kind: 'ambiguous',
        workspace_root: requestedRoot,
        book_root: '',
        evidence: ['direct_book_candidates'],
        candidates,
      };
    }
  } else if (mode !== 'book_only') {
    return rejected('unknown', requestedRoot, `unsupported_mode:${mode}`);
  }

  return {
    status: 'resolved',
    root_kind: 'book',
    workspace_root: '',
    book_root: requestedRoot,
    evidence: bookEvidence(requestedRoot),
    candidates: [],
  };
}

function inspectDirectory(requestedRoot) {
  try {
    let current = path.parse(requestedRoot).root;
    let stat = fs.lstatSync(current);
    for (const segment of requestedRoot.slice(current.length).split(path.sep).filter(Boolean)) {
      current = path.join(current, segment);
      stat = fs.lstatSync(current);
      if (stat.isSymbolicLink() && !isSystemRootAlias(current, stat)) {
        return { status: 'rejected', result: rejected('symlink_escape', requestedRoot, 'symlink_escape') };
      }
    }
    if (!stat.isDirectory()) return { status: 'rejected', result: rejected('unknown', requestedRoot, 'not_directory') };
    return { status: 'ok' };
  } catch (error) {
    return { status: 'rejected', result: rejected('unknown', requestedRoot, `missing:${error.code || 'path'}`) };
  }
}

function isSystemRootAlias(candidate, stat) {
  const parsed = path.parse(candidate);
  return path.dirname(candidate) === parsed.root && stat.uid === 0;
}

function rejected(rootKind, requestedRoot, evidence) {
  return {
    status: 'rejected',
    root_kind: rootKind,
    workspace_root: '',
    book_root: '',
    evidence: [evidence],
    candidates: requestedRoot ? [requestedRoot] : [],
  };
}

function bookEvidence(root) {
  const evidence = [];
  for (const name of BOOK_EVIDENCE_NAMES) {
    if (fs.existsSync(path.join(root, name))) evidence.push(name);
  }
  return evidence.length ? evidence : ['exact_requested_directory'];
}

function hasBookEvidence(root) {
  return BOOK_EVIDENCE_NAMES.some(name => fs.existsSync(path.join(root, name)));
}

function directBookCandidates(root) {
  try {
    return fs.readdirSync(root, { withFileTypes: true })
      .filter(entry => entry.isDirectory())
      .map(entry => path.join(root, entry.name))
      .filter(hasBookEvidence)
      .sort();
  } catch (_) {
    return [];
  }
}

module.exports = { resolveProjectRoot };
