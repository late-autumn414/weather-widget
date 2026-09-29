#!/usr/bin/env bash
# ============================================================
# 天气桌面小工具 - deb 打包构建脚本
# 适用于 Debian / Deepin / UOS 及其衍生发行版
# ============================================================
# 用法:
#   ./packaging/build_deb.sh                 # 构建到 dist/ 目录
#   ./packaging/build_deb.sh -o DIR          # 指定输出目录
#   ./packaging/build_deb.sh --help          # 显示帮助
#
# 环境变量（均可选）:
#   DEB_VERSION        版本号覆盖（默认从 src/__init__.py 读取）
#   DEB_MAINTAINER     维护者覆盖（默认使用内置作者信息）
#   DEB_ARCH           架构覆盖（默认 all，纯 Python 架构无关）
#   SOURCE_DATE_EPOCH  构建时间戳（Unix 秒，用于可复现构建）
#
# 构建产物:
#   <输出目录>/weather-widget_<版本>_<架构>.deb
#
# 安装 / 卸载:
#   sudo apt install ./dist/weather-widget_<版本>_all.deb
#   sudo apt remove weather-widget
# ============================================================

# ============================================================
# 包元数据常量
# ============================================================
PKG_NAME="weather-widget"
PKG_SECTION="utils"
PKG_PRIORITY="optional"
PKG_HOMEPAGE="https://github.com/late-autumn414/weather-widget"
DEFAULT_MAINTAINER="WangWq <wangwq@deepin.org>"
DEFAULT_DEPENDS="python3 (>= 3.8), python3-tk"
DEFAULT_RECOMMENDS="python3-pil"
INSTALL_PREFIX="/usr/lib/weather-widget"

# ============================================================
# 颜色与日志（与 setup.sh 风格一致）
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_ok()   { echo -e "  ${GREEN}✅${NC} $*"; }
log_warn() { echo -e "  ${YELLOW}⚠️${NC} $*"; }
log_err()  { echo -e "  ${RED}❌${NC} $*" >&2; }
log_info() { echo -e "  ${BLUE}ℹ️${NC} $*"; }

# ============================================================
# 帮助信息
# ============================================================
usage() {
    cat <<EOF
用法: $0 [-o DIR] [--help]

  -o, --output DIR   指定 deb 输出目录（默认: 项目根目录下的 dist/）
  -h, --help         显示此帮助信息

环境变量:
  DEB_VERSION        版本号覆盖（默认从 src/__init__.py 读取 __version__）
  DEB_MAINTAINER     维护者覆盖（默认: $DEFAULT_MAINTAINER）
  DEB_ARCH           架构覆盖（默认: all）
  SOURCE_DATE_EPOCH  构建时间戳（Unix 秒，用于可复现构建）

示例:
  ./packaging/build_deb.sh
  DEB_VERSION=2.0.0 ./packaging/build_deb.sh -o /tmp/debs
EOF
}

# ============================================================
# 版本号处理
# ============================================================
validate_version() {
    # deb 版本号规则: 以数字开头，仅含数字/字母/./+/-/~
    [[ "$1" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]]
}

read_version() {
    # $1: src/__init__.py 路径
    # 输出: 解析到的版本号（stdout）；失败时返回非 0
    local init_file="$1" version
    if [[ ! -f "$init_file" ]]; then
        log_err "未找到版本定义文件: $init_file"
        return 1
    fi
    version=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$init_file" | head -n 1)
    if [[ -z "$version" ]]; then
        log_err "无法从 $init_file 解析 __version__ 字段"
        return 1
    fi
    if ! validate_version "$version"; then
        log_err "非法版本号: $version（须以数字开头，仅含数字/字母/./+/-/~）"
        return 1
    fi
    echo "$version"
}

