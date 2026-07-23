#!/bin/bash
# revision-impact-scan.sh — build a pre-edit impact report for longform rewrites.
set -u

usage() {
  echo "Usage: $0 <book-dir> <request-file>" >&2
  echo "Request fields: 修改对象, 修改类型, 修改原因, 关键词" >&2
}

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

field_value() {
  key="$1"
  file="$2"
  awk -v key="$key" '
    index($0, key "：") == 1 {
      sub("^[^：]*：", "")
      print
      exit
    }
    index($0, key ":") == 1 {
      sub("^[^:]*:", "")
      print
      exit
    }
  ' "$file" | trim
}

add_unique_line() {
  value="$1"
  file="$2"
  if [ -n "$value" ] && ! grep -qxF "$value" "$file" 2>/dev/null; then
    printf '%s\n' "$value" >> "$file"
  fi
}

classify_file() {
  rel="$1"
  scope="其他"
  impact="关键词命中，需人工判断影响"
  must_sync="否"

  case "$rel" in
    正文/*)
      scope="正文"
      impact="正文语义、情绪推进或事实呈现可能变化"
      must_sync="是"
      ;;
    大纲/细纲_*)
      scope="细纲"
      impact="章节 beat、禁止事项或线索设计可能变化"
      must_sync="是"
      ;;
    大纲/*)
      scope="大纲"
      impact="卷目标、主线推进或章节顺序可能变化"
      must_sync="是"
      ;;
    追踪/上下文.md)
      scope="上下文"
      impact="State Delta 或当前写作上下文需要同步"
      must_sync="是"
      ;;
    追踪/伏笔.md)
      scope="伏笔"
      impact="伏笔埋设、回收时机或后续动作需要同步"
      must_sync="是"
      ;;
    追踪/时间线.md)
      scope="时间线"
      impact="事件顺序和因果链需要同步"
      must_sync="是"
      ;;
    追踪/章节契约/*)
      scope="章节契约"
      impact="Chapter Contract 的必须 beat 或禁止事项需要复核"
      must_sync="是"
      ;;
    追踪/漂移门控/*)
      scope="漂移门控"
      impact="Plot Drift Gate 需要重跑并更新证据"
      must_sync="是"
      ;;
    追踪/*)
      scope="追踪"
      impact="追踪账可能需要同步"
      must_sync="是"
      ;;
    设定/角色不变量/*)
      scope="角色不变量"
      impact="角色动机、红线或认知边界可能被影响"
      must_sync="是"
      ;;
    设定/*)
      scope="设定"
      impact="世界观、角色或事实库可能需要同步"
      must_sync="是"
      ;;
  esac
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

if [ ! -d "$1" ]; then
  echo "FAIL: book dir not found: $1" >&2
  exit 2
fi

if [ ! -f "$2" ]; then
  echo "FAIL: request file not found: $2" >&2
  exit 2
fi

book_dir="$(cd "$1" && pwd)"
request_file="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

target="$(field_value "修改对象" "$request_file")"
change_type="$(field_value "修改类型" "$request_file")"
reason="$(field_value "修改原因" "$request_file")"
keywords="$(field_value "关键词" "$request_file")"

if [ -z "$target" ] || [ -z "$keywords" ]; then
  echo "FAIL: request must include 修改对象 and 关键词" >&2
  usage
  exit 2
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

candidates="$tmp_dir/candidates"
risks="$tmp_dir/risks"
: > "$candidates"
: > "$risks"

add_unique_line "$target" "$candidates"

for keyword in $keywords; do
  for dir in 正文 大纲 追踪 设定; do
    if [ -d "$book_dir/$dir" ]; then
      matches="$(grep -RIl -- "$keyword" "$book_dir/$dir" 2>/dev/null || true)"
      if [ -n "$matches" ]; then
        printf '%s\n' "$matches" | while IFS= read -r match; do
          rel="${match#$book_dir/}"
          add_unique_line "$rel" "$candidates"
        done
      fi
    fi
  done
done

if printf '%s\n' "$change_type" | grep -q "新增"; then
  add_unique_line "Untracked_Addition" "$risks"
fi

if printf '%s\n' "$change_type" | grep -q "删除伏笔\|删除线索\|提前回收"; then
  add_unique_line "Foreshadow_Early_Payoff" "$risks"
fi

while IFS= read -r rel; do
  case "$rel" in
    正文/*|追踪/*)
      add_unique_line "State_Not_Updated" "$risks"
      ;;
    设定/*)
      add_unique_line "Canon_Conflict" "$risks"
      ;;
  esac
done < "$candidates"

if [ ! -s "$risks" ]; then
  add_unique_line "需人工复核" "$risks"
fi

risk_codes="$(sort -u "$risks" | awk 'BEGIN { text = "" } { if (text != "") text = text ", "; text = text $0 } END { print text }')"

echo "## Revision Impact Analysis"
echo
echo "### 修改请求"
echo "- 修改对象：$target"
echo "- 修改类型：${change_type:-未填写}"
echo "- 修改原因：${reason:-未填写}"
echo "- 关键词：$keywords"
echo
echo "### 影响范围"
echo "| 范围 | 文件 | 影响 | 必须同步 |"
echo "|---|---|---|---|"
sort -u "$candidates" | while IFS= read -r rel; do
  classify_file "$rel"
  echo "| $scope | $rel | $impact | $must_sync |"
done
echo
echo "### 风险"
echo "- 主线风险：修改可能改变章节 beat 与卷目标的服务关系。"
echo "- 角色风险：命中角色设定或角色不变量时，需复核动机、红线和认知边界。"
echo "- 伏笔风险：删除或提前回收线索时，需同步伏笔表、时间线和后续章节契约。"
echo "- 状态风险：正文事实改变后，必须更新 State Delta，否则标记 State_Not_Updated。"
echo "- 风险码：$risk_codes"
echo
echo "### 建议执行顺序"
echo "1. 复核目标正文对应的 Chapter Contract 与细纲，确认必须 beat、禁止事项和修改边界。"
echo "2. 按修改请求更新正文或设定，只处理影响分析列出的范围。"
echo "3. 同步伏笔、时间线、上下文与角色不变量等追踪文件。"
echo "4. 重新运行 Plot Drift Gate，确认 Plot_Drift、Beat_Missing、State_Not_Updated 未出现。"
echo "5. 写入新的 State Delta，再进入下一章写作。"
