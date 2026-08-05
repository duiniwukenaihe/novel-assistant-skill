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
## 第7节：主管用我的签字权掩盖了三年
- 结构功能：将记录差异翻成部门对复核员判断权的长期占用。
- 承接上节：审计员摊开的旧台账迫使主管解释前任留下的纠错文件去向。
- 场景动作：主管拿出澄清声明和新授权书，女主当面核对纠错文件的日期。
- 子事件：
  1. 主管被文件日期逼得承认前任早已要求纠错。
  2. 女主发现自己的签字权被用来证明全组支持旧结论。
  3. 主管用同事去留换她签字，她假意出席第二场复核会。
- 情绪目标：最后侥幸 -> 心寒 -> 冷静反制。
- 压力变化：内部解释转为以同事去留和签字权逼她沉默。
- 因果链：前任批注出现 -> 主管承认压下文件 -> 签字权用途曝光 -> 女主取得公开场域。
- 角色选择：她不提前提交撤回通知，但先把脱敏证据交给独立审查方。
- 可见阻力：主管同时用旧情、同事去留和部门权限逼她沉默。
- 本节兑现：主管知情与签字权占用两条真相同时闭合。
- 关系变化：上下级从还能谈判变为女主不再交出判断权。
- 代价升级：女主一旦公开纠错，将同时失去部门保护与复核职位。
- 节尾钩子：官方预告说她会还原事故真相，她却已把公开复核申请交给独立审查方。
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
    '这些动作按因果顺序推进，最终停在邮件抄送栏出现主管名字的钩子上。',
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
- 审计员摊开的旧台账逼主管解释前任纠错文件去了哪里。
- 主管拿出澄清声明和新授权书，我当面核对文件日期。
- 日期迫使他承认前任早就要求纠错，我的签字权却一直被拿来证明全组支持旧结论。
- 本节最终让主管知情和签字权占用两条真相一起闭合。
- 他拿同事去留和旧情逼我签字，我表面答应出席第二场复核会，先把脱敏证据交给独立审查方。

## 人物与代价
- 这次选择会让我失去部门保护和复核职位，上下级关系也从谈判变成我不再交出判断权。

## 节尾钩子
- 官方预告说我会还原事故真相，我却已经把公开复核申请交给独立审查方。`;
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
