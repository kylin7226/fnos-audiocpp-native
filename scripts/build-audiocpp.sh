#!/usr/bin/env bash
# ==============================================================================
# audio.cpp · fnOS native fpk —— 构建脚本（在 debian:12 容器内运行）
#
# 为什么在 debian:12 里编：fnOS = Debian 12（glibc 2.36）。官方 release 的 Linux
# 二进制是在 Ubuntu 24.04（glibc 2.39）上编的，直接拿到 fnOS 会报
# GLIBC_2.38/GLIBCXX_3.4.32 not found。在 bookworm 里编出的产物才与 fnOS 兼容。
#
# 为什么用 conda gcc-13 而非 bookworm 自带 gcc-12：audio.cpp 文档硬性要求 GCC≥13，
# 且 earshot_vad 的 `#pragma GCC target("avx2")`+always_inline intrinsic 在 gcc-12
# 上编译失败；而 bookworm 源里没有 gcc-13。conda-forge 的 gcc-13 自带 glibc 2.34
# 的 sysroot，产物只要求 GLIBC≤2.34（<fnOS 2.36），既满足 gcc-13 又守住 glibc 下限。
# 代价：产物要 GLIBCXX_3.4.32（>fnOS 系统的 3.4.30），故 3.1a 把 conda 的
# libstdc++.so.6/libgcc_s.so.1/libgomp.so.1 一并打进 bin/（rpath=$ORIGIN 命中）。
#
# 输入（环境变量）：
#   SRC_DIR   audio.cpp 源码目录（含 CMakeLists.txt），必填
#   REPO_DIR  本 fnos-audiocpp-native 目录（提供 payload/etc/server.json.template），必填
#   OUT_TGZ   输出的 app.tgz 路径，默认 $REPO_DIR/dist/app.tgz
#   JOBS      并行编译数，默认 nproc
#   AUDIOCPP_VERSION  编进二进制的版本串（-DAUDIOCPP_VERSION），默认 dev
#   AUDIOCPP_CONDA_CHANNEL   conda 通道，默认 conda-forge（CI 官方）；本地 CN 可设清华镜像
#   AUDIOCPP_MINICONDA_URL   Miniconda 下载地址，默认官方；本地 CN 可设清华镜像
#   VULKAN_HEADERS_VERSION  默认 v1.3.290（bookworm 的 239 太旧）
#
# 产出：app.tgz —— 解压到 fnOS 的 TRIM_APPDEST(target/) 后含：
#   bin/audiocpp_server, bin/audiocpp_cli, bin/audiocpp_model_manager, bin/*.so*
#   bin/libstdc++.so.6*, bin/libgcc_s.so.1, bin/libgomp.so.1*（conda gcc-13 运行时）
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

# ── 1. apt 依赖（不含编译器，编译器走下面的 conda gcc-13）──────────────────────
# 为什么不用 bookworm 自带的 gcc-12：audio.cpp 文档（README/docs/build/linux.md）硬性
# 要求 “GCC 13 or newer”，且 src/community_models/earshot_vad/runtime.cpp 用
# `#pragma GCC target("avx2")` + always_inline AVX intrinsic，在 gcc-12 上会
# “inlining failed … target specific option mismatch” 直接编译失败（实测 74% 处挂掉）。
# 而 bookworm 源里**没有** gcc-13（它在 trixie/sid，glibc 2.40 又会破坏 fnOS 兼容）。
# 解法：debian:12 容器里装 conda-forge 的 gcc-13——它自带 glibc 2.34 的 sysroot，
# 编出的产物只要求 GLIBC≤2.34（< fnOS 的 2.36），既满足 gcc-13 又守住 glibc 下限。
log "安装 apt 依赖（bookworm，清华/官方源均可）"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    cmake make git binutils patchelf ca-certificates curl \
    glslc libvulkan-dev spirv-headers libgomp1
command -v glslc >/dev/null || die "glslc 安装失败"
command -v patchelf >/dev/null || die "patchelf 安装失败"

# ── 1a. conda-forge gcc-13（CI 用官方通道；本地 CN 可设 AUDIOCPP_CONDA_CHANNEL 走清华）──
# --override-channels 绕开 conda 默认通道的 ToS 门槛，只用 conda-forge。
# 切记：自定义变量不能叫 CONDA_CHANNEL/CONDA_CHANNELS——conda 把 CONDA_* 环境变量当成
# 自己的配置，安装器会因 channel/channels 别名冲突报 MultipleKeysError 而失败。
CONDA_DIR="${AUDIOCPP_CONDA_DIR:-/opt/conda}"
CONDA_CHANNEL_URL="${AUDIOCPP_CONDA_CHANNEL:-conda-forge}"
MINICONDA_URL="${AUDIOCPP_MINICONDA_URL:-https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh}"
CC_BIN="$CONDA_DIR/bin/x86_64-conda-linux-gnu-gcc"
CXX_BIN="$CONDA_DIR/bin/x86_64-conda-linux-gnu-g++"
if [[ -x "$CXX_BIN" ]] && "$CXX_BIN" -dumpversion 2>/dev/null | grep -q '^13'; then
  log "复用已存在的 conda gcc-13（$("$CXX_BIN" --version | head -1)）"
