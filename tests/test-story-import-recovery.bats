#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    IMPORT_SKILL="$REPO/src/internal-skills/story-import/SKILL.md"
}

@test "story import documents recovery without overwriting existing assets" {
    grep -q "导入故障自愈" "$IMPORT_SKILL"
    grep -q "文件系统是权威" "$IMPORT_SKILL"
    grep -q "分阶段恢复" "$IMPORT_SKILL"
    grep -q "自动修复类" "$IMPORT_SKILL"
    grep -q "外部阻断类" "$IMPORT_SKILL"
    grep -q "覆盖保护" "$IMPORT_SKILL"
    grep -q "已有正文、章名、细纲和设定默认不覆盖" "$IMPORT_SKILL"
}
