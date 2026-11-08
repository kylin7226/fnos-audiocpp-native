#!/usr/bin/env bash
# ==============================================================================
# audio.cpp · fnOS native fpk —— 打包脚本（把 app 骨架 + app.tgz 组装成 .fpk）
#
# 自包含，不依赖官方 fnpack，也不依赖 fnos-apps 仓库。fpk 本质是 tar.gz，顶层裸名条目
# （不能带 ./ 前缀，否则 fnOS 包格式校验失败）：
#   app.tgz / cmd/ / config/ / wizard/ / *.sc / ICON*.PNG / manifest
# 桌面入口 ui/ 打进 app.tgz（安装后即 target/ui），不放顶层。
# manifest 的 checksum 字段 = 最终 app.tgz 的 md5（fnOS 安装时校验）。
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

# ── 组装包目录 ────────────────────────────────────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/package"; mkdir -p "$PKG"

# app.tgz = 安装后 target/ 的内容。fnOS 包格式硬性要求（对照真实可安装的 fan-control/motrix）：
#   1) 桌面入口 ui/ 必须在 app.tgz 内（安装后即 target/ui，manifest 的 desktop_uidir 指它），
#      不能放在 .fpk 顶层；
#   2) tar 条目必须是裸名（manifest / app.tgz / bin/…），不能带 ./ 前缀，否则包格式校验失败。
# 因此解开构建产出的 app.tgz、注入 ui/，再按裸名重新打包。
APPWORK="$WORK/app"; mkdir -p "$APPWORK"
tar -xzf "$APP_TGZ" -C "$APPWORK"
mkdir -p "$APPWORK/ui/images"
[[ -f "$APP_DIR/ui/config" ]] || err "缺少桌面入口配置：$APP_DIR/ui/config"
cp "$APP_DIR/ui/config" "$APPWORK/ui/config"
# ui/images/icon-{32,64,128,256}.png：ui/config 里 icon 用 {0} 占位尺寸，由 ICON*.PNG 生成
gen_icon() {
  local sz="$1" out="$APPWORK/ui/images/icon-$1.png"
  if command -v magick >/dev/null 2>&1; then
    magick "$APP_DIR/ICON_256.PNG" -resize "${sz}x${sz}" "$out"
  elif command -v convert >/dev/null 2>&1; then
    convert "$APP_DIR/ICON_256.PNG" -resize "${sz}x${sz}" "$out"
  elif [[ "$sz" -le 64 ]]; then cp "$APP_DIR/ICON.PNG" "$out"
  else cp "$APP_DIR/ICON_256.PNG" "$out"; fi
}
for sz in 32 64 128 256; do gen_icon "$sz"; done
# 裸名重打包（cd 进目录用 * 通配，避免 ./ 前缀）
( cd "$APPWORK" && tar -czf "$PKG/app.tgz" * )

# checksum 必须对最终打进包的 app.tgz（已注入 ui/ 并重打包）计算，而非构建原始产物
CHECKSUM=$(md5sum "$PKG/app.tgz" | cut -d' ' -f1)
info "打包 $APPNAME，app.tgz checksum=$CHECKSUM"

cp -a "$APP_DIR/cmd"     "$PKG/"
cp -a "$APP_DIR/config"  "$PKG/"
[[ -d "$APP_DIR/wizard" ]] && cp -a "$APP_DIR/wizard" "$PKG/"
cp "$APP_DIR"/*.sc       "$PKG/" 2>/dev/null || true
cp "$APP_DIR"/ICON*.PNG  "$PKG/"

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

# ── 生成 .fpk（tar.gz，条目用裸名，不能带 ./ 前缀）───────────────────────────
( cd "$PKG" && tar -czf "$OUT_PATH" * )
info "已生成：$OUT_PATH（$(du -h "$OUT_PATH" | cut -f1)）"
echo "$OUT_PATH"
