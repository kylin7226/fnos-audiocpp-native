#!/usr/bin/env bash
# ==============================================================================
# audio.cpp · fnOS native fpk —— 打包脚本（用官方 fnpack 生成可安装的 .fpk）
#
# 为什么必须用 fnpack：早期本脚本手搓 tar.gz（裸名条目）产包，fnOS 应用中心一律以
# 「应用包格式不符合系统版本要求」拒装——fnOS 校验的包结构/字段由官方 fnpack 决定，
# 手工复刻不可靠。改为：本脚本只负责把「构建产物 + 仓库骨架」组装成 fnpack 的工程
# 目录，再交给官方 fnpack build 出包，checksum/包内布局全由 fnpack 处理。
#
# fnpack 工程目录布局（对照 `fnpack create` 模板）：
#   <proj>/manifest          ← 仓库 app/manifest（去掉空 checksum 行，fnpack 自己算）
#   <proj>/ICON.PNG,ICON_256.PNG
#   <proj>/cmd/              ← 仓库 app/cmd/（9 个生命周期脚本）
#   <proj>/config/           ← 仓库 app/config/（privilege,resource）
#   <proj>/wizard/           ← 仓库 app/wizard/（install）
#   <proj>/app/              ← 载荷：解开 app.tgz（bin/etc/assets）+ 注入桌面入口 ui/
# 产物：<proj>/<appname>.fpk，最后按 <appname>_<version>_<platform>.fpk 改名到 out-dir。
#
# 用法：
#   scripts/pack-fpk.sh <app-dir> <app.tgz> [version] [platform] [out-dir]
#     app-dir   fpk 骨架目录（本仓库的 app/）
#     app.tgz   build-audiocpp.sh 产出的载荷
#     version   覆盖 manifest 版本（可选，CI 用 tag 传入）
#     platform  覆盖 manifest 平台（可选，默认取 manifest 里的值 / x86）
#     out-dir   输出目录（可选，默认当前目录）
#
# fnpack 定位：优先用环境变量 FNPACK 指定的可执行文件；否则用 PATH 里的 fnpack；
# 再否则从 FNPACK_URL（默认官方 v1.2.3）下载到临时目录。
# ==============================================================================
set -euo pipefail

info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

APP_DIR="${1:-}"; APP_TGZ="${2:-}"; VERSION="${3:-}"; PLATFORM="${4:-}"; OUT_DIR="${5:-.}"
[[ -n "$APP_DIR" && -n "$APP_TGZ" ]] || err "用法：$0 <app-dir> <app.tgz> [version] [platform] [out-dir]"
[[ -d "$APP_DIR" ]] || err "app 目录不存在：$APP_DIR"
[[ -f "$APP_TGZ" ]] || err "app.tgz 不存在：$APP_TGZ"

FNPACK_URL="${FNPACK_URL:-https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64}"

# ── 校验骨架完整性 ────────────────────────────────────────────────────────────
for f in manifest config/privilege config/resource cmd/main ui/config ICON.PNG ICON_256.PNG; do
  [[ -e "$APP_DIR/$f" ]] || err "缺少必需文件：$APP_DIR/$f"
done
# fnpack 硬性要求 9 个生命周期脚本齐全（缺一个 build 就报错）
for c in main install_init install_callback uninstall_init uninstall_callback \
         upgrade_init upgrade_callback config_init config_callback; do
  [[ -f "$APP_DIR/cmd/$c" ]] || err "缺少 cmd 生命周期脚本：$APP_DIR/cmd/$c"
done
for key in appname version display_name service_port source; do
  grep -q "^${key}[[:space:]]*=" "$APP_DIR/manifest" || err "manifest 缺字段：$key"
done

