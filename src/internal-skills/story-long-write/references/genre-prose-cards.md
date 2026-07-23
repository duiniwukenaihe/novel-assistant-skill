# 按需题材正文卡

本文件定义长篇正文的轻量题材卡协议。它不是卡库：每次只从项目已确认的题材和当前章节 Brief 生成一张卡，不维护或加载 30+ 张预制卡。

## 生成与选择

1. 读取 `设定/题材定位.md` 的主题材、副题材、平台、目标读者情绪和已确认卖点。
2. 读取当前章的 Chapter Contract、逐章 Brief；有分节时读取每节 Brief。
3. 主题材决定卡的场景压力和读者承诺；副题材最多补一个限制，不与主题材轮流抢叙事主导。
4. 未确认题材时使用项目的情绪、人物关系和场景事实生成临时卡，标记待确认；不得默认代入修真、仙侠或其他常见题材词。

## 单张卡格式

```text
genre_prose_card:
  profile: <由项目题材动态得出>
  scene_pressure: <谁想做什么，谁或什么阻止他>
  reader_promise: <本节要交付的期待、关系变化、信息变化或风险>
  visible_actions: <2-4 个可被角色经历的动作/反应>
  language_boundary: <项目文风、角色口吻和题材氛围的交集>
  avoid: <与本章承诺冲突的解释、串味或模板化写法>
```

## 使用边界

- 只把当前的单张题材正文卡传给 narrative-writer；不得把全文卡库注入 prompt。
- 卡必须服从 Chapter Contract、Context Pack、人物不变量、用户硬约束和 canonical chapter-commit 事务；卡不能授权新增剧情或跨章扩写。
- 卡片的字段、卡名、题材分析、来源样本、合规自评均是写作元信息，不得泄漏到小说正文。
- 写后由长篇节奏门按逐章 Brief / 每节 Brief 验证场景推进；卡只帮助落地，不代替 Plot Drift Gate、State Delta 或 Handoff。
