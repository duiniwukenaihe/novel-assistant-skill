# book-state.sh — .book-state.json 读写工具（被 story-setup / session-start / story-explorer 共用）
# bash 3.2 兼容；不引入 jq 依赖；写入用 mktemp + mv 原子替换

book_state_path() {
    local project_root="$1"
    echo "${project_root}/.book-state.json"
}

book_state_exists() {
    local project_root="$1"
    [ -f "$(book_state_path "$project_root")" ]
}

book_state_get_field() {
    local project_root="$1"
    local field="$2"
    local file
    file="$(book_state_path "$project_root")"
    [ -f "$file" ] || return 1
    # 简单 awk 提取（不依赖 jq）；字段值若包含特殊字符需用 jq，此处仅处理字符串/数字
    awk -v field="$field" '
        {
            pattern = "\"" field "\"[[:space:]]*:[[:space:]]*"
            if (match($0, pattern)) {
                value = substr($0, RSTART + RLENGTH)
                sub(/^[[:space:]]*/, "", value)
                if (substr(value, 1, 1) == "\"") {
                    value = substr(value, 2)
                    sub(/".*$/, "", value)
                } else {
                    sub(/[[:space:],}].*$/, "", value)
                }
                print value
                exit
            }
        }
    ' "$file"
}

book_state_get_status() {
    local project_root="$1"
    book_state_get_field "$project_root" "status"
}

book_state_set_status() {
    local project_root="$1"
    local new_status="$2"
    local file
    file="$(book_state_path "$project_root")"
    [ -f "$file" ] || return 1
    # awk 替换 status 字段（保持其他字段不动）
    local tmp
    tmp="$(mktemp)"
    awk -v new_status="$new_status" '
        /"status"[[:space:]]*:/ {
            sub(/"status"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"status\": \"" new_status "\"")
        }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

book_state_set_chapter() {
    local project_root="$1"
    local chapter="$2"
    local file
    file="$(book_state_path "$project_root")"
    [ -f "$file" ] || return 1
    local tmp
    tmp="$(mktemp)"
    awk -v ch="$chapter" '
        /"currentChapter"[[:space:]]*:/ {
            sub(/"currentChapter"[[:space:]]*:[[:space:]]*[0-9]+/, "\"currentChapter\": " ch)
        }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}
