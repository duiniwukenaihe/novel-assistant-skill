import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const repo = path.resolve(new URL('..', import.meta.url).pathname)
const script = path.join(repo, 'scripts/fanqie-category-catalog.js')

test('fanqie category catalog extracts official rank categories from html fixture', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'fanqie-category-catalog-'))
  try {
    const fixture = path.join(root, 'rank.html')
    writeFileSync(fixture, [
      '<a href="/rank/1_2_1141">西方奇幻</a>',
      '<a href="/rank/1_2_262">都市脑洞</a>',
      '<a href="/rank/1_1_1141">西方奇幻</a>',
      '<a href="/rank/0_2_1139">古风世情</a>',
      '<a href="/rank/0_2_748">豪门总裁</a>',
      '<a href="/rank/0_1_1139">古风世情</a>',
    ].join('\n'), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--fixture-rank-html',
      fixture,
      '--json',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)

    assert.equal(parsed.status, 'ok')
    assert.equal(parsed.platform, 'fanqie')
    assert.equal(parsed.catalogs.official_rank_male_reading.source, 'fanqie_rank_html')
    assert.deepEqual(parsed.catalogs.official_rank_male_reading.categories.map((row) => row.name), ['西方奇幻', '都市脑洞'])
    assert.equal(parsed.catalogs.official_rank_male_reading.categories[0].id, '1141')
    assert.equal(parsed.catalogs.official_rank_female_reading.categories[1].name, '豪门总裁')
    assert.equal(parsed.catalogs.official_rank_female_newbook.categories[0].url, 'https://fanqienovel.com/rank/0_1_1139')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fanqie category catalog keeps shortform/debut categories marked as third party', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'fanqie-category-catalog-short-'))
  try {
    const fixture = path.join(root, 'debut-category.json')
    writeFileSync(fixture, JSON.stringify({
      code: 200,
      data: [
        { name: '都市脑洞', count: 0 },
        { name: '豪门总裁', count: 0 },
      ],
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--fixture-wangwen-male-category',
      fixture,
      '--fixture-wangwen-female-category',
      fixture,
      '--json',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)

    assert.equal(parsed.catalogs.third_party_debut_male.source, 'wangwen_debut')
    assert.equal(parsed.catalogs.third_party_debut_male.official, false)
    assert.equal(parsed.catalogs.third_party_debut_male.categories[0].name, '都市脑洞')
    assert.match(parsed.notes.join('\n'), /不是番茄官方短篇分类/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fanqie category catalog extracts official app marketing categories without calling them rank categories', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'fanqie-category-catalog-app-'))
  try {
    const fixture = path.join(root, 'app.html')
    writeFileSync(fixture, [
      '热门分类，都市爽文、言情穿越、玄幻修仙、武侠世界……你想看的这里都有。',
      '拥有海量的短剧资源，包括都市热血、甜宠言情、职场婚恋、逆袭反转、逆天改命等多种类型。',
    ].join('\n'), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--fixture-app-html',
      fixture,
      '--json',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)

    assert.equal(parsed.catalogs.official_app_marketing.official, true)
    assert.equal(parsed.catalogs.official_app_marketing.source, 'fanqie_app_download')
    assert.deepEqual(parsed.catalogs.official_app_marketing.novelCategories, ['都市爽文', '言情穿越', '玄幻修仙', '武侠世界'])
    assert.deepEqual(parsed.catalogs.official_app_marketing.shortDramaCategories, ['都市热血', '甜宠言情', '职场婚恋', '逆袭反转', '逆天改命'])
    assert.match(parsed.notes.join('\n'), /App.*不是公开 Web rank 分类/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fanqie category catalog imports app api category taxonomy from json capture', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'fanqie-category-catalog-app-api-'))
  try {
    const fixture = path.join(root, 'fanqie-app-api.json')
    writeFileSync(fixture, JSON.stringify({
      data: {
        tabs: [
          {
            name: '短篇',
            categories: [
              { category_id: 'sp-100', category_name: '现代世情' },
              { category_id: 'sp-101', category_name: '悬疑反转' },
            ],
          },
          {
            name: '短剧',
            categoryList: [
              { id: 'dr-200', name: '逆袭反转' },
            ],
          },
        ],
      },
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--fixture-app-api-json',
      fixture,
      '--json',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)

    assert.equal(parsed.catalogs.official_app_api_import.status, 'imported')
    assert.equal(parsed.catalogs.official_app_api_import.source, 'fanqie_app_api_capture')
    assert.equal(parsed.catalogs.official_app_api_import.official, true)
    assert.deepEqual(
      parsed.catalogs.official_app_api_import.categories.map((row) => `${row.section}:${row.id}:${row.name}`),
      ['短篇:sp-100:现代世情', '短篇:sp-101:悬疑反转', '短剧:dr-200:逆袭反转'],
    )
    assert.match(parsed.notes.join('\n'), /App API JSON\/HAR/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fanqie category catalog imports app api category taxonomy from har capture', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'fanqie-category-catalog-app-har-'))
  try {
    const fixture = path.join(root, 'fanqie-app.har')
    writeFileSync(fixture, JSON.stringify({
      log: {
        entries: [
          {
            request: { url: 'https://api5-normal-lq.fqnovel.com/reading/user/category' },
            response: {
              content: {
                text: JSON.stringify({
                  data: {
                    categories: [
                      { id: '500', name: '家庭伦理' },
                      { id: '501', name: '复仇打脸' },
                    ],
                  },
                }),
              },
            },
          },
        ],
      },
    }), 'utf8')

    const result = spawnSync(process.execPath, [
      script,
      '--fixture-app-har',
      fixture,
      '--json',
    ], { encoding: 'utf8', timeout: 5000 })
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const parsed = JSON.parse(result.stdout)

    assert.equal(parsed.catalogs.official_app_api_import.status, 'imported')
    assert.equal(parsed.catalogs.official_app_api_import.categories.length, 2)
    assert.equal(parsed.catalogs.official_app_api_import.categories[0].sourceUrl, 'https://api5-normal-lq.fqnovel.com/reading/user/category')
    assert.deepEqual(parsed.catalogs.official_app_api_import.categories.map((row) => row.name), ['家庭伦理', '复仇打脸'])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