else
  log "安装 conda-forge gcc-13（channel=${CONDA_CHANNEL_URL}）"
  # 清掉可能干扰安装器的 CONDA_* 配置变量（构建容器里本就不该有）
  unset CONDA_CHANNEL CONDA_CHANNELS CONDA_PREFIX CONDA_DEFAULT_ENV 2>/dev/null || true
  curl -fsSL "$MINICONDA_URL" -o /tmp/miniconda.sh || die "下载 Miniconda 失败：$MINICONDA_URL"
  bash /tmp/miniconda.sh -b -u -p "$CONDA_DIR" >/dev/null && rm -f /tmp/miniconda.sh
  export PATH="$CONDA_DIR/bin:$PATH"   # 刚装完 conda 还不在 PATH，必须先导出再用
  case "$CONDA_CHANNEL_URL" in http://*) SSLV=false ;; *) SSLV=true ;; esac
  printf 'ssl_verify: %s\nchannel_priority: flexible\n' "$SSLV" > "$CONDA_DIR/.condarc"
  conda install -y --override-channels -c "$CONDA_CHANNEL_URL" \
      gcc_linux-64=13 gxx_linux-64=13 sysroot_linux-64 >/dev/null || die "conda 安装 gcc-13 失败"
  conda clean -afy >/dev/null 2>&1 || true
fi
export PATH="$CONDA_DIR/bin:$PATH"
[[ -x "$CXX_BIN" ]] || die "conda g++ 不存在：$CXX_BIN"
SYSROOT="$("$CXX_BIN" -print-sysroot)"
log "conda gcc-13：$("$CXX_BIN" --version | head -1)"
echo "  sysroot=$SYSROOT（glibc 下限 2.34，产物可在 fnOS glibc 2.36 上运行）"

# ── 1b. Vulkan-Headers 装进 conda sysroot（apt 的 1.3.239 太旧）────────────────
# ggml-vulkan.cpp 用到 VK_EXT_layer_settings（vk::LayerSettingEXT 等），需
# VK_HEADER_VERSION ≥ 275；bookworm 的 libvulkan-dev 只有 239，会报
# "'LayerSettingEXT' is not a member of 'vk'"。conda gcc 只搜自己的 sysroot，
# 所以必须把新版头装进 $SYSROOT/usr（装 /usr 它看不到）。纯头文件，不动 glibc/loader。
VK_HDR_VER="${VULKAN_HEADERS_VERSION:-v1.3.290}"
log "安装 Vulkan-Headers ${VK_HDR_VER} → sysroot/usr"
rm -rf /tmp/vk-headers
git clone --depth 1 --branch "${VK_HDR_VER}" \
    https://github.com/KhronosGroup/Vulkan-Headers.git /tmp/vk-headers \
    || die "克隆 Vulkan-Headers 失败（检查网络/ tag ${VK_HDR_VER}）"
export CC="$CC_BIN" CXX="$CXX_BIN"
cmake -S /tmp/vk-headers -B /tmp/vk-headers/build -DCMAKE_INSTALL_PREFIX="$SYSROOT/usr" >/dev/null
cmake --install /tmp/vk-headers/build >/dev/null
NEWVER=$(grep -m1 'define VK_HEADER_VERSION ' "$SYSROOT/usr/include/vulkan/vulkan_core.h" | grep -oE '[0-9]+')
echo "  sysroot VK_HEADER_VERSION=${NEWVER}"
[[ "${NEWVER:-0}" -ge 275 ]] || die "Vulkan-Headers 升级失败（仍为 ${NEWVER:-未知}）"

# ── 1c. SPIRV-Headers 拷进 sysroot（ggml-vulkan 的 spv:: 命名空间需要）──────────
# apt 的 spirv-headers 装在 /usr/include/spirv，但 conda gcc 看不到 /usr/include，
# 否则 ggml-vulkan.cpp 报 "'spv' has not been declared"。拷进 sysroot 即可。
if [[ -d /usr/include/spirv && ! -d "$SYSROOT/usr/include/spirv" ]]; then
  cp -a /usr/include/spirv "$SYSROOT/usr/include/"
  log "已拷贝 SPIRV-Headers → sysroot/usr/include/spirv"
