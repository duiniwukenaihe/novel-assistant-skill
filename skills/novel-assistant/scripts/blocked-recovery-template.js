#!/usr/bin/env node
// blocked-recovery-template.js
// Emits short, deterministic recovery replies for blocked workflow states.

const STATUSES = {
  blocked_model_degradation: {
    title: '已暂停：检测到输出健康异常',
    state: '当前任务已停在最后可信断点，未继续写入正文或报告。',
    reason: '模型或上下文可能开始复读、乱码、夹带工程词或长时间空转。继续硬跑容易浪费上下文成本，并把坏内容写进报告。',
    recommendation: '推荐选 1：缩小范围继续。比如先处理当前批次的一小段，验证通过后再回到原范围。',
    options: ['缩小范围继续', '重新复检当前断点后继续', '只保存诊断', '取消当前任务'],
  },
  blocked_tool_command_contaminated: {
    title: '已暂停：检测到工具调用污染',
    state: '已丢弃污染调用，准备从文件系统事实和当前任务状态重建。',
    options: ['自动重建一次干净调用', '只保存恢复记录', '查看阻断原因', '取消当前任务'],
  },
  blocked_repeated_tool_failure: {
    title: '已暂停：同一工具连续失败',
    state: '已停止重复调用，避免继续消耗上下文。',
    options: ['缩小范围重试', '改用脚本方式处理', '只保存诊断', '取消当前任务'],
  },
  blocked_provider_sensitive: {
    title: '已暂停：供应商输出安全拦截',
    state: '已保留最后可信断点，不会原样重试被拦截内容。',
    options: ['降低描写尺度继续', '跳过敏感段保留因果', '只保存诊断', '取消当前任务'],
  },
};

function parseArgs(argv) {
  const args = { status: '', json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--status') {
      args.status = argv[++i] || '';
    } else if (arg === '--json') {
      args.json = true;
    } else if (arg === '--help' || arg === '-h') {
      usage();
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${arg}`);
      usage();
      process.exit(2);
    }
  }
  return args;
}

function usage() {
  console.error('Usage: blocked-recovery-template.js --status blocked_model_degradation [--json]');
}

function buildTemplate(status) {
  const spec = STATUSES[status] || {
    title: '已暂停：任务需要恢复',
    state: '已保存最后可信断点，等待选择下一步。',
    reason: '当前流程需要先确认恢复方式，避免误执行旧候选。',
    recommendation: '推荐选 1：继续前先复检。',
    options: ['继续前先复检', '只保存诊断', '取消当前任务'],
  };
  const lines = [
    spec.title,
    '',
    spec.state,
    '',
    `为什么暂停：${spec.reason}`,
    `建议：${spec.recommendation}`,
    '',
    '下一步：',
    ...spec.options.map((option, index) => `${index + 1}. ${option}`),
    '',
    '请回复 1/2/3/4。不要只回复“继续”，除非你想执行选项 1。',
    '也可以直接输入你的具体要求。',
  ];
  return { status, title: spec.title, options: spec.options, text: lines.join('\n') };
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.status) {
    usage();
    process.exit(2);
  }
  const template = buildTemplate(args.status);
  process.stdout.write(args.json ? `${JSON.stringify(template, null, 2)}\n` : `${template.text}\n`);
}

if (require.main === module) main();

module.exports = { buildTemplate };
