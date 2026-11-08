#!/usr/bin/env bash
# ==============================================================================
# audio.cpp · fnOS native fpk —— 构建脚本（在 debian:12 容器内运行）
#
# 为什么在 debian:12 里编：fnOS = Debian 12（glibc 2.36）。官方 release 的 Linux
# 二进制是在 Ubuntu 24.04（glibc 2.39）上编的，直接拿到 fnOS 会报
# GLIBC_2.38/GLIBCXX_3.4.32 not found。在 bookworm 里编出的产物才与 fnOS 兼容。
#
# 输入（环境变量）：
#   SRC_DIR   audio.cpp 源码目录（含 CMakeLists.txt），必填
#   REPO_DIR  本 fnos-audiocpp-native 目录（提供 payload/etc/server.json.template），必填
#   OUT_TGZ   输出的 app.tgz 路径，默认 $REPO_DIR/dist/app.tgz
#   JOBS      并行编译数，默认 nproc
#   AUDIOCPP_VERSION  编进二进制的版本串（-DAUDIOCPP_VERSION），默认 dev
#
# 产出：app.tgz —— 解压到 fnOS 的 TRIM_APPDEST(target/) 后含：
#   bin/audiocpp_server, bin/audiocpp_cli, bin/audiocpp_model_manager, bin/*.so*
#   bin/provision-models.sh（按 server.json 自动下载缺失模型）
#   etc/server.json.template
#   assets/silero_vad/silero_vad_16k.safetensors
#   assets/demo_voices/*
# ==============================================================================
set -euo pipefail

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "${SRC_DIR:-}"  ]] || die "必须设置 SRC_DIR（audio.cpp 源码目录）"
[[ -n "${REPO_DIR:-}" ]] || die "必须设置 REPO_DIR（fnos-audiocpp-native 目录）"
[[ -f "$SRC_DIR/CMakeLists.txt" ]] || die "SRC_DIR=$SRC_DIR 下没有 CMakeLists.txt"
OUT_TGZ="${OUT_TGZ:-$REPO_DIR/dist/app.tgz}"
JOBS="${JOBS:-$(nproc)}"

# 确认构建环境确实是 bookworm（glibc 2.36），编错环境会白干
if [[ -r /etc/debian_version ]]; then
  log "构建环境 Debian $(cat /etc/debian_version) / glibc $(ldd --version | head -1 | grep -oE '[0-9.]+$')"
fi

# ── 1. 依赖 ────────────────────────────────────────────────────────────────────
# 与官方 release.yml linux-vulkan 一致，但 Debian 12 的 build-essential 是 gcc-12
# （< audio.cpp 要求的 13），所以显式装 gcc-13/g++-13，如同官方 CUDA job 对 ubuntu22.04。
log "安装构建依赖（apt / bookworm）"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    gcc-13 g++-13 make cmake ca-certificates \
    glslc libvulkan-dev spirv-headers \
    libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev \
    libgomp1
command -v gcc-13 >/dev/null || die "gcc-13 安装失败"

# ── 2. 配置 + 构建（对齐官方 release.yml 的 linux-vulkan-**portable** 配方）──────
# 关键：用 portable 而非默认（native）配方。ENGINE_DEFAULT_ENABLE_NATIVE_CPU=ON，
# 默认会按“编译机 CPU”下 -march=native；但本包在 GitHub runner 上编、却要跑在
# 用户各不相同的 NAS CPU 上，native 编译可能触发 SIGILL（非法指令）。portable 配方
# 关掉 native、开启 CPU_ALL_VARIANTS（把 CPU 后端编成按 ISA 分派的动态库，运行时自选），
# 因此可在任意 x86-64 NAS 上安全运行。这些 ggml-cpu-*.so 会被下面 3.1 一并打进 bin/。
log "cmake 配置（Vulkan portable，DEPLOYMENT_BUILD=ON）"
export CC=gcc-13 CXX=g++-13
cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENGINE_ENABLE_CUDA=OFF \
    -DENGINE_ENABLE_VULKAN=ON \
    -DENGINE_ENABLE_OPENMP=ON \
    -DENGINE_ENABLE_NATIVE_CPU=OFF \
    -DENGINE_ENABLE_CPU_ALL_VARIANTS=ON \
    -DAUDIOCPP_VERSION="${AUDIOCPP_VERSION:-dev}" \
    -DAUDIOCPP_DEPLOYMENT_BUILD=ON \
    -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=ON \
    -DENGINE_ENABLE_LLAMAFILE=ON \
    -DENGINE_BUILD_EXAMPLES=OFF \
    -DENGINE_BUILD_TESTS=OFF \
    -DENGINE_BUILD_WARMBENCH=OFF

