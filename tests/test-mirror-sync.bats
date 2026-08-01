#!/usr/bin/env bats

# Task P2.5: mirror-sync 测试
# 覆盖 codex 给的 5 条测试计划（拆为 6 个用例，含 idempotent）。
# 每个用例用 mktemp 构造隔离 fixture，不污染仓库。
# 注意：bats 1.x 把 @test 名字转成 bash 函数名，不支持中文，故名字用 ASCII，
#       中文语义写在注释里。

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MIRROR_SYNC="$REPO/scripts/lib/mirror-sync.js"
    [ -f "$MIRROR_SYNC" ] || skip "mirror-sync.js not implemented yet"

    FIXTURE="$(mktemp -d)"
    # 默认 fixture：source 含 2 个根脚本 + lib 子目录（含嵌套）+ native 子目录
    # + 1 个未列入 manifest 的构建脚本。
    SOURCE="$FIXTURE/source"
    MIRROR="$FIXTURE/mirror"
    mkdir -p "$SOURCE/lib/nested" "$SOURCE/native"
    printf '#!/usr/bin/env node\nconsole.log("run-a");\n' > "$SOURCE/run-a.js"
    printf '#!/bin/sh\necho b\n' > "$SOURCE/run-b.sh"
    printf 'module.exports = { lib: true };\n' > "$SOURCE/lib/helper.js"
    printf 'module.exports = { deep: true };\n' > "$SOURCE/lib/nested/deep.js"
    printf 'module.exports = { native: true };\n' > "$SOURCE/native/extra.js"
    # 未列入 manifest 的构建/审计脚本（不应进镜像）
    printf '#!/usr/bin/env node\n// build only\n' > "$SOURCE/build-audit.js"

    MANIFEST_FILE="$FIXTURE/manifest.json"
    cat > "$MANIFEST_FILE" <<'JSON'
{
  "scriptFiles": ["run-a.js", "run-b.sh"],
  "scriptDirectories": ["lib", "native"]
}
JSON
}

teardown() {
    if [ -n "${FIXTURE:-}" ] && [ -d "$FIXTURE" ]; then rm -rf "$FIXTURE"; fi
}

# 用 node 调 syncMirror，把返回的 audit 结果打印到 stdout（JSON）。
run_sync() {
    node - "$MIRROR_SYNC" "$SOURCE" "$MIRROR" "$MANIFEST_FILE" <<'NODE'
const mod = require(process.argv[2]);
const fs = require('fs');
const sourceDir = process.argv[3];
const mirrorDir = process.argv[4];
const manifest = JSON.parse(fs.readFileSync(process.argv[5], 'utf8'));
const result = mod.syncMirror({ sourceDir, mirrorDir, manifest });
process.stdout.write(JSON.stringify(result));
NODE
}

# 用 node 调 auditMirror，打印 audit 结果（JSON）。
run_audit() {
    node - "$MIRROR_SYNC" "$SOURCE" "$MIRROR" "$MANIFEST_FILE" <<'NODE'
const mod = require(process.argv[2]);
const fs = require('fs');
const sourceDir = process.argv[3];
const mirrorDir = process.argv[4];
const manifest = JSON.parse(fs.readFileSync(process.argv[5], 'utf8'));
const result = mod.auditMirror({ sourceDir, mirrorDir, manifest });
process.stdout.write(JSON.stringify(result));
NODE
}

# macOS stat 取 octal mode（低 9 位权限）。
mode_octal() {
    stat -f "%Lp" "$1" 2>/dev/null || stat -c "%a" "$1"
}

# 1) 验证 manifest 内文件及目录完整同步（内容一致）
@test "manifest entries fully synced with matching content" {
    run_sync
    # 根脚本同步且内容一致
    [ -f "$MIRROR/run-a.js" ]
    [ -f "$MIRROR/run-b.sh" ]
    cmp "$SOURCE/run-a.js" "$MIRROR/run-a.js"
    cmp "$SOURCE/run-b.sh" "$MIRROR/run-b.sh"
    # scriptDirectories 递归同步（含子目录）
    [ -f "$MIRROR/lib/helper.js" ]
    [ -f "$MIRROR/lib/nested/deep.js" ]
    [ -f "$MIRROR/native/extra.js" ]
    cmp "$SOURCE/lib/helper.js" "$MIRROR/lib/helper.js"
    cmp "$SOURCE/lib/nested/deep.js" "$MIRROR/lib/nested/deep.js"
    cmp "$SOURCE/native/extra.js" "$MIRROR/native/extra.js"
}

# 2) 未列入 manifest 的构建/审计脚本不进镜像
@test "scripts not listed in manifest are not mirrored" {
    run_sync
    [ ! -e "$MIRROR/build-audit.js" ]
    # 再跑一次确认 audit current
    result="$(run_audit)"
    echo "$result" | grep -q '"status":"current"'
}

