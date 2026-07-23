import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const repo = path.resolve(new URL('..', import.meta.url).pathname)
const script = path.join(repo, 'scripts/story-prose-gate.js')

function runGate(root, ...args) {
  return spawnSync(process.execPath, [script, root, ...args, '--json'], { encoding: 'utf8' })
}

function makeBook() {
  const root = mkdtempSync(path.join(tmpdir(), 'story-prose-gate-'))
  mkdirSync(path.join(root, '正文/第1卷'), { recursive: true })
  return root
}

test('passes clean canonical volume-local draft', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_干净稿.md'), '## 第1章 干净稿\n\n陈洛趴在泥里。\n狼在洞外。\n他没有动。\n', 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'pass')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fails when legacy flat duplicate can pollute chapter context', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_新稿.md'), '## 第1章 新稿\n\n陈洛活下来了。\n', 'utf8')
    writeFileSync(path.join(root, '正文/第001章_旧稿.md'), '## 第1章 旧稿\n\n陈——洛——死——了。\n', 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 2, result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'fail')
    assert.equal(body.findings.some(item => item.type === 'legacy-duplicate'), true)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('allows sparse functional Chinese em dash but fails ellipsis remnants', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_坏稿.md'), '## 第1章 坏稿\n\n陈洛抬头——狼在洞外……\n', 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 2, result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'fail')
    assert.equal(body.findings.some(item => item.type === 'dash'), false)
    assert.equal(body.findings.some(item => item.type === 'ellipsis'), true)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fails on dash density overuse', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_坏稿.md'), [
      '## 第1章 坏稿',
      '',
      '陈洛停住——门外有人。',
      '黑狗崽抬头——尾巴绷直。',
      '风吹进来——血腥味更重。',
      '铃声一响——所有人都看向他。',
      '',
    ].join('\n'), 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 2, result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'fail')
    assert.equal(body.findings.some(item => item.type === 'dash-density'), true)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fails on nonstandard dash forms', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_坏稿.md'), '## 第1章 坏稿\n\n陈洛抬头--狼在洞外。\n他一顿—没再说话。\n', 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 2, result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'fail')
    assert.equal(body.findings.filter(item => item.type === 'invalid-dash').length, 2)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('fails when prose leaks writing workflow terms into dialogue', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_坏稿.md'), [
      '## 第1章 坏稿',
      '',
      '沈七把锅铲一放。',
      '绿珠问：“那现在怎么办？”',
      '沈七说：“该到下一章了，本章任务已经完成。”',
      '灶火还在响。',
      '',
    ].join('\n'), 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 2, result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'fail')
    assert.equal(body.findings.some(item => item.type === 'prose-meta-leak'), true)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('allows chapter wording when it is an in-world reading object', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_干净稿.md'), [
      '## 第1章 干净稿',
      '',
      '先生把旧书推到桌边。',
      '“翻到下一章。”他说，“照着经文读。”',
      '沈七低头，纸页边缘都是油烟。',
      '',
    ].join('\n'), 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'pass')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('allows in-world system task panel wording', () => {
  const root = makeBook()
  try {
    writeFileSync(path.join(root, '正文/第1卷/第001章_系统面板.md'), [
      '## 第1章 系统面板',
      '',
      '蓝色光幕在灶台前展开。',
      '【任务描述：在厨房立足，拿到第一口热锅。】',
      '沈七盯着那行字，心里更稳了。',
      '',
    ].join('\n'), 'utf8')

    const result = runGate(root, '--chapter', '1')
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'pass')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('ignores non-prose tracking files even when their names look chapter-like', () => {
  const root = makeBook()
  try {
    mkdirSync(path.join(root, '追踪/审查报告'), { recursive: true })
    const report = path.join(root, '追踪/审查报告/第001章.md')
    writeFileSync(report, [
      '# 第001章 审查报告',
      '',
      '下一步候选：回复继续可写下一章。',
      '发现：本章任务描述需要回到细纲节点复核。',
      '',
    ].join('\n'), 'utf8')

    const result = runGate(report)
    assert.equal(result.status, 0, result.stderr || result.stdout)
    const body = JSON.parse(result.stdout)
    assert.equal(body.status, 'pass')
    assert.deepEqual(body.inspected, [])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('checks standalone short-story body file named 正文.md', () => {
  const root = makeBook()
  try {
    const body = path.join(root, '正文.md')
    writeFileSync(body, [
      '# 短篇正文',
      '',
      '她看着门外。',
      '他说：“该到下一章了，本章任务已经完成。”',
      '',
    ].join('\n'), 'utf8')

    const result = runGate(body)
    assert.equal(result.status, 2, result.stdout)
    const parsed = JSON.parse(result.stdout)
    assert.equal(parsed.status, 'fail')
    assert.deepEqual(parsed.inspected, ['正文.md'])
    assert.equal(parsed.findings.some(item => item.type === 'prose-meta-leak'), true)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