log "编译 audiocpp_server / audiocpp_cli / audiocpp_model_manager（-j$JOBS）"
cmake --build "$SRC_DIR/build" --parallel "$JOBS" \
    --target audiocpp_server \
    --target audiocpp_cli \
    --target audiocpp_model_manager

[[ -x "$SRC_DIR/build/bin/audiocpp_server" ]] || die "构建产物缺失 audiocpp_server"
[[ -x "$SRC_DIR/build/bin/audiocpp_model_manager" ]] || die "构建产物缺失 audiocpp_model_manager（模型自动下载需要它）"

# 校验：产物应链接 bookworm 的 glibc，且不含高于 2.36 的 GLIBC 符号版本
log "校验 glibc 符号版本（应 ≤ GLIBC_2.36）"
MAXGLIBC=$(objdump -T "$SRC_DIR/build/bin/audiocpp_server" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1 || echo "GLIBC_?")
echo "  最高 GLIBC 需求：${MAXGLIBC}"
case "$MAXGLIBC" in
  GLIBC_2.3[0-6]|GLIBC_2.[0-2][0-9]|GLIBC_?) : ;;
  *) echo "  警告：${MAXGLIBC} 高于 2.36，可能不是在 bookworm 里编的！" >&2 ;;
esac

# ── 3. 组装 app.tgz 载荷 ──────────────────────────────────────────────────────
log "组装载荷 → $OUT_TGZ"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 3.1 二进制 + 所有 .so（rpath=$ORIGIN，必须同目录）
mkdir -p "$STAGE/bin"
cp -f "$SRC_DIR/build/bin/audiocpp_server" \
      "$SRC_DIR/build/bin/audiocpp_cli" \
      "$SRC_DIR/build/bin/audiocpp_model_manager" "$STAGE/bin/"
find "$SRC_DIR/build" -name '*.so*' -exec cp -Pf {} "$STAGE/bin/" \;
chmod 755 "$STAGE/bin/audiocpp_server" "$STAGE/bin/audiocpp_cli" "$STAGE/bin/audiocpp_model_manager"

# 3.1b 模型自动下载脚本（install_callback 后台调用 / main download-models 前台调用）
cp -f "$REPO_DIR/payload/bin/provision-models.sh" "$STAGE/bin/"
chmod 755 "$STAGE/bin/provision-models.sh"

# 3.2 配置模板（install_callback 会渲染 __DATA_ROOT__）
mkdir -p "$STAGE/etc"
cp -f "$REPO_DIR/payload/etc/server.json.template" "$STAGE/etc/"

# 3.3 资产：silero VAD 权重 + demo 参考音频（来自上游源码树）
mkdir -p "$STAGE/assets/silero_vad" "$STAGE/assets/demo_voices"
VAD="$SRC_DIR/assets/framework/models/silero_vad/silero_vad_16k.safetensors"
[[ -f "$VAD" ]] && cp -f "$VAD" "$STAGE/assets/silero_vad/" || echo "  警告：未找到 silero VAD 权重" >&2
if [[ -d "$SRC_DIR/webui/native/demo_voices" ]]; then
  cp -rf "$SRC_DIR/webui/native/demo_voices/." "$STAGE/assets/demo_voices/"
else
  echo "  警告：未找到 demo_voices" >&2
fi

# 3.4 打包（保留可执行位）
mkdir -p "$(dirname "$OUT_TGZ")"
tar -czf "$OUT_TGZ" -C "$STAGE" .
log "完成：$OUT_TGZ （$(du -h "$OUT_TGZ" | cut -f1)）"
echo "--- 载荷内容 ---"
tar -tzf "$OUT_TGZ" | sed -n '1,25p'
