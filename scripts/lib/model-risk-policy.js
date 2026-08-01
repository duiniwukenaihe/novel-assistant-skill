'use strict';

const FAMILY_PROFILES = Object.freeze({
  claude: profile('claude', 0.9, ['long_reasoning_drift', 'over_reading'], ['保持当前单元边界', '只读取受控上下文包']),
  openai: profile('openai', 0.9, ['scope_expansion', 'premature_completion'], ['复述当前交付边界后执行', '不得补做未选择阶段']),
  minimax: profile('minimax', 0.65, ['repetition_loop', 'tool_argument_drift', 'genre_term_fixation'], ['单次只处理一个制品', '重复短语命中后立即停在可信断点']),
  deepseek: profile('deepseek', 0.75, ['reasoning_leak', 'contrast_pattern_repetition', 'over_explanation'], ['结论优先', '限制不是X是Y等模板对比句']),
  glm: profile('glm', 0.7, ['selection_ambiguity', 'tool_argument_drift', 'context_replay'], ['数字选择必须绑定当前菜单', '工具失败后不得重放整段上下文']),
  unknown: profile('unknown', 0.7, ['unknown_model_variance'], ['采用保守上下文预算', '一次失败后停在检查点']),
});

function resolveModelRiskPolicy(input = {}) {
  const provider = clean(input.provider || process.env.NOVEL_ASSISTANT_PROVIDER || process.env.NOVEL_ASSISTANT_HOST || '');
  const model = clean(input.model || process.env.NOVEL_ASSISTANT_MODEL || process.env.ANTHROPIC_MODEL || process.env.CODEX_MODEL || process.env.ZCODE_MODEL || '');
  const family = detectFamily(`${provider} ${model}`);
  const selected = FAMILY_PROFILES[family] || FAMILY_PROFILES.unknown;
  return {
    schemaVersion: '1.0.0',
    family,
    provider: provider || 'unspecified',
    model: model || 'unspecified',
    context_budget_multiplier: selected.context_budget_multiplier,
    risks: selected.risks.slice(),
    prompt_directives: selected.prompt_directives.slice(),
    retry_budget: { same_failure: 1, same_tool_error: 1, provider_error: 1, on_exhausted: 'pause_at_checkpoint' },
    prose_policy: {
      unit_scope: 'single_section_or_current_stage',
      outline_fidelity_required: true,
      repetition_health_check: family === 'unknown' ? 'standard' : 'family_aware',
    },
  };
}

function detectFamily(value) {
  const text = String(value || '').toLowerCase();
  if (/minimax|abab/u.test(text)) return 'minimax';
  if (/deepseek/u.test(text)) return 'deepseek';
  if (/glm|zcode|zhipu|智谱/u.test(text)) return 'glm';
  if (/claude|anthropic/u.test(text)) return 'claude';
  if (/openai|gpt|codex|o[134](?:\b|-)/u.test(text)) return 'openai';
  return 'unknown';
}

function profile(family, contextBudgetMultiplier, risks, promptDirectives) {
  return { family, context_budget_multiplier: contextBudgetMultiplier, risks, prompt_directives: promptDirectives };
}

function clean(value) { return String(value || '').trim().slice(0, 160); }

module.exports = { FAMILY_PROFILES, detectFamily, resolveModelRiskPolicy };