# ============================================================
# PNG 尺寸解析（用于 hicolor 图标目录命名）
# ============================================================
read_png_size() {
    # $1: PNG 文件路径
    # 输出: 宽x高（如 128x128）；非 PNG 或文件过短时返回非 0
    local png="$1" bytes
    local -a sig
    if [[ ! -f "$png" ]]; then
        log_err "未找到 PNG 文件: $png"
        return 1
    fi
    bytes=$(od -A n -t u1 -N 24 -- "$png" | tr -s ' \n' ' ')
    read -r -a sig <<< "$bytes"
    if (( ${#sig[@]} < 24 )); then
        log_err "文件过短，不是有效的 PNG: $png"
        return 1
    fi
    # 校验 PNG 签名: 89 50 4E 47 0D 0A 1A 0A
    if (( sig[0] != 137 || sig[1] != 80 || sig[2] != 78 || sig[3] != 71 )); then
        log_err "不是有效的 PNG 文件: $png"
        return 1
    fi
    # 校验第一个块必须是 IHDR: 73 72 68 82（偏移 12-15）
    if (( sig[12] != 73 || sig[13] != 72 || sig[14] != 68 || sig[15] != 82 )); then
        log_err "PNG 缺少 IHDR 块: $png"
        return 1
    fi
    local w h
    w=$(( sig[16] * 16777216 + sig[17] * 65536 + sig[18] * 256 + sig[19] ))
    h=$(( sig[20] * 16777216 + sig[21] * 65536 + sig[22] * 256 + sig[23] ))
    if (( w <= 0 || h <= 0 )); then
        log_err "PNG 尺寸异常: ${w}x${h}"
        return 1
    fi
    echo "${w}x${h}"
}

# ============================================================
# DEBIAN/control 生成
# ============================================================
generate_control() {
    # $1: staging 目录  $2: 版本  $3: 架构  $4: 维护者
    local staging="$1" version="$2" arch="$3" maintainer="$4"
    mkdir -p "$staging/DEBIAN"
    cat > "$staging/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $version
Architecture: $arch
Maintainer: $maintainer
Depends: $DEFAULT_DEPENDS
Recommends: $DEFAULT_RECOMMENDS
Section: $PKG_SECTION
Priority: $PKG_PRIORITY
Homepage: $PKG_HOMEPAGE
Description: 多城市桌面天气小工具
 支持多城市同屏显示实时天气与未来 3 天预报，基于 Python + Tkinter
 构建，适用于 Deepin / UOS / Linux 桌面环境。
 .
 特性: 多城市同屏、城市搜索、自定义背景、深色主题、30 分钟自动
 刷新、数据缓存与断网保护。
EOF
    chmod 0644 "$staging/DEBIAN/control"
}

# ============================================================
# 启动器 /usr/bin/weather-widget
# ============================================================
generate_launcher() {
    # $1: staging 目录
    local staging="$1"
    mkdir -p "$staging/usr/bin"
    cat > "$staging/usr/bin/$PKG_NAME" <<EOF
#!/bin/sh
# $PKG_NAME 启动器（由 packaging/build_deb.sh 生成）
exec python3 $INSTALL_PREFIX/src/main.py "\$@"
EOF
    chmod 0755 "$staging/usr/bin/$PKG_NAME"
}

# ============================================================
# 桌面入口 /usr/share/applications/weather-widget.desktop
# ============================================================
generate_desktop() {
    # $1: staging 目录
    local staging="$1"
    mkdir -p "$staging/usr/share/applications"
    cat > "$staging/usr/share/applications/$PKG_NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=天气小工具
GenericName=Weather Widget
Comment=多城市桌面天气小工具 - 实时天气、3天预报
Exec=$PKG_NAME
Icon=$PKG_NAME
Terminal=false
Categories=Utility;Weather;
StartupNotify=true
EOF
    chmod 0644 "$staging/usr/share/applications/$PKG_NAME.desktop"
}

# ============================================================
# 维护者脚本 postinst / postrm
# ============================================================
generate_maintainer_scripts() {
    # $1: staging 目录
    local staging="$1"
    mkdir -p "$staging/DEBIAN"
    local body
    body='#!/bin/sh
set -e

# 刷新图标缓存与桌面数据库，使图标和菜单项立即生效
if [ -x /usr/bin/gtk-update-icon-cache ]; then
    gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
if [ -x /usr/bin/update-desktop-database ]; then
    update-desktop-database -q /usr/share/applications || true
fi

exit 0
'
    printf '%s' "$body" > "$staging/DEBIAN/postinst"
    printf '%s' "$body" > "$staging/DEBIAN/postrm"
    chmod 0755 "$staging/DEBIAN/postinst" "$staging/DEBIAN/postrm"
}

# ============================================================
# changelog 生成（DEBIAN/changelog 与文档目录共用）
# ============================================================
changelog_date() {
    # 支持 SOURCE_DATE_EPOCH 以实现可复现构建
    if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
        date -u -d "@${SOURCE_DATE_EPOCH}" -R
    else
        date -R
    fi
}

write_changelog() {
    # $1: 目标文件路径  $2: 版本  $3: 维护者
    # 按 Debian changelog 格式写出内容，DEBIAN/changelog 与文档目录共用，
    # 保证两处 changelog 内容一致
    local out="$1" version="$2" maintainer="$3"
    cat > "$out" <<EOF
$PKG_NAME ($version) unstable; urgency=low

  * 新增 deb 打包支持（packaging/build_deb.sh）

 -- $maintainer  $(changelog_date)
EOF
    chmod 0644 "$out"
}

generate_changelog() {
    # $1: staging 目录  $2: 版本  $3: 维护者
    # 生成 DEBIAN/changelog，随控制归档打入 deb 包，
    # 可通过 dpkg-deb --info / apt changelog 查看
    local staging="$1" version="$2" maintainer="$3"
    mkdir -p "$staging/DEBIAN"
    write_changelog "$staging/DEBIAN/changelog" "$version" "$maintainer"
}

# ============================================================
# 文档（copyright + changelog.gz）
# ============================================================
generate_doc() {
    # $1: staging 目录  $2: 项目根目录  $3: 版本  $4: 维护者
    local staging="$1" root="$2" version="$3" maintainer="$4"
    local doc_dir="$staging/usr/share/doc/$PKG_NAME"
    if [[ ! -f "$root/LICENSE" ]]; then
        log_err "缺少 LICENSE 文件，无法生成 copyright: $root/LICENSE"
        return 1
    fi
    mkdir -p "$doc_dir"
    cp "$root/LICENSE" "$doc_dir/copyright"
    chmod 0644 "$doc_dir/copyright"
    write_changelog "$doc_dir/changelog" "$version" "$maintainer"
    gzip -9n "$doc_dir/changelog"
}

# ============================================================
# 安装文件暂存（payload 布局）
# ============================================================
stage_payload() {
    # $1: staging 目录  $2: 项目根目录
    local staging="$1" root="$2"
    local app_dir="$staging$INSTALL_PREFIX"

    if [[ ! -d "$root/src" ]]; then
        log_err "缺少 src/ 目录，无法打包: $root"
        return 1
    fi

    # ---- 应用主体: /usr/lib/weather-widget/ ----
    mkdir -p "$app_dir"
    cp -a "$root/src" "$app_dir/"
    # 清理缓存文件，保证包内容干净、可复现
    find "$app_dir" -type d -name '__pycache__' -prune -exec rm -rf {} +
    find "$app_dir" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
    if [[ -f "$root/requirements.txt" ]]; then
        cp "$root/requirements.txt" "$app_dir/"
    fi
    if [[ -d "$root/assets" ]]; then
        mkdir -p "$app_dir/assets"
        cp -a "$root/assets/." "$app_dir/assets/"
    fi

    # ---- hicolor 图标 ----
    local png="$root/assets/icon.png" svg="$root/assets/icon.svg" size
    if [[ -f "$png" ]]; then
        size=$(read_png_size "$png") || return 1
        mkdir -p "$staging/usr/share/icons/hicolor/$size/apps"
        cp "$png" "$staging/usr/share/icons/hicolor/$size/apps/$PKG_NAME.png"
        chmod 0644 "$staging/usr/share/icons/hicolor/$size/apps/$PKG_NAME.png"
    fi
    if [[ -f "$svg" ]]; then
        mkdir -p "$staging/usr/share/icons/hicolor/scalable/apps"
        cp "$svg" "$staging/usr/share/icons/hicolor/scalable/apps/$PKG_NAME.svg"
        chmod 0644 "$staging/usr/share/icons/hicolor/scalable/apps/$PKG_NAME.svg"
    fi
    if [[ ! -f "$png" && ! -f "$svg" ]]; then
        log_warn "未找到图标文件（assets/icon.png / icon.svg），包内将不含图标"
    fi
}

# ============================================================
# 调用 dpkg-deb 构建
# ============================================================
build_package() {
    # $1: staging 目录  $2: 输出 .deb 路径
    local staging="$1" out="$2"
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        log_err "未找到 dpkg-deb，请先安装: sudo apt install dpkg"
        return 1
    fi
    mkdir -p "$(dirname "$out")"
    rm -f "$out"
    dpkg-deb --build --root-owner-group "$staging" "$out" >/dev/null
}

# ============================================================
# 主流程
# ============================================================
STAGING_DIR=""

cleanup() {
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi
    return 0
}

main() {
    set -euo pipefail

    local script_dir project_root output_dir="dist"
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    project_root="$(dirname "$script_dir")"

    # ---- 解析参数 ----
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                if [[ $# -lt 2 ]]; then
                    log_err "$1 需要一个参数: 输出目录"
                    return 1
                fi
                output_dir="$2"
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                log_err "未知参数: $1"
                usage >&2
                return 1
                ;;
        esac
    done

    # ---- 版本 / 架构 / 维护者 ----
    local version="${DEB_VERSION:-}" arch maintainer
    if [[ -z "$version" ]]; then
        version="$(read_version "$project_root/src/__init__.py")"
    elif ! validate_version "$version"; then
        log_err "DEB_VERSION 非法: $version（须以数字开头，仅含数字/字母/./+/-/~）"
        return 1
    fi
    arch="${DEB_ARCH:-all}"
    maintainer="${DEB_MAINTAINER:-$DEFAULT_MAINTAINER}"

    # 相对输出目录基于项目根目录解析
    case "$output_dir" in
        /*) ;;
        *)  output_dir="$project_root/$output_dir" ;;
    esac

    local deb_path="$output_dir/${PKG_NAME}_${version}_${arch}.deb"
    STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PKG_NAME}-deb.XXXXXX")"
    trap cleanup EXIT

    echo ""
    echo "=========================================="
    echo "  📦 deb 打包 - $PKG_NAME"
    echo "=========================================="
    echo ""
    log_info "版本: $version    架构: $arch"
    log_info "维护者: $maintainer"
    log_info "项目根目录: $project_root"
    echo ""

    # ---- 暂存安装文件 ----
    echo "📋 暂存安装文件..."
    stage_payload "$STAGING_DIR" "$project_root"
    generate_control "$STAGING_DIR" "$version" "$arch" "$maintainer"
    generate_launcher "$STAGING_DIR"
    generate_desktop "$STAGING_DIR"
    generate_maintainer_scripts "$STAGING_DIR"
    generate_changelog "$STAGING_DIR" "$version" "$maintainer"
    generate_doc "$STAGING_DIR" "$project_root" "$version" "$maintainer"
    log_ok "暂存目录就绪"

    # ---- 构建 ----
    echo "🔨 构建 deb 包..."
    build_package "$STAGING_DIR" "$deb_path"
    log_ok "构建成功"

    # ---- 验证与信息输出 ----
    echo ""
    echo "🔍 包信息:"
    dpkg-deb --info "$deb_path"
    echo ""
    echo "=========================================="
    echo -e "  ${GREEN}✅ deb 包构建完成!${NC}"
    echo "=========================================="
    echo ""
    echo "产物:     $deb_path"
    echo "安装:     sudo apt install $deb_path"
    echo "启动:     $PKG_NAME  （或应用菜单中点击「天气小工具」）"
    echo "卸载:     sudo apt remove $PKG_NAME"
    echo ""
}

# 仅在直接执行时运行主流程（被 source 时只加载函数，便于单元测试）
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
