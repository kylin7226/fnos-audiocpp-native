#!/usr/bin/env bash
# ==============================================================================
# audio.cpp · fnOS native fpk —— 打包脚本（把 app 骨架 + app.tgz 组装成 .fpk）
#
# 自包含，不依赖官方 fnpack，也不依赖 fnos-apps 仓库。fpk 本质是 tar.gz：
#   app.tgz / cmd/ / config/ / wizard/ / ui/ / *.sc / ICON*.PNG / manifest
# manifest 的 checksum 字段 = app.tgz 的 md5（fnOS 安装时校验）。
#
# 用法：
#   scripts/pack-fpk.sh <app-dir> <app.tgz> [version] [platform] [out-dir]
#     app-dir   fpk 骨架目录（本仓库的 app/）
#     app.tgz   build-audiocpp.sh 产出的载荷
#     version   覆盖 manifest 版本（可选，CI 用 tag 传入）
#     platform  覆盖 manifest 平台（可选，默认取 manifest 里的值 / x86）
#     out-dir   输出目录（可选，默认当前目录）
# ==============================================================================
set -euo pipefail

info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

APP_DIR="${1:-}"; APP_TGZ="${2:-}"; VERSION="${3:-}"; PLATFORM="${4:-}"; OUT_DIR="${5:-.}"
[[ -n "$APP_DIR" && -n "$APP_TGZ" ]] || err "用法：$0 <app-dir> <app.tgz> [version] [platform] [out-dir]"
[[ -d "$APP_DIR" ]] || err "app 目录不存在：$APP_DIR"
[[ -f "$APP_TGZ" ]] || err "app.tgz 不存在：$APP_TGZ"

# ── 校验骨架完整性 ────────────────────────────────────────────────────────────
for f in manifest config/privilege config/resource cmd/main ICON.PNG ICON_256.PNG; do
  [[ -e "$APP_DIR/$f" ]] || err "缺少必需文件：$APP_DIR/$f"
done
for key in appname version display_name service_port source; do
  grep -q "^${key}[[:space:]]*=" "$APP_DIR/manifest" || err "manifest 缺字段：$key"
done

APPNAME=$(grep '^appname' "$APP_DIR/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
[[ -n "$APPNAME" ]] || err "无法从 manifest 读取 appname"

# app.tgz 过小多半是构建失败/下载损坏
SIZE=$(stat -c%s "$APP_TGZ" 2>/dev/null || stat -f%z "$APP_TGZ")
[[ "${SIZE:-0}" -ge 102400 ]] || err "app.tgz 异常偏小（${SIZE} 字节），疑似构建失败"

CHECKSUM=$(md5sum "$APP_TGZ" | cut -d' ' -f1)
info "打包 $APPNAME，app.tgz checksum=$CHECKSUM"

# ── 组装包目录 ────────────────────────────────────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/package"; mkdir -p "$PKG"

cp "$APP_TGZ" "$PKG/app.tgz"
cp -a "$APP_DIR/cmd"     "$PKG/"
cp -a "$APP_DIR/config"  "$PKG/"
[[ -d "$APP_DIR/wizard" ]] && cp -a "$APP_DIR/wizard" "$PKG/"
[[ -d "$APP_DIR/ui"     ]] && cp -a "$APP_DIR/ui"     "$PKG/"
cp "$APP_DIR"/*.sc       "$PKG/" 2>/dev/null || true
cp "$APP_DIR"/ICON*.PNG  "$PKG/"

# ui/images/icon-{64,256}.png 由 ICON*.PNG 生成，避免仓库里存重复图标
if [[ -d "$PKG/ui" ]]; then
  mkdir -p "$PKG/ui/images"
  if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
    IMG=$(command -v magick >/dev/null 2>&1 && echo "magick" || echo "convert")
    cp "$PKG/ICON.PNG"     "$PKG/ui/images/icon-64.png"
    cp "$PKG/ICON_256.PNG" "$PKG/ui/images/icon-256.png"
    info "已生成 ui/images/icon-{64,256}.png"
  else
    # 无 ImageMagick 时直接用现成图标充当（尺寸已由 ICON*.PNG 保证）
    cp "$PKG/ICON.PNG"     "$PKG/ui/images/icon-64.png"
    cp "$PKG/ICON_256.PNG" "$PKG/ui/images/icon-256.png"
  fi
fi

# ── 渲染 manifest（version / platform / checksum）────────────────────────────
cp "$APP_DIR/manifest" "$PKG/manifest"
if [[ -n "$VERSION" ]]; then
  sed -i "s/^version[[:space:]]*=.*/version         = ${VERSION}/" "$PKG/manifest"
fi
if [[ -n "$PLATFORM" ]]; then
  if grep -q '^platform' "$PKG/manifest"; then
    sed -i "s/^platform[[:space:]]*=.*/platform        = ${PLATFORM}/" "$PKG/manifest"
  else
    echo "platform        = ${PLATFORM}" >> "$PKG/manifest"
  fi
fi
sed -i "s/^checksum[[:space:]]*=.*/checksum        = ${CHECKSUM}/" "$PKG/manifest"

VER=$(grep '^version'  "$PKG/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
PLAT=$(grep '^platform' "$PKG/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
FPK_NAME="${APPNAME}_${VER}_${PLAT:-x86}.fpk"

mkdir -p "$OUT_DIR"
OUT_PATH="$(cd "$OUT_DIR" && pwd)/${FPK_NAME}"

# ── 生成 .fpk（tar.gz）───────────────────────────────────────────────────────
( cd "$PKG" && tar -czf "$OUT_PATH" ./* )
info "已生成：$OUT_PATH（$(du -h "$OUT_PATH" | cut -f1)）"
echo "$OUT_PATH"