# 3) 缺失/篡改/多余文件 -> audit drift 且 CLI 非零退出
@test "missing changed unexpected files cause audit drift and non-zero CLI exit" {
    run_sync

    # 1) 删 mirror 里某文件 -> missing
    rm "$MIRROR/lib/helper.js"
    result_missing="$(run_audit)"
    echo "$result_missing" | grep -q '"status":"drift"'
    echo "$result_missing" | grep -q '"missing":\["lib/helper.js"\]'

    # 2) 改 mirror 里某文件内容 -> changed
    printf 'tampered' > "$MIRROR/run-a.js"
    result_changed="$(run_audit)"
    echo "$result_changed" | grep -q '"status":"drift"'
    echo "$result_changed" | grep -q '"changed":\["run-a.js"\]'

    # 3) mirror 里加多余文件 -> unexpected
    printf 'junk' > "$MIRROR/stray.js"
    result_unexpected="$(run_audit)"
    echo "$result_unexpected" | grep -q '"status":"drift"'
    echo "$result_unexpected" | grep -q '"unexpected":\["stray.js"\]'

    # 4) CLI audit 模式 drift 时 exit 1
    run node "$MIRROR_SYNC" audit "$SOURCE" "$MIRROR" "$MANIFEST_FILE"
    [ "$status" -ne 0 ]
}

# 4) 顶层运行脚本保持可执行，lib/native 保持源权限
@test "top level scripts executable while lib dirs keep source perms" {
    # 源 lib/native 文件不给 x 位（只读），顶层脚本给 x 位
    chmod 644 "$SOURCE/lib/helper.js" "$SOURCE/native/extra.js"
    chmod 755 "$SOURCE/run-a.js" "$SOURCE/run-b.sh"

    run_sync

    # scriptFiles 同步后含 owner 可执行位（mode & 0o100 != 0）
    a_mode="$(mode_octal "$MIRROR/run-a.js")"
    b_mode="$(mode_octal "$MIRROR/run-b.sh")"
    [ $(( 8#$a_mode & 8#100 )) -ne 0 ]
    [ $(( 8#$b_mode & 8#100 )) -ne 0 ]

    # scriptDirectories 内文件保持源权限（644，无可执行位）
    h_mode="$(mode_octal "$MIRROR/lib/helper.js")"
    e_mode="$(mode_octal "$MIRROR/native/extra.js")"
    [ "$h_mode" = "644" ]
    [ "$e_mode" = "644" ]
}

# 5) 连续 sync 两次幂等（第二次无新增 diff）
@test "sync is idempotent across two consecutive runs" {
    run_sync
    first_audit="$(run_audit)"
    echo "$first_audit" | grep -q '"status":"current"'

    # 第二次 sync 后仍 current（无新增 diff，无多余改动）
    run_sync
    second_audit="$(run_audit)"
    echo "$second_audit" | grep -q '"status":"current"'
    [ "$first_audit" = "$second_audit" ]

    # CLI audit 模式应 exit 0
    run node "$MIRROR_SYNC" audit "$SOURCE" "$MIRROR" "$MANIFEST_FILE"
    [ "$status" -eq 0 ]
}

@test "manifest entries missing from source fail sync" {
    node - "$MANIFEST_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.scriptFiles.push('missing.js');
fs.writeFileSync(file, JSON.stringify(manifest));
NODE

    run node "$MIRROR_SYNC" sync "$SOURCE" "$MIRROR" "$MANIFEST_FILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing mirror source"* ]]
}

@test "sync removes files no longer managed by manifest" {
    run_sync
    printf 'stale' > "$MIRROR/stray.js"
    mkdir -p "$MIRROR/obsolete"
    printf 'stale' > "$MIRROR/obsolete/old.js"

    run_sync
    [ ! -e "$MIRROR/stray.js" ]
    [ ! -e "$MIRROR/obsolete/old.js" ]
    result="$(run_audit)"
    echo "$result" | grep -q '"status":"current"'
}

@test "manifest directory traversal is rejected" {
    node - "$MANIFEST_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.scriptDirectories = ['../outside'];
fs.writeFileSync(file, JSON.stringify(manifest));
NODE

    run node "$MIRROR_SYNC" audit "$SOURCE" "$MIRROR" "$MANIFEST_FILE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe scriptDirectories entry"* ]]
}

@test "source-only predicate excludes build tooling" {
    run node - "$MIRROR_SYNC" <<'NODE'
const { shouldMirror } = require(process.argv[2]);
if (shouldMirror('build-oh-story-bundle.sh')) throw new Error('build script must remain source-only');
if (!shouldMirror('workflow-runner.js')) throw new Error('runtime script must be mirrorable');
NODE
    [ "$status" -eq 0 ]
}