fi
[[ -f "$SYSROOT/usr/include/spirv/unified1/spirv.hpp" ]] || die "sysroot 缺 spirv/unified1/spirv.hpp"

# ── 2. 配置 + 构建（对齐官方 release.yml 的 linux-vulkan-**portable** 配方）──────
# portable（非 native）：ENGINE_ENABLE_NATIVE_CPU=OFF + CPU_ALL_VARIANTS=ON，把 CPU
# 后端编成按 ISA 分派的动态库，运行时自选，避免在用户各不相同的 NAS CPU 上 SIGILL。
# 链接期加 -L/usr/lib/x86_64-linux-gnu 让 conda gcc 能找到 apt 的 libvulkan 等。
log "cmake 配置（conda gcc-13，Vulkan portable，DEPLOYMENT_BUILD=ON）"
LINKDIR=/usr/lib/x86_64-linux-gnu
cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCMAKE_EXE_LINKER_FLAGS="-L${LINKDIR} -Wl,-rpath-link,${LINKDIR}" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L${LINKDIR} -Wl,-rpath-link,${LINKDIR}" \
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

# 校验：产物应只要求 GLIBC≤2.36（conda sysroot 实际给到 2.34）。
# GLIBCXX 会高至 3.4.32（gcc-13），超过 fnOS 系统 libstdc++ 的 3.4.30——
# 因此 3.1a 会把 conda 的 libstdc++.so.6/libgcc_s.so.1/libgomp.so.1 一并打进 bin/。
log "校验 glibc 符号版本（应 ≤ GLIBC_2.36）"
MAXGLIBC=$(objdump -T "$SRC_DIR/build/bin/audiocpp_server" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1 || echo "GLIBC_?")
MAXGXX=$(objdump -T "$SRC_DIR/build/bin/audiocpp_server" 2>/dev/null \
    | grep -oE 'GLIBCXX_[0-9.]+' | sort -V | tail -1 || echo "GLIBCXX_?")
echo "  最高 GLIBC=${MAXGLIBC}  最高 GLIBCXX=${MAXGXX}"
case "$MAXGLIBC" in
  GLIBC_2.3[0-6]|GLIBC_2.[0-2][0-9]|GLIBC_?) : ;;
  *) echo "  警告：${MAXGLIBC} 高于 2.36，fnOS 可能跑不了！" >&2 ;;
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

# 3.1a 捆绑 conda gcc-13 的 C++ 运行时（fnOS 系统 libstdc++ 只到 GLIBCXX_3.4.30，
# 而产物要 3.4.32）。这些库自身只要求 GLIBC≤2.17，放进 bin/ 后经 rpath=$ORIGIN 命中。
log "捆绑 conda 运行时：libstdc++.so.6 / libgcc_s.so.1 / libgomp.so.1"
for lib in libstdc++.so.6 libgcc_s.so.1 libgomp.so.1; do
  [[ -n "$(find "$CONDA_DIR/lib" -maxdepth 1 -name "${lib}*" | head -1)" ]] \
      || die "conda 运行时缺失：$lib"
  cp -Pf "$CONDA_DIR/lib/${lib}"* "$STAGE/bin/"
done
# 补齐 soname 符号链接：conda 的 libgomp 只有 libgomp.so.1.0.0、没有 libgomp.so.1，
# 缺了它 loader 会回退到系统 /lib（fnOS 未必装 libgomp1）→ 按 SONAME 建软链兜底。
for f in "$STAGE/bin"/lib*.so.*; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  soname=$(objdump -p "$f" 2>/dev/null | awk '/SONAME/{print $2}')
  [[ -n "$soname" && ! -e "$STAGE/bin/$soname" ]] && ln -sf "$(basename "$f")" "$STAGE/bin/$soname"
done

# 3.1b 把 RPATH 规整为纯 $ORIGIN（conda 会留下 $ORIGIN:/opt/conda/lib，后者在 fnOS
# 上不存在但无害；清掉更干净，也避免任何绝对路径搜索）。
log "patchelf 规整 RPATH → \$ORIGIN"
find "$STAGE/bin" -maxdepth 1 -type f -perm -u+x -exec patchelf --set-rpath '$ORIGIN' {} \;
find "$STAGE/bin" -maxdepth 1 -name '*.so*' -type f -exec patchelf --set-rpath '$ORIGIN' {} \;

# 3.1c 模型自动下载脚本（install_callback 后台调用 / main download-models 前台调用）
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
