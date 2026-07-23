import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'

const repoRoot = path.resolve(import.meta.dirname, '..')

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

test('shared story load-bearing contract covers semantic quality without adding another runtime skill', () => {
  const contract = read('src/internal-skills/story-workflow/references/story-load-bearing-contract.md')
  for (const anchor of [
    '故事脊柱',
    '为什么不能轻易离开',
    '拖延代价',
    '揭示必须改变局面',
    '目标 -> 可见阻力 -> 主角选择 -> 后果/代价',
    '只读审阅',
    '字段名不同',
    '不得成为既定事实',
    '不规定固定章节数或固定字数',
  ]) {
    assert.match(contract, new RegExp(anchor.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }

  const consumers = [
    'src/internal-skills/story-workflow/SKILL.md',
    'src/internal-skills/story-long-write/SKILL.md',
    'src/internal-skills/story-short-write/SKILL.md',
    'src/internal-skills/story-review/SKILL.md',
  ]
  for (const consumer of consumers) {
    assert.match(read(consumer), /story-load-bearing-contract\.md/, consumer)
  }
})
