import assert from 'node:assert/strict'
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const repo = path.resolve(new URL('..', import.meta.url).pathname)
const script = path.join(repo, 'scripts/scan-download-hints.js')

function runHints(input, ...args) {
  return spawnSync(process.execPath, [script, input, '--json', ...args], { encoding: 'utf8' })
}

function makeScan(lines) {
  const root = mkdtempSync(path.join(tmpdir(), 'scan-download-hints-'))
  const scan = path.join(root, 'scan')
  mkdirSync(scan, { recursive: true })
  writeFileSync(path.join(scan, 'ranking-items.jsonl'), lines.map((line) => JSON.stringify(line)).join('\n') + '\n', 'utf8')
  return { root, scan }
}

test('extracts fanqie bookId from ranking item page url', () => {
  const { root, scan } = makeScan([
    {
      rank: 1,
      title: '星：我就翻个垃圾，你就曝光我？',
      author: '布萝泥鸭',
      url: 'https://fanqienovel.com/page/7646009040631254078',
      metrics: { readCount: 12345 },
    },
  ])
  try {
    const result = runHints(scan)
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.totalItems, 1)
    assert.equal(body.downloadableCount, 1)
    assert.equal(body.hints[0].source, 'fanqie')
    assert.equal(body.hints[0].bookId, '7646009040631254078')
    assert.equal(body.hints[0].pageUrl, 'https://fanqienovel.com/page/7646009040631254078')
    assert.equal(body.hints[0].title, '星：我就翻个垃圾，你就曝光我？')
    assert.match(body.hints[0].downloadCommand, /novel_download\.py/)
    assert.match(body.hints[0].downloadCommand, /7646009040631254078/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('extracts fanqie bookId from metrics when page url is missing', () => {
  const { root, scan } = makeScan([
    {
      rank: 2,
      title: '番茄短篇样本',
      author: '作者甲',
      url: '',
      metrics: { platform: 'fanqie', bookId: '7000000000000000001' },
    },
  ])
  try {
    const result = runHints(path.join(scan, 'ranking-items.jsonl'))
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.downloadableCount, 1)
    assert.equal(body.hints[0].bookId, '7000000000000000001')
    assert.equal(body.hints[0].pageUrl, 'https://fanqienovel.com/page/7000000000000000001')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('skips non-fanqie scan items', () => {
  const { root, scan } = makeScan([
    {
      rank: 1,
      title: '点众样本',
      author: '作者乙',
      url: 'https://www.ishugui.com/book/12345',
      metrics: { score: 9.1 },
    },
  ])
  try {
    const result = runHints(scan)
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.totalItems, 1)
    assert.equal(body.downloadableCount, 0)
    assert.deepEqual(body.hints, [])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('selects single or multiple ranking items before building download plan', () => {
  const { root, scan } = makeScan([
    { rank: 1, title: '第一本', author: '作者一', url: 'https://fanqienovel.com/page/7000000000000000001' },
    { rank: 2, title: '第二本', author: '作者二', url: 'https://fanqienovel.com/page/7000000000000000002' },
    { rank: 3, title: '第三本', author: '作者三', url: 'https://fanqienovel.com/page/7000000000000000003' },
  ])
  try {
    const result = runHints(scan, '--select', '1,3')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.totalItems, 3)
    assert.equal(body.downloadableCount, 3)
    assert.equal(body.selectedCount, 2)
    assert.deepEqual(body.hints.map((item) => item.rank), [1, 3])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('skips already downloaded books with ledger', () => {
  const { root, scan } = makeScan([
    { rank: 1, title: '第一本', author: '作者一', url: 'https://fanqienovel.com/page/7000000000000000001' },
    { rank: 2, title: '第二本', author: '作者二', url: 'https://fanqienovel.com/page/7000000000000000002' },
  ])
  try {
    const ledger = path.join(root, 'download-ledger.json')
    writeFileSync(ledger, JSON.stringify({
      downloaded: [
        { source: 'fanqie', bookId: '7000000000000000002', title: '第二本' },
      ],
    }), 'utf8')
    const result = runHints(scan, '--ledger', ledger)
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.selectedCount, 1)
    assert.equal(body.skippedDuplicateCount, 1)
    assert.deepEqual(body.hints.map((item) => item.bookId), ['7000000000000000001'])
    assert.deepEqual(body.skippedDuplicates.map((item) => item.bookId), ['7000000000000000002'])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('runs selected downloads and records successful books in ledger', () => {
  const { root, scan } = makeScan([
    { rank: 1, title: '第一本', author: '作者一', url: 'https://fanqienovel.com/page/7000000000000000001' },
    { rank: 2, title: '第二本', author: '作者二', url: 'https://fanqienovel.com/page/7000000000000000002' },
  ])
  try {
    const fakeSkill = path.join(root, 'private-download-extension')
    mkdirSync(path.join(fakeSkill, 'scripts'), { recursive: true })
    const fakeDownloader = path.join(fakeSkill, 'scripts', 'novel_download.py')
    writeFileSync(fakeDownloader, [
      '#!/usr/bin/env python3',
      'import pathlib, sys',
      `pathlib.Path(${JSON.stringify(path.join(root, 'download-args.log'))}).write_text("\\n".join(sys.argv[1:]), encoding="utf-8")`,
      'sys.exit(0)',
      '',
    ].join('\n'), 'utf8')
    chmodSync(fakeDownloader, 0o755)

    const ledger = path.join(root, 'download-ledger.json')
    const result = runHints(scan, '--select', '2', '--ledger', ledger, '--download-skill-dir', fakeSkill, '--run')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.selectedCount, 1)
    assert.equal(body.runResults.length, 1)
    assert.equal(body.runResults[0].status, 0)
    assert.match(readFileSync(path.join(root, 'download-args.log'), 'utf8'), /7000000000000000002/)
    const stored = JSON.parse(readFileSync(ledger, 'utf8'))
    assert.deepEqual(stored.downloaded.map((item) => item.bookId), ['7000000000000000002'])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('sorts and limits download plan by market metrics', () => {
  const { root, scan } = makeScan([
    { rank: 1, title: '低读增', author: '作者一', url: 'https://fanqienovel.com/page/7000000000000000001', wordCount: 90000, metrics: { readCount: 1000, readGrowth: 100, score: 7.5 } },
    { rank: 2, title: '高读增', author: '作者二', url: 'https://fanqienovel.com/page/7000000000000000002', wordCount: 110000, metrics: { readCount: 8000, readGrowth: 9000, score: 8.1 } },
    { rank: 3, title: '高在读', author: '作者三', url: 'https://fanqienovel.com/page/7000000000000000003', wordCount: 120000, metrics: { readCount: 20000, readGrowth: 2000, score: 9.2 } },
  ])
  try {
    const result = runHints(scan, '--sort-by', 'readGrowth', '--top', '2')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.selectedCount, 2)
    assert.deepEqual(body.hints.map((item) => item.title), ['高读增', '高在读'])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('filters download plan by minimum market thresholds', () => {
  const { root, scan } = makeScan([
    { rank: 1, title: '弱数据', author: '作者一', url: 'https://fanqienovel.com/page/7000000000000000001', wordCount: 90000, metrics: { readCount: 1000, readGrowth: 100, score: 7.5 } },
    { rank: 2, title: '强数据', author: '作者二', url: 'https://fanqienovel.com/page/7000000000000000002', wordCount: 130000, metrics: { readCount: 20000, readGrowth: 9000, score: 8.9 } },
  ])
  try {
    const result = runHints(scan, '--min-read-count', '10000', '--min-read-growth', '5000', '--min-word-count', '100000', '--min-score', '8.5')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.selectedCount, 1)
    assert.equal(body.hints[0].title, '强数据')
    assert.equal(body.filters.minReadCount, 10000)
    assert.equal(body.sortBy, 'rank')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('sorts by adaptive quality when score is unavailable', () => {
  const { root, scan } = makeScan([
    { rank: 1, title: '榜位高但数据弱', author: '作者一', url: 'https://fanqienovel.com/page/7000000000000000001', wordCount: 50000, metrics: { readCount: 1000, readGrowth: 0, authorLevel: '作家Lv.1' } },
    { rank: 2, title: '综合数据强', author: '作者二', url: 'https://fanqienovel.com/page/7000000000000000002', wordCount: 130000, metrics: { readCount: 20000, readGrowth: 0, authorLevel: '作家Lv.4' } },
    { rank: 3, title: '字数够但热度中', author: '作者三', url: 'https://fanqienovel.com/page/7000000000000000003', wordCount: 120000, metrics: { readCount: 8000, readGrowth: 0, authorLevel: '作家Lv.2' } },
  ])
  try {
    const result = runHints(scan, '--sort-by', 'quality', '--top', '2')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.sortBy, 'quality')
    assert.equal(body.metricAvailability.readCount, 3)
    assert.equal(body.metricAvailability.score, 0)
    assert.deepEqual(body.hints.map((item) => item.title), ['综合数据强', '字数够但热度中'])
    assert.equal(typeof body.hints[0].qualityScore, 'number')
    assert.ok(body.hints[0].qualityReasons.some((line) => line.includes('总在读')))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('filters by adaptive quality score', () => {
  const { root, scan } = makeScan([
    { rank: 1, title: '弱项', author: '作者一', url: 'https://fanqienovel.com/page/7000000000000000001', wordCount: 30000, metrics: { readCount: 100, readGrowth: 0, authorLevel: '作家Lv.1' } },
    { rank: 2, title: '强项', author: '作者二', url: 'https://fanqienovel.com/page/7000000000000000002', wordCount: 150000, metrics: { readCount: 30000, readGrowth: 0, authorLevel: '作家Lv.5' } },
  ])
  try {
    const result = runHints(scan, '--sort-by', 'quality', '--min-quality', '0.6')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.selectedCount, 1)
    assert.equal(body.hints[0].title, '强项')
    assert.equal(body.filters.minQuality, 0.6)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
