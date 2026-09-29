#!/usr/bin/env bash
# ============================================================
# packaging/build_deb.sh - 单元测试
# ============================================================
# 运行方式:
#   ./packaging/test_build_deb.sh
#
# 说明:
#   - 纯 bash 自包含测试框架，无第三方依赖
#   - 覆盖 build_deb.sh 中全部函数的正常路径、边界条件与错误路径
#   - dpkg-deb 缺失时，端到端构建用例自动跳过（SKIP）
#   - 全部通过时退出码为 0，否则为 1
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_SCRIPT="$SCRIPT_DIR/build_deb.sh"

# shellcheck source=packaging/build_deb.sh
source "$BUILD_SCRIPT"

# ============================================================
# 测试框架
# ============================================================
PASS=0
FAIL=0
SKIP=0
CURRENT_TEST=""
TMP_DIRS=()

cleanup_tmp() {
    local d
    for d in "${TMP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
    return 0
}
trap cleanup_tmp EXIT

new_tmp() {
    local d
    d="$(mktemp -d)"
    TMP_DIRS+=("$d")
    echo "$d"
}

assert_eq() { # $1: 期望值  $2: 实际值  $3: 说明
    if [[ "$1" == "$2" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ [$CURRENT_TEST] $3: 期望 '$1'，实际 '$2'"
    fi
}

assert_contains() { # $1: 内容  $2: 子串  $3: 说明
    if [[ "$1" == *"$2"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ [$CURRENT_TEST] $3: 未找到 '$2'"
    fi
}

assert_not_contains() { # $1: 内容  $2: 子串  $3: 说明
    if [[ "$1" != *"$2"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ [$CURRENT_TEST] $3: 不应包含 '$2'"
    fi
}

assert_rc() { # $1: 期望退出码(0/非0 用 nonzero)  $2: 实际退出码  $3: 说明
    if [[ "$1" == "nonzero" ]]; then
        if (( $2 != 0 )); then PASS=$((PASS + 1)); else
            FAIL=$((FAIL + 1)); echo "  ❌ [$CURRENT_TEST] $3: 期望失败但返回 0"
        fi
    else
        assert_eq "$1" "$2" "$3"
    fi
}

assert_file_exists() { # $1: 路径  $2: 说明
    if [[ -f "$1" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ [$CURRENT_TEST] $2: 文件不存在 $1"
    fi
}

assert_dir_exists() { # $1: 路径  $2: 说明
    if [[ -d "$1" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  ❌ [$CURRENT_TEST] $2: 目录不存在 $1"
    fi
}

assert_file_mode() { # $1: 路径  $2: 期望八进制权限  $3: 说明
    local m=""
    [[ -e "$1" ]] && m="$(stat -c '%a' "$1" 2>/dev/null)"
    assert_eq "$2" "$m" "$3"
}

skip_test() { # $1: 原因
    SKIP=$((SKIP + 1))
    echo "  ⏭️  [$CURRENT_TEST] 跳过: $1"
}

run_test() { # $1: 测试名  其余: 测试函数
    CURRENT_TEST="$1"
    shift
    echo "▶ $CURRENT_TEST"
    "$@"
}

# ============================================================
# 夹具（fixture）：最小项目结构
# ============================================================
make_fixture() {
    # 生成一个满足打包要求的最小项目，输出根目录路径
    local root
    root="$(new_tmp)"
    mkdir -p "$root/src" "$root/assets"
    cat > "$root/src/__init__.py" <<'EOF'
"""测试夹具包"""
__version__ = "9.8.7"
EOF
    cat > "$root/src/main.py" <<'EOF'
print("fixture main")
EOF
    cat > "$root/requirements.txt" <<'EOF'
Pillow==11.1.0
EOF
    cat > "$root/LICENSE" <<'EOF'
MIT License

Copyright (c) 2026 Test
EOF
    # 合成 PNG: 签名 + IHDR(13) + 宽 128 / 高 64（宽高不同以便发现顺序错误）
    printf '\211PNG\r\n\032\n\000\000\000\015IHDR\000\000\000\200\000\000\000\100\010\006\000\000\000' \
        > "$root/assets/icon.png"
    cat > "$root/assets/icon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"/>
EOF
    echo "$root"
}

make_staging() {
    new_tmp
}

# ============================================================
# read_version / validate_version
# ============================================================
test_read_version_ok() {
    local root version
    root="$(make_fixture)"
    version="$(read_version "$root/src/__init__.py")"
    assert_eq "9.8.7" "$version" "应解析 __version__"
}

test_read_version_real_project() {
    local version
    version="$(read_version "$PROJECT_ROOT/src/__init__.py")"
    assert_eq "2.0.0" "$version" "应解析真实项目版本号"
}

test_read_version_missing_file() {
    local out rc
    out="$(read_version "/nonexistent/__init__.py" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "文件不存在应失败"
    assert_contains "$out" "未找到" "应输出缺失文件错误"
}

test_read_version_no_field() {
    local root out rc
    root="$(new_tmp)"
    echo "x = 1" > "$root/__init__.py"
    out="$(read_version "$root/__init__.py" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "无 __version__ 字段应失败"
    assert_contains "$out" "__version__" "错误信息应提及 __version__"
}

test_read_version_invalid_value() {
    local root out rc
    root="$(new_tmp)"
    echo '__version__ = "v1.0 beta"' > "$root/__init__.py"
    out="$(read_version "$root/__init__.py" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "非法版本号应失败"
    assert_contains "$out" "非法版本号" "应输出非法版本号错误"
}

test_validate_version() {
    validate_version "2.0.0";        assert_rc 0 $? "2.0.0 合法"
    validate_version "1.0";          assert_rc 0 $? "1.0 合法"
    validate_version "2.0.0+dfsg";   assert_rc 0 $? "+dfsg 合法"
    validate_version "1.0~rc1";      assert_rc 0 $? "~rc1 合法"
    validate_version "";             assert_rc nonzero $? "空串非法"
    validate_version "v1.0";         assert_rc nonzero $? "字母开头非法"
    validate_version "1.0 beta";     assert_rc nonzero $? "含空格非法"
    validate_version "1.0_1";        assert_rc nonzero $? "含下划线非法"
}

# ============================================================
# read_png_size
# ============================================================
test_read_png_size_ok() {
    local root size
    root="$(make_fixture)"
    size="$(read_png_size "$root/assets/icon.png")"
    assert_eq "128x64" "$size" "应解析 PNG 宽高（顺序正确）"
}

test_read_png_size_real_icon() {
    local size
    size="$(read_png_size "$PROJECT_ROOT/assets/icon.png")"
    assert_eq "128x128" "$size" "真实图标应为 128x128"
}

test_read_png_size_not_png() {
    local root out rc
    root="$(new_tmp)"
    echo "this is not a png file at all, just plain text" > "$root/fake.png"
    out="$(read_png_size "$root/fake.png" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "非 PNG 应失败"
    assert_contains "$out" "不是有效的 PNG" "应输出格式错误"
}

test_read_png_size_truncated() {
    local root out rc
    root="$(new_tmp)"
    printf '\211PNG\r\n' > "$root/short.png"
    out="$(read_png_size "$root/short.png" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "过短文件应失败"
    assert_contains "$out" "过短" "应输出文件过短错误"
}

test_read_png_size_missing_file() {
    local out rc
    out="$(read_png_size "/nonexistent/icon.png" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "文件不存在应失败"
    assert_contains "$out" "未找到" "应输出缺失文件错误"
}

test_read_png_size_bad_ihdr() {
    local root out rc
    root="$(new_tmp)"
    # 合法签名但第一个块不是 IHDR
    printf '\211PNG\r\n\032\n\000\000\000\015XXXX\000\000\000\200\000\000\000\100' \
        > "$root/bad.png"
    out="$(read_png_size "$root/bad.png" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "缺少 IHDR 应失败"
    assert_contains "$out" "IHDR" "应输出 IHDR 错误"
}

# ============================================================
# generate_control
# ============================================================
test_generate_control() {
    local staging content
    staging="$(make_staging)"
    generate_control "$staging" "9.8.7" "all" "Tester <t@example.com>"
    assert_file_exists "$staging/DEBIAN/control" "control 文件应生成"
    content="$(cat "$staging/DEBIAN/control")"
    assert_contains "$content" "Package: weather-widget" "Package 字段"
    assert_contains "$content" "Version: 9.8.7" "Version 字段"
    assert_contains "$content" "Architecture: all" "Architecture 字段"
    assert_contains "$content" "Maintainer: Tester <t@example.com>" "Maintainer 字段"
    assert_contains "$content" "Depends: python3 (>= 3.8), python3-tk" "Depends 字段"
    assert_contains "$content" "Recommends: python3-pil" "Recommends 字段"
    assert_contains "$content" "Section: utils" "Section 字段"
    assert_contains "$content" "Priority: optional" "Priority 字段"
    assert_contains "$content" "Homepage: https://gitee.com/vghxug/weather-widget" "Homepage 字段"
    assert_contains "$content" "Description: 多城市桌面天气小工具" "Description 摘要"
    assert_file_mode "$staging/DEBIAN/control" "644" "control 权限应为 644"
    # Description 长描述行必须以空格开头（Debian 控制文件规范）
    local line
    while IFS= read -r line; do
        if [[ "$line" == "支持多城市同屏"* ]]; then
            assert_eq " " "${line:0:1}" "长描述行应以空格开头"
        fi
    done <<< "$content"
}

# ============================================================
# generate_launcher
# ============================================================
test_generate_launcher() {
    local staging content
    staging="$(make_staging)"
    generate_launcher "$staging"
    assert_file_exists "$staging/usr/bin/weather-widget" "启动器应生成"
    content="$(cat "$staging/usr/bin/weather-widget")"
    assert_contains "$content" "#!/bin/sh" "shebang 应为 /bin/sh"
    assert_contains "$content" 'exec python3 /usr/lib/weather-widget/src/main.py "$@"' "应转发参数并 exec 主程序"
    assert_file_mode "$staging/usr/bin/weather-widget" "755" "启动器权限应为 755"
}

# ============================================================
# generate_desktop
# ============================================================
test_generate_desktop() {
    local staging content
    staging="$(make_staging)"
    generate_desktop "$staging"
    local f="$staging/usr/share/applications/weather-widget.desktop"
    assert_file_exists "$f" "desktop 文件应生成"
    content="$(cat "$f")"
    assert_contains "$content" "[Desktop Entry]" "应含 Desktop Entry 头"
    assert_contains "$content" "Type=Application" "Type 字段"
    assert_contains "$content" "Name=天气小工具" "Name 字段"
    assert_contains "$content" "Exec=weather-widget" "Exec 字段"
    assert_contains "$content" "Icon=weather-widget" "Icon 字段"
    assert_contains "$content" "Terminal=false" "Terminal 字段"
    assert_contains "$content" "Categories=Utility;Weather;" "Categories 字段"
    assert_file_mode "$f" "644" "desktop 文件权限应为 644"
}

# ============================================================
# generate_maintainer_scripts
# ============================================================
test_generate_maintainer_scripts() {
    local staging content
    staging="$(make_staging)"
    generate_maintainer_scripts "$staging"
    local s
    for s in postinst postrm; do
        assert_file_exists "$staging/DEBIAN/$s" "$s 应生成"
        assert_file_mode "$staging/DEBIAN/$s" "755" "$s 权限应为 755"
        content="$(cat "$staging/DEBIAN/$s")"
        assert_contains "$content" "#!/bin/sh" "$s shebang"
        assert_contains "$content" "set -e" "$s 应启用 set -e"
        assert_contains "$content" "gtk-update-icon-cache" "$s 应刷新图标缓存"
        assert_contains "$content" "update-desktop-database" "$s 应刷新桌面数据库"
        assert_contains "$content" "exit 0" "$s 应正常退出"
    done
}

# ============================================================
# write_changelog / generate_changelog
# ============================================================
test_write_changelog() {
    local staging out content
    staging="$(make_staging)"
    out="$staging/changelog"
    SOURCE_DATE_EPOCH=1700000000 write_changelog "$out" "9.8.7" "Tester <t@example.com>"
    assert_file_exists "$out" "changelog 文件应生成"
    content="$(cat "$out")"
    assert_contains "$content" "weather-widget (9.8.7) unstable; urgency=low" "首行应为包名 (版本) 发行版; urgency"
    assert_contains "$content" "  * " "应含以两空格加星号开头的变更条目"
    assert_contains "$content" " -- Tester <t@example.com>  Tue, 14 Nov 2023 22:13:20 +0000" \
        "尾行应为 ' -- 维护者  两个空格 RFC2822 时间'"
    assert_file_mode "$out" "644" "changelog 权限应为 644"
    # 结构校验：头行、空行、条目、空行、尾行（Debian changelog 规范）
    local head_line blank_ok
    head_line="$(head -n 1 "$out")"
    assert_eq "weather-widget (9.8.7) unstable; urgency=low" "$head_line" "第一行必须是 changelog 头"
    blank_ok="$(sed -n '2p;4p' "$out" | grep -c '^$')"
    assert_eq "2" "$blank_ok" "头行与尾行前必须是空行"
}

test_write_changelog_source_date_epoch() {
    local staging out content
    staging="$(make_staging)"
    out="$staging/changelog"
    SOURCE_DATE_EPOCH=0 write_changelog "$out" "1.0" "T <t@e.com>"
    content="$(cat "$out")"
    assert_contains "$content" "Thu, 01 Jan 1970 00:00:00 +0000" "SOURCE_DATE_EPOCH=0 应输出固定 UTC 时间"
}

test_generate_changelog() {
    local staging content
    staging="$(make_staging)"
    SOURCE_DATE_EPOCH=1700000000 generate_changelog "$staging" "9.8.7" "Tester <t@example.com>"
    assert_file_exists "$staging/DEBIAN/changelog" "DEBIAN/changelog 应生成"
    content="$(cat "$staging/DEBIAN/changelog")"
    assert_contains "$content" "weather-widget (9.8.7) unstable; urgency=low" "应含包名与版本"
    assert_contains "$content" " -- Tester <t@example.com>  " "应含维护者与两空格分隔"
    assert_file_mode "$staging/DEBIAN/changelog" "644" "DEBIAN/changelog 权限应为 644"
}

test_generate_changelog_creates_debian_dir() {
    local staging
    staging="$(make_staging)"
    rm -rf "$staging/DEBIAN"
    SOURCE_DATE_EPOCH=0 generate_changelog "$staging" "1.0" "T <t@e.com>"
    assert_rc 0 $? "DEBIAN 目录缺失时应自动创建"
    assert_dir_exists "$staging/DEBIAN" "DEBIAN 目录应被创建"
    assert_file_exists "$staging/DEBIAN/changelog" "changelog 应生成于 DEBIAN 下"
}

test_changelog_debian_matches_doc() {
    # DEBIAN/changelog 与 usr/share/doc 下 changelog.gz 内容应完全一致
    local root staging deb_ch doc_ch
    root="$(make_fixture)"
    staging="$(make_staging)"
    SOURCE_DATE_EPOCH=1700000000 generate_changelog "$staging" "9.8.7" "Tester <t@example.com>"
    SOURCE_DATE_EPOCH=1700000000 generate_doc "$staging" "$root" "9.8.7" "Tester <t@example.com>"
    deb_ch="$(cat "$staging/DEBIAN/changelog")"
    doc_ch="$(gzip -dc "$staging/usr/share/doc/weather-widget/changelog.gz")"
    assert_eq "$deb_ch" "$doc_ch" "DEBIAN/changelog 与文档 changelog 内容应一致"
}

# ============================================================
# generate_doc / changelog_date
# ============================================================
test_generate_doc() {
    local root staging
    root="$(make_fixture)"
    staging="$(make_staging)"
    generate_doc "$staging" "$root" "9.8.7" "Tester <t@example.com>"
    local doc="$staging/usr/share/doc/weather-widget"
    assert_file_exists "$doc/copyright" "copyright 应生成"
    assert_contains "$(cat "$doc/copyright")" "MIT License" "copyright 应来自 LICENSE"
    assert_file_exists "$doc/changelog.gz" "changelog.gz 应生成"
    local changelog
    changelog="$(gzip -dc "$doc/changelog.gz")"
    assert_contains "$changelog" "weather-widget (9.8.7)" "changelog 应含包名与版本"
    assert_contains "$changelog" "-- Tester <t@example.com>" "changelog 应含维护者"
}

test_generate_doc_missing_license() {
    local root staging out rc
    root="$(new_tmp)"
    staging="$(make_staging)"
    out="$(generate_doc "$staging" "$root" "1.0" "T <t@e.com>" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "缺少 LICENSE 应失败"
    assert_contains "$out" "LICENSE" "错误信息应提及 LICENSE"
}

test_changelog_date_source_date_epoch() {
    local d
    d="$(SOURCE_DATE_EPOCH=0 changelog_date)"
    assert_eq "Thu, 01 Jan 1970 00:00:00 +0000" "$d" "SOURCE_DATE_EPOCH=0 应输出固定 UTC 时间"
    d="$(changelog_date)"
    assert_rc 0 $? "默认应输出当前时间"
    assert_contains "$d" "+" "RFC2822 时间应含时区"
}

# ============================================================
# stage_payload
# ============================================================
test_stage_payload() {
    local root staging
    root="$(make_fixture)"
    # 混入应被清理的缓存文件
    mkdir -p "$root/src/__pycache__"
    echo "junk" > "$root/src/__pycache__/main.cpython-311.pyc"
    echo "junk" > "$root/src/main.pyc"

    staging="$(make_staging)"
    stage_payload "$staging" "$root"
    assert_rc 0 $? "stage_payload 应成功"

    local app="$staging/usr/lib/weather-widget"
    assert_file_exists "$app/src/main.py" "src 应被复制"
    assert_file_exists "$app/src/__init__.py" "包定义应被复制"
    assert_file_exists "$app/requirements.txt" "requirements.txt 应被复制"
    assert_file_exists "$app/assets/icon.png" "assets 应被复制"

    # 缓存文件应被清理
    if [[ -d "$app/src/__pycache__" ]]; then
        FAIL=$((FAIL + 1)); echo "  ❌ [$CURRENT_TEST] __pycache__ 应被清理"
    else
        PASS=$((PASS + 1))
    fi
    if [[ -f "$app/src/main.pyc" ]]; then
        FAIL=$((FAIL + 1)); echo "  ❌ [$CURRENT_TEST] .pyc 文件应被清理"
    else
        PASS=$((PASS + 1))
    fi

    # 图标布局
    assert_file_exists "$staging/usr/share/icons/hicolor/128x64/apps/weather-widget.png" \
        "PNG 图标应安装到与实际尺寸匹配的 hicolor 目录"
    assert_file_exists "$staging/usr/share/icons/hicolor/scalable/apps/weather-widget.svg" \
        "SVG 图标应安装到 scalable 目录"
}

test_stage_payload_missing_src() {
    local root staging out rc
    root="$(new_tmp)"
    staging="$(make_staging)"
    out="$(stage_payload "$staging" "$root" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "缺少 src/ 应失败"
    assert_contains "$out" "src/" "错误信息应提及 src/"
}

test_stage_payload_missing_license_ok_icon_optional() {
    # 无任何图标时仅告警，不失败
    local root staging out rc
    root="$(make_fixture)"
    rm -f "$root/assets/icon.png" "$root/assets/icon.svg"
    staging="$(make_staging)"
    out="$(stage_payload "$staging" "$root" 2>&1)"
    rc=$?
    assert_rc 0 "$rc" "无图标时 stage_payload 仍应成功"
    assert_contains "$out" "未找到图标" "应输出无图标告警"
}

# ============================================================
# build_package
# ============================================================
test_build_package_missing_dpkg_deb() {
    local staging out rc
    staging="$(make_staging)"
    mkdir -p "$staging/DEBIAN"
    echo "Package: x" > "$staging/DEBIAN/control"
    # 清空 PATH 模拟 dpkg-deb 不存在
    out="$(PATH=/nonexistent-dir build_package "$staging" "/tmp/never-built.deb" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "缺少 dpkg-deb 应失败"
    assert_contains "$out" "dpkg-deb" "错误信息应提及 dpkg-deb"
    if [[ -f /tmp/never-built.deb ]]; then
        FAIL=$((FAIL + 1)); echo "  ❌ [$CURRENT_TEST] 失败时不应产出文件"
        rm -f /tmp/never-built.deb
    else
        PASS=$((PASS + 1))
    fi
}

test_build_package_end_to_end() {
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        skip_test "dpkg-deb 不可用"
        return 0
    fi
    local root staging out info contents rc
    root="$(make_fixture)"
    staging="$(make_staging)"
    out="$(new_tmp)/weather-widget_9.8.7_all.deb"

    # 按 main 的完整流水线暂存
    stage_payload "$staging" "$root"
    generate_control "$staging" "9.8.7" "all" "Tester <t@example.com>"
    generate_launcher "$staging"
    generate_desktop "$staging"
    generate_maintainer_scripts "$staging"
    generate_changelog "$staging" "9.8.7" "Tester <t@example.com>"
    generate_doc "$staging" "$root" "9.8.7" "Tester <t@example.com>"

    build_package "$staging" "$out"
    rc=$?
    assert_rc 0 "$rc" "build_package 应成功"
    assert_file_exists "$out" "deb 文件应生成"

    info="$(dpkg-deb --info "$out")"
    assert_rc 0 $? "dpkg-deb --info 应通过（control 语法合法）"
    assert_contains "$info" "Package: weather-widget" "包名正确"
    assert_contains "$info" "Version: 9.8.7" "版本正确"
    assert_contains "$info" "Architecture: all" "架构正确"

    # DEBIAN/changelog 应进入控制归档
    assert_contains "$(dpkg-deb --ctrl-tarfile "$out" | tar -t)" "./changelog" \
        "控制归档应包含 changelog"
    assert_contains "$(dpkg-deb --ctrl-tarfile "$out" | tar -xO ./changelog)" \
        "weather-widget (9.8.7) unstable; urgency=low" "控制归档 changelog 内容正确"

    contents="$(dpkg-deb --contents "$out")"
    assert_contains "$contents" "root/root" "文件属主应为 root（--root-owner-group）"
    assert_contains "$contents" "./usr/bin/weather-widget" "含启动器"
    assert_contains "$contents" "./usr/lib/weather-widget/src/main.py" "含主程序"
    assert_contains "$contents" "./usr/share/applications/weather-widget.desktop" "含桌面入口"
    assert_contains "$contents" "./usr/share/icons/hicolor/128x64/apps/weather-widget.png" "含图标"
    assert_contains "$contents" "./usr/share/doc/weather-widget/copyright" "含版权文件"
}

# ============================================================
# CLI（main 入口，子进程方式运行真实脚本）
# ============================================================
test_cli_help() {
    local out rc
    out="$(bash "$BUILD_SCRIPT" --help)"
    rc=$?
    assert_rc 0 "$rc" "--help 应成功"
    assert_contains "$out" "用法" "帮助应含用法说明"
    assert_contains "$out" "DEB_VERSION" "帮助应说明环境变量"
}

test_cli_unknown_arg() {
    local out rc
    out="$(bash "$BUILD_SCRIPT" --bad-arg 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "未知参数应失败"
    assert_contains "$out" "未知参数" "应输出未知参数错误"
}

test_cli_output_missing_value() {
    local out rc
    out="$(bash "$BUILD_SCRIPT" -o 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "-o 缺少参数应失败"
    assert_contains "$out" "需要一个参数" "应提示缺少参数"
}

test_cli_full_build_real_project() {
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        skip_test "dpkg-deb 不可用"
        return 0
    fi
    local outdir out rc deb
    outdir="$(new_tmp)"
    out="$(bash "$BUILD_SCRIPT" -o "$outdir" 2>&1)"
    rc=$?
    assert_rc 0 "$rc" "真实项目构建应成功: $out"
    deb="$outdir/weather-widget_2.0.0_all.deb"
    assert_file_exists "$deb" "应生成 dist 命名的 deb 文件"
    if [[ -f "$deb" ]]; then
        assert_contains "$(dpkg-deb --info "$deb")" "Version: 2.0.0" "版本应来自 src/__init__.py"
        assert_contains "$(dpkg-deb --contents "$deb")" "./usr/lib/weather-widget/src/weather_ui.py" "应包含 UI 模块"
        assert_contains "$(dpkg-deb --ctrl-tarfile "$deb" | tar -t)" "./changelog" \
            "真实构建的控制归档应含 DEBIAN/changelog"
    fi
}

test_cli_env_overrides() {
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        skip_test "dpkg-deb 不可用"
        return 0
    fi
    local outdir out rc
    outdir="$(new_tmp)"

    # DEB_VERSION / DEB_ARCH / DEB_MAINTAINER 覆盖
    out="$(DEB_VERSION=3.4.5 DEB_ARCH=amd64 DEB_MAINTAINER="T <t@e.com>" \
        bash "$BUILD_SCRIPT" -o "$outdir" 2>&1)"
    rc=$?
    assert_rc 0 "$rc" "环境变量覆盖构建应成功: $out"
    assert_file_exists "$outdir/weather-widget_3.4.5_amd64.deb" "文件名应反映覆盖的版本与架构"
    if [[ -f "$outdir/weather-widget_3.4.5_amd64.deb" ]]; then
        out="$(dpkg-deb --info "$outdir/weather-widget_3.4.5_amd64.deb")"
        assert_contains "$out" "Maintainer: T <t@e.com>" "Maintainer 应被覆盖"
    fi

    # 非法 DEB_VERSION 应失败
    out="$(DEB_VERSION="bad version" bash "$BUILD_SCRIPT" -o "$outdir" 2>&1)"
    rc=$?
    assert_rc nonzero "$rc" "非法 DEB_VERSION 应失败"
    assert_contains "$out" "DEB_VERSION 非法" "应输出非法版本错误"
}

test_cli_reproducible_build() {
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        skip_test "dpkg-deb 不可用"
        return 0
    fi
    local outdir1 outdir2 rc
    outdir1="$(new_tmp)"
    outdir2="$(new_tmp)"
    SOURCE_DATE_EPOCH=1700000000 bash "$BUILD_SCRIPT" -o "$outdir1" >/dev/null 2>&1
    rc=$?
    assert_rc 0 "$rc" "第一次可复现构建应成功"
    SOURCE_DATE_EPOCH=1700000000 bash "$BUILD_SCRIPT" -o "$outdir2" >/dev/null 2>&1
    rc=$?
    assert_rc 0 "$rc" "第二次可复现构建应成功"
    if [[ -f "$outdir1/weather-widget_2.0.0_all.deb" && -f "$outdir2/weather-widget_2.0.0_all.deb" ]]; then
        local changelog
        changelog="$(dpkg-deb --fsys-tarfile "$outdir1/weather-widget_2.0.0_all.deb" 2>/dev/null \
            | tar -xO ./usr/share/doc/weather-widget/changelog.gz 2>/dev/null | gzip -dc)"
        assert_contains "$changelog" "Tue, 14 Nov 2023 22:13:20 +0000" "changelog 日期应来自 SOURCE_DATE_EPOCH"
        local deb_changelog
        deb_changelog="$(dpkg-deb --ctrl-tarfile "$outdir1/weather-widget_2.0.0_all.deb" 2>/dev/null \
            | tar -xO ./changelog 2>/dev/null)"
        assert_contains "$deb_changelog" "Tue, 14 Nov 2023 22:13:20 +0000" \
            "DEBIAN/changelog 日期应来自 SOURCE_DATE_EPOCH"
        assert_contains "$deb_changelog" "weather-widget (2.0.0)" "DEBIAN/changelog 应含包名与版本"
    else
        FAIL=$((FAIL + 1)); echo "  ❌ [$CURRENT_TEST] deb 产物缺失"
    fi
}

# ============================================================
# 执行全部测试
# ============================================================
echo "=========================================="
echo "  🧪 build_deb.sh 单元测试"
echo "=========================================="
echo ""

run_test "read_version: 正常解析"                    test_read_version_ok
run_test "read_version: 真实项目版本"                test_read_version_real_project
run_test "read_version: 文件不存在"                  test_read_version_missing_file
run_test "read_version: 无版本字段"                  test_read_version_no_field
run_test "read_version: 非法版本值"                  test_read_version_invalid_value
run_test "validate_version: 合法/非法边界"           test_validate_version
run_test "read_png_size: 正常解析"                   test_read_png_size_ok
run_test "read_png_size: 真实图标"                   test_read_png_size_real_icon
run_test "read_png_size: 非 PNG 文件"                test_read_png_size_not_png
run_test "read_png_size: 文件过短"                   test_read_png_size_truncated
run_test "read_png_size: 文件不存在"                 test_read_png_size_missing_file
run_test "read_png_size: 缺少 IHDR"                  test_read_png_size_bad_ihdr
run_test "generate_control: 字段与格式"              test_generate_control
run_test "generate_launcher: 内容与权限"             test_generate_launcher
run_test "generate_desktop: 字段与权限"              test_generate_desktop
run_test "generate_maintainer_scripts: postinst/postrm" test_generate_maintainer_scripts
run_test "write_changelog: 格式与权限"               test_write_changelog
run_test "write_changelog: SOURCE_DATE_EPOCH"       test_write_changelog_source_date_epoch
run_test "generate_changelog: DEBIAN/changelog 生成" test_generate_changelog
run_test "generate_changelog: 自动创建 DEBIAN 目录"  test_generate_changelog_creates_debian_dir
run_test "changelog: DEBIAN 与文档内容一致"          test_changelog_debian_matches_doc
run_test "generate_doc: copyright 与 changelog"      test_generate_doc
run_test "generate_doc: 缺少 LICENSE"                test_generate_doc_missing_license
run_test "changelog_date: SOURCE_DATE_EPOCH"         test_changelog_date_source_date_epoch
run_test "stage_payload: 布局与缓存清理"             test_stage_payload
run_test "stage_payload: 缺少 src/"                  test_stage_payload_missing_src
run_test "stage_payload: 无图标仅告警"               test_stage_payload_missing_license_ok_icon_optional
run_test "build_package: 缺少 dpkg-deb"              test_build_package_missing_dpkg_deb
run_test "build_package: 端到端构建"                 test_build_package_end_to_end
run_test "CLI: --help"                               test_cli_help
run_test "CLI: 未知参数"                             test_cli_unknown_arg
run_test "CLI: -o 缺少参数"                          test_cli_output_missing_value
run_test "CLI: 真实项目完整构建"                     test_cli_full_build_real_project
run_test "CLI: 环境变量覆盖"                         test_cli_env_overrides
run_test "CLI: 可复现构建"                           test_cli_reproducible_build

echo ""
echo "=========================================="
echo "  结果: ✅ 通过 $PASS   ❌ 失败 $FAIL   ⏭️ 跳过 $SKIP"
echo "=========================================="
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
