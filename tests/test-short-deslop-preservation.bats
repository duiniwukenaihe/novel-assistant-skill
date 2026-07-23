#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "small expression cleanup keeps the story ready without forcing padding" {
  run node - "$REPO/scripts/lib/short-deslop-preservation.js" <<'NODE'
const {preservationCheck}=require(process.argv[2]);
const section=(n,body)=>`## 第${n}节 标题\n\n${body}\n`;
const source=section(1,'人物行动现实反应剧情后果'.repeat(100)+'其实'.repeat(20))+section(2,'冲突升级人物选择跨节承接'.repeat(100)+'其实'.repeat(20));
const revised=section(1,'人物行动现实反应剧情后果'.repeat(100))+section(2,'冲突升级人物选择跨节承接'.repeat(100));
const out=preservationCheck(source,revised);
if(out.status!=='pass'||out.blocking) throw new Error(JSON.stringify(out));
if(out.after_cjk_chars>=out.before_cjk_chars) throw new Error('fixture did not shrink');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "material loss in multiple sections requires targeted story restoration" {
  run node - "$REPO/scripts/lib/short-deslop-preservation.js" <<'NODE'
const {preservationCheck}=require(process.argv[2]);
const section=(n,body)=>`## 第${n}节 标题\n\n${body}\n`;
const source=section(1,'人物行动现实反应剧情后果'.repeat(150))+section(2,'冲突升级人物选择跨节承接'.repeat(150));
const revised=section(1,'人物行动'.repeat(40))+section(2,'冲突升级'.repeat(40));
const out=preservationCheck(source,revised);
if(out.status!=='revision_required'||!out.blocking) throw new Error(JSON.stringify(out));
if(!out.findings.some(row=>row.code==='section_material_loss')||!out.findings.some(row=>row.code==='whole_story_material_loss')) throw new Error(JSON.stringify(out.findings));
if(!out.repair_principle.includes('不按差额机械补字')) throw new Error(out.repair_principle);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an explicit structural exception is recorded instead of pretending the loss passed" {
  run node - "$REPO/scripts/lib/short-deslop-preservation.js" <<'NODE'
const {preservationCheck}=require(process.argv[2]);
const section=(n,body)=>`## 第${n}节 标题\n\n${body}\n`;
const source=section(1,'人物行动现实反应剧情后果'.repeat(150))+section(2,'冲突升级人物选择跨节承接'.repeat(150));
const revised=section(1,'人物行动'.repeat(40))+section(2,'冲突升级'.repeat(40));
const out=preservationCheck(source,revised,{exceptionReason:'作者确认删除重复回忆场景并保留全部关键后果'});
if(out.status!=='explicit_exception'||out.blocking||!out.exception_reason) throw new Error(JSON.stringify(out));
if(!out.findings.length) throw new Error('exception must retain findings as evidence');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "public and private short workflow descriptions require post-deslop preservation" {
  run node - "$REPO/scripts/lib/workflow-template-registry.js" "$REPO/src/private-internal-skills/private-short-extension/workflow-registry.json" <<'NODE'
const registry=require(process.argv[2]),fs=require('fs');
const pub=Object.fromEntries(registry.BASE_TEMPLATES.short_write.stages.map(row=>[row.stage_id,row]));
const privTemplate=JSON.parse(fs.readFileSync(process.argv[3],'utf8')).workflow_templates.find(row=>row.workflow_type==='short_write');
const priv=Object.fromEntries(privTemplate.stages.map(row=>[row.stage_id,row]));
if(!pub.deslop.description.includes('不按字数差额机械灌水')) throw new Error(pub.deslop.description);
if(!priv.short_deslop.description.includes('不按差额机械补字')) throw new Error(priv.short_deslop.description);
if(!pub.final_check.description.includes('保真回执')||!priv.final_check.description.includes('保真回执')) throw new Error('final check preservation missing');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