APPNAME=$(grep '^appname' "$APP_DIR/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
[[ -n "$APPNAME" ]] || err "无法从 manifest 读取 appname"

# app.tgz 过小多半是构建失败/下载损坏
SIZE=$(stat -c%s "$APP_TGZ" 2>/dev/null || stat -f%z "$APP_TGZ")
[[ "${SIZE:-0}" -ge 102400 ]] || err "app.tgz 异常偏小（${SIZE} 字节），疑似构建失败"

# ── 定位 / 下载 fnpack ────────────────────────────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
if [[ -n "${FNPACK:-}" && -x "${FNPACK}" ]]; then
  FNPACK_BIN="$FNPACK"
elif command -v fnpack >/dev/null 2>&1; then
  FNPACK_BIN="$(command -v fnpack)"
else
  FNPACK_BIN="$WORK/fnpack"
  info "下载 fnpack：$FNPACK_URL"
  curl -fsSL --retry 3 -o "$FNPACK_BIN" "$FNPACK_URL" || err "fnpack 下载失败：$FNPACK_URL"
  chmod +x "$FNPACK_BIN"
fi
info "使用 fnpack：$FNPACK_BIN（$("$FNPACK_BIN" --help 2>&1 | grep -i '^Version' || echo '?')）"

# ── 组装 fnpack 工程目录 ──────────────────────────────────────────────────────
PROJ="$WORK/$APPNAME"; mkdir -p "$PROJ"

# 1) 工程根：manifest + 图标 + cmd/config/wizard
cp "$APP_DIR"/ICON*.PNG "$PROJ/"
cp -a "$APP_DIR/cmd"    "$PROJ/"
cp -a "$APP_DIR/config" "$PROJ/"
[[ -d "$APP_DIR/wizard" ]] && cp -a "$APP_DIR/wizard" "$PROJ/"
chmod 755 "$PROJ"/cmd/* 2>/dev/null || true

# manifest：去掉空 checksum 行（fnpack build 会自行计算并写入），再套用 version/platform
grep -v '^[[:space:]]*checksum[[:space:]]*=[[:space:]]*$' "$APP_DIR/manifest" > "$PROJ/manifest"
if [[ -n "$VERSION" ]]; then
  sed -i "s/^version[[:space:]]*=.*/version         = ${VERSION}/" "$PROJ/manifest"
fi
if [[ -n "$PLATFORM" ]]; then
  if grep -q '^platform' "$PROJ/manifest"; then
    sed -i "s/^platform[[:space:]]*=.*/platform        = ${PLATFORM}/" "$PROJ/manifest"
  else
    echo "platform        = ${PLATFORM}" >> "$PROJ/manifest"
  fi
fi

# 2) 载荷 app/：解开构建产物（bin/etc/assets），再注入桌面入口 ui/
mkdir -p "$PROJ/app"
tar -xzf "$APP_TGZ" -C "$PROJ/app"
mkdir -p "$PROJ/app/ui/images"
cp "$APP_DIR/ui/config" "$PROJ/app/ui/config"
# ui/config 里 icon 用 {0} 占位尺寸，生成 icon_{32,64,128,256}.png（下划线命名，
# 与 fnpack 模板 / ui/config 的 images/icon_{0}.png 一致）。
gen_icon() {
  local sz="$1" out="$PROJ/app/ui/images/icon_${sz}.png"
  if command -v magick >/dev/null 2>&1; then
    magick "$APP_DIR/ICON_256.PNG" -resize "${sz}x${sz}" "$out"
  elif command -v convert >/dev/null 2>&1; then
    convert "$APP_DIR/ICON_256.PNG" -resize "${sz}x${sz}" "$out"
  elif [[ "$sz" -le 64 ]]; then cp "$APP_DIR/ICON.PNG" "$out"
  else cp "$APP_DIR/ICON_256.PNG" "$out"; fi
}
for sz in 32 64 128 256; do gen_icon "$sz"; done

VER=$(grep '^version'  "$PROJ/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
PLAT=$(grep '^platform' "$PROJ/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
FPK_NAME="${APPNAME}_${VER}_${PLAT:-x86}.fpk"

# ── fnpack build ──────────────────────────────────────────────────────────────
info "fnpack build -d $PROJ"
( cd "$PROJ" && "$FNPACK_BIN" build -d . )
[[ -f "$PROJ/${APPNAME}.fpk" ]] || err "fnpack 未产出 ${APPNAME}.fpk"

mkdir -p "$OUT_DIR"
OUT_PATH="$(cd "$OUT_DIR" && pwd)/${FPK_NAME}"
mv -f "$PROJ/${APPNAME}.fpk" "$OUT_PATH"
info "已生成：$OUT_PATH（$(du -h "$OUT_PATH" | cut -f1)）"
echo "$OUT_PATH"
