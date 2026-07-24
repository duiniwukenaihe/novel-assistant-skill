import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  buildShortSectionOutlineContract,
  renderOutlineCoverageTemplate,
  validateBriefOutlineCoverage,
  validateDraftOutlineCoverage,
} = require('../scripts/lib/short-section-outline-contract');
const { validateShortSectionAcceptanceProof } = require('../scripts/lib/short-section-acceptance-proof');

function projectWithSection7() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'short-outline-contract-'));
  fs.mkdirSync(path.join(root, '追踪/private-short-extension'), { recursive: true });
  fs.writeFileSync(path.join(root, '设定.md'), '# 设定\n- 叙事方式：第一人称\n- 主节奏：调查 -> 对抗 -> 公开纠错\n- 计划：共9节\n');
  fs.writeFileSync(path.join(root, '追踪/private-short-extension/project-state.json'), JSON.stringify({ narrative: { planned_sections: 9 }, current_section_index: 7 }));
  fs.writeFileSync(path.join(root, '小节大纲.md'), `# 小节大纲
## 第7节：妈妈用我的表决权沉默了三年
- 结构功能：将商业欺骗翻成家族对女主声音与权利的长期占用。
- 承接上节：哥哥摊开的旧账本迫使母亲解释父亲改标文件的去向。
- 场景动作：母亲拿出澄清声明和新委托书，女主当面核对父亲改标文件的日期。
- 子事件：
  1. 母亲被文件日期逼得承认父亲早已要求改标。
  2. 女主发现自己的表决权被用来证明全家支持哥哥。
  3. 母亲用员工去留换她签字，她假意出席第二场直播。
- 情绪目标：最后侥幸 -> 心寒 -> 冷静反制。
- 压力变化：家族解释转为以员工去留和表决权逼她沉默。
- 因果链：父亲文字出现 -> 母亲承认压下文件 -> 表决权用途曝光 -> 女主取得公开场域。
- 角色选择：她不提前提交撤回通知，但先把脱敏证据交给独立审查方。
- 可见阻力：母亲同时用亲情、员工去留和家族控制权逼她沉默。
- 本节兑现：母亲知情与表决权占用两条真相同时闭合。
- 关系变化：母女从还能谈判变为女主不再交出判断权。
- 代价升级：女主一旦公开纠错，将同时失去家庭保护与品牌职位。
- 节尾钩子：官方预告说她会还原事故真相，她却在另一台手机上设好实名直播。
`);
  return root;
}

test('Brief must preserve every confirmed outline obligation', () => {
  const root = projectWithSection7();
  const contract = buildShortSectionOutlineContract(root, 7);
  assert.equal(contract.status, 'current');
  assert.equal(contract.incoming_hook_anchor, 'H006');
  assert.equal(contract.outgoing_hook_anchor, 'H007');
  const template = renderOutlineCoverageTemplate(contract);
  assert.equal(validateBriefOutlineCoverage(template, contract).status, 'pass');
  const drifted = template.replace(/- P01：.*\n/u, '- P01：女主在记者会上意外得到外部证据。\n');
  const result = validateBriefOutlineCoverage(drifted, contract);
  assert.equal(result.status, 'blocked');
  assert.ok(result.findings.some((item) => item.code === 'outline_obligation_changed' && item.obligation_id === 'P01'));
});

test('Brief may express outline obligations naturally while the machine mapping stays in a sidecar', () => {
  const root = projectWithSection7();
  const contract = buildShortSectionOutlineContract(root, 7);
  const naturalBrief = [
    '# 第7节写作提要',
    ...contract.obligations.map((item) => `- ${item.source_text}`),
    '这些动作按因果顺序推进，最终停在邮件抄送栏出现母亲名字的钩子上。',
  ].join('\n');
  const result = validateBriefOutlineCoverage(naturalBrief, contract);
  assert.equal(result.status, 'pass');
  assert.equal(result.coverage_mode, 'semantic_sidecar');
  assert.equal(result.coverage.length, contract.obligations.length);
});

