import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const repo = path.resolve(new URL('..', import.meta.url).pathname)
const scraper = path.join(repo, 'src/internal-skills/story-short-scan/scripts/wangwen-debut-scraper.js')
const hints = path.join(repo, 'scripts/scan-download-hints.js')

test('wangwen debut scraper writes v0.8 fanqie artifacts with bookId', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'wangwen-debut-scraper-'))
  try {
    const fixtureList = path.join(root, 'list.json')
    writeFileSync(fixtureList, JSON.stringify({
      code: 200,
      message: 'ok',
      data: {
        records: [{
          bookId: '7646009040631254078',
          media: 'fq',
          bookName: '星：我就翻个垃圾，你就曝光我？',
          gender: 1,
          sxDate: '2026-07-08 00:00:00',
          authorName: '布萝泥鸭',
          authorLevel: 'Lv.2',
          category: '都市脑洞',
          updateStatus: 1,
          wordCount: 81234,
          readCount: 45678,
          wordGrowth: 12345,
          readGrowth: 6789,
          wordTrend: '[{"2026-07-08":"12345"}]',
          readTrend: '[{"2026-07-08":"6789"}]',
          tags: ['星际', '爽文'],
          imageUrl: 'https://example.com/cover.jpg',
        }],
        total: 1,
        size: 20,
        current: 1,
      },
    }), 'utf8')

    const outdir = path.join(root, 'out')
    const result = spawnSync(process.execPath, [
      scraper,
      '--fixture-list',
      fixtureList,
      '--outdir',
      outdir,
      '--date',
      '2026-07-08',
      '--channel',
      'male',
      '--size',
      '20',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)

    const jsonl = readFileSync(path.join(outdir, 'ranking-items.jsonl'), 'utf8').trim()
    const item = JSON.parse(jsonl)
    assert.equal(item.title, '星：我就翻个垃圾，你就曝光我？')
    assert.equal(item.url, 'https://fanqienovel.com/page/7646009040631254078')
    assert.equal(item.metrics.bookId, '7646009040631254078')
    assert.equal(item.metrics.source, 'wangwen_debut')
    assert.equal(item.metrics.readGrowth, 6789)

    const hintResult = spawnSync(process.execPath, [hints, outdir, '--json'], { encoding: 'utf8' })
    assert.equal(hintResult.status, 0, hintResult.stderr || hintResult.stdout)
    const parsed = JSON.parse(hintResult.stdout)
    assert.equal(parsed.downloadableCount, 1)
    assert.equal(parsed.hints[0].bookId, '7646009040631254078')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('wangwen debut scraper lists category boards from fixture', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'wangwen-debut-categories-'))
  try {
    const fixtureCategory = path.join(root, 'category.json')
    writeFileSync(fixtureCategory, JSON.stringify({
      code: 200,
      message: 'ok',
      data: [
        { name: '都市脑洞', count: 12 },
        { name: '玄幻脑洞', count: 8 },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      scraper,
      '--list-categories',
      '--fixture-category',
      fixtureCategory,
      '--date',
      '2026-07-08',
      '--channel',
      'male',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.status, 'ok')
    assert.equal(parsed.source, 'wangwen_debut')
    assert.deepEqual(parsed.categories, [
      { name: '都市脑洞', count: 12 },
      { name: '玄幻脑洞', count: 8 },
    ])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('wangwen debut scraper can enrich items from official fanqie book info', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'wangwen-debut-fanqie-enrich-'))
  try {
    const fixtureList = path.join(root, 'list.json')
    const infoDir = path.join(root, 'fanqie-info')
    writeFileSync(fixtureList, JSON.stringify({
      code: 200,
      message: 'ok',
      data: {
        records: [{
          bookId: '7646009040631254078',
          media: 'fq',
          bookName: '第三方旧标题',
          gender: 1,
          sxDate: '2026-07-08 00:00:00',
          authorName: '第三方作者',
          authorLevel: 'Lv.2',
          category: '第三方分类',
          updateStatus: 1,
          wordCount: 81234,
          readCount: 45678,
          wordGrowth: 12345,
          readGrowth: 6789,
          tags: ['星际', '爽文'],
        }],
        total: 1,
      },
    }), 'utf8')
    mkdirSync(infoDir, { recursive: true })
    writeFileSync(path.join(infoDir, '7646009040631254078.json'), JSON.stringify({
      data: {
        bookId: '7646009040631254078',
        bookName: '星：我就翻个垃圾，你就曝光我？',
        authorName: '布萝泥鸭',
        author: '布萝泥鸭',
        wordNumber: '109876',
        readCount: '45441',
        abstract: '官方简介。',
        lastChapterTitle: '第35章 元流之子',
        categoryV2: '[{"Name":"动漫衍生","MainCategory":true},{"Name":"穿越","MainCategory":false}]',
        thumbUrl: 'https://example.com/fanqie-cover.jpg',
        creationStatus: '1',
      },
    }), 'utf8')

    const outdir = path.join(root, 'out')
    const result = spawnSync(process.execPath, [
      scraper,
      '--fixture-list',
      fixtureList,
      '--fixture-fanqie-info-dir',
      infoDir,
      '--enrich-fanqie',
      '--outdir',
      outdir,
      '--date',
      '2026-07-08',
      '--channel',
      'male',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)

    const item = JSON.parse(readFileSync(path.join(outdir, 'ranking-items.jsonl'), 'utf8').trim())
    assert.equal(item.title, '星：我就翻个垃圾，你就曝光我？')
    assert.equal(item.author, '布萝泥鸭')
    assert.equal(item.genre, '动漫衍生')
    assert.equal(item.wordCount, 109876)
    assert.equal(item.metrics.readCount, 45441)
    assert.equal(item.metrics.marketReadCount, 45678)
    assert.equal(item.metrics.fanqieOfficial.verified, true)
    assert.equal(item.metrics.fanqieOfficial.lastChapterTitle, '第35章 元流之子')
    assert.equal(item.dataQuality, 'ok')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