test('Brief may distribute one outline obligation across task beats and the ending hook', () => {
  const root = projectWithSection7();
  const contract = buildShortSectionOutlineContract(root, 7);
  const naturalBrief = `# 第7节写作提要

## 本节任务
- 哥哥摊开的旧账本逼母亲解释父亲改标文件去了哪里。
- 母亲拿出澄清声明和新委托书，我当面核对文件日期。
- 日期迫使她承认父亲早就要求改标，我的表决权却一直被拿来证明全家支持哥哥。
- 本节最终让母亲知情和表决权占用两条真相一起闭合。
- 她拿员工去留和亲情逼我签字，我表面答应出席第二场直播，先把脱敏证据交给独立审查方。

## 人物与代价
- 这次选择会让我失去家庭保护和品牌职位，母女关系也从谈判变成我不再交出判断权。

## 节尾钩子
- 官方预告说我会还原事故真相，我却在另一台手机上设好了实名直播。`;
  const result = validateBriefOutlineCoverage(naturalBrief, contract);
  assert.equal(result.status, 'pass', JSON.stringify(result));
  assert.equal(result.coverage_mode, 'semantic_sidecar');
});

test('story review quotes must exist in the candidate and cover all required obligations', () => {
  const root = projectWithSection7();
  const contract = buildShortSectionOutlineContract(root, 7);
  const required = contract.obligations.filter((item) => item.required_in_draft);
  const lines = required.map((item) => `证据${item.id}：这是本节中独立发生的可见动作。`);
  const draft = lines.join('\n');
  const review = {
    outline_contract_digest: contract.contract_digest,
    outline_coverage: required.map((item, index) => ({ id: item.id, status: 'pass', evidence_quote: lines[index] })),
  };
  assert.deepEqual(validateDraftOutlineCoverage(review, contract, draft), []);
  review.outline_coverage[0].evidence_quote = '正文里不存在的证据';
  assert.ok(validateDraftOutlineCoverage(review, contract, draft).some((item) => item.code === 'draft_outline_evidence_not_found'));
});

test('user confirmation protects legacy prose but never replaces current quality evidence', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'short-legacy-proof-'));
  fs.mkdirSync(path.join(root, '正文'), { recursive: true });
  fs.mkdirSync(path.join(root, '追踪/private-short-extension'), { recursive: true });
  const canonicalPath = '正文/第001节.md';
  const anchorPath = '追踪/private-short-extension/section-001-anchor.json';
  fs.writeFileSync(path.join(root, canonicalPath), '# 第1节\n\n我把证据放到桌上。\n');
  const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, canonicalPath))).digest('hex');
  const anchor = {
    workflow_id: 'wf-legacy', section_index: 1, status: 'accepted', canonical_path: canonicalPath, canonical_sha256: digest,
    quality_result: {
      machine_gate: 'pass', story_value_gate: 'pass', repetition_gate: 'legacy_migration_accepted',
      length_policy: { blocking: false, verdict: 'legacy_migration_accepted' },
    },
    migration_compatibility: { missing_v2_fields_marked: true, source_kind: 'legacy', user_confirmed: false },
  };
  fs.writeFileSync(path.join(root, anchorPath), JSON.stringify(anchor));
  const proof = { workflow_id: 'wf-legacy', section_index: 1, anchor_path: anchorPath, canonical_path: canonicalPath, canonical_sha256: digest };
  assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-legacy', proof }).code, 'short_section_legacy_quality_revalidation_required');
  anchor.migration_compatibility = { missing_v2_fields_marked: true, source_kind: 'user_confirmed', user_confirmed: true };
  fs.writeFileSync(path.join(root, anchorPath), JSON.stringify(anchor));
  assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-legacy', proof }).code, 'short_section_user_confirmed_quality_revalidation_required');
});
