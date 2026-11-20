#!/usr/bin/env bash
set -euo pipefail

log() { printf '\n==> %s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

[[ -n "${SRC_DIR:-}" && -f "$SRC_DIR/CMakeLists.txt" ]] || die "SRC_DIR 必须指向 audio.cpp 源码"
[[ -n "${REPO_DIR:-}" ]] || die "必须设置 REPO_DIR"
OUT_TGZ="${OUT_TGZ:-$REPO_DIR/dist/app.tgz}"
JOBS="${JOBS:-$(nproc)}"
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 12 ]] || die "必须使用 Debian 12 构建"
[[ "$(getconf GNU_LIBC_VERSION)" == 'glibc 2.36' ]] || die "必须使用 glibc 2.36"

log "安装 Debian 12 构建依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    cmake make git binutils patchelf ca-certificates curl python3 \
    glslc libvulkan-dev spirv-headers libgomp1

CONDA_DIR="${AUDIOCPP_CONDA_DIR:-/opt/conda}"
CONDA_CHANNEL_URL="${AUDIOCPP_CONDA_CHANNEL:-conda-forge}"
MINICONDA_URL="${AUDIOCPP_MINICONDA_URL:-https://repo.anaconda.com/miniconda/Miniconda3-py312_25.1.1-2-Linux-x86_64.sh}"
MINICONDA_SHA256=4766d85b5f7d235ce250e998ebb5a8a8210cbd4f2b0fea4d2177b3ed9ea87884
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [[ ! -x "$CONDA_DIR/bin/conda" ]]; then
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 1800 "$MINICONDA_URL" -o "$WORK/miniconda.sh"
    printf '%s  %s\n' "$MINICONDA_SHA256" "$WORK/miniconda.sh" | sha256sum -c -
    unset CONDA_CHANNEL CONDA_CHANNELS CONDA_PREFIX CONDA_DEFAULT_ENV
    bash "$WORK/miniconda.sh" -b -p "$CONDA_DIR"
fi
export PATH="$CONDA_DIR/bin:$PATH"
conda install -y --override-channels -c "$CONDA_CHANNEL_URL" \
    gcc_linux-64=13.4.0 gxx_linux-64=13.4.0 sysroot_linux-64=2.34 \
    libgcc=13.4.0 libstdcxx=13.4.0 libgomp=13.4.0
CC_BIN="$CONDA_DIR/bin/x86_64-conda-linux-gnu-gcc"
CXX_BIN="$CONDA_DIR/bin/x86_64-conda-linux-gnu-g++"
[[ "$("$CXX_BIN" -dumpfullversion)" == 13.4.0 ]] || die "编译器版本不符"
SYSROOT="$("$CXX_BIN" -print-sysroot)"
export CC="$CC_BIN" CXX="$CXX_BIN"

log "安装 Vulkan-Headers v1.3.290 到 conda sysroot"
git clone --depth 1 --branch v1.3.290 \
    https://github.com/KhronosGroup/Vulkan-Headers.git "$WORK/vulkan-headers"
cmake -S "$WORK/vulkan-headers" -B "$WORK/vulkan-headers/build" -DCMAKE_INSTALL_PREFIX="$SYSROOT/usr"
cmake --install "$WORK/vulkan-headers/build"
cp -a /usr/include/spirv "$SYSROOT/usr/include/"

log "编译 Vulkan portable 版本"
LINKDIR=/usr/lib/x86_64-linux-gnu
cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCMAKE_EXE_LINKER_FLAGS="-L${LINKDIR} -Wl,-rpath-link,${LINKDIR}" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L${LINKDIR} -Wl,-rpath-link,${LINKDIR}" \
    -DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=ON -DENGINE_ENABLE_OPENMP=ON \
    -DENGINE_ENABLE_NATIVE_CPU=OFF -DENGINE_ENABLE_CPU_ALL_VARIANTS=ON \
    -DAUDIOCPP_VERSION="${AUDIOCPP_VERSION:-dev}" -DAUDIOCPP_DEPLOYMENT_BUILD=ON \
    -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=ON -DENGINE_ENABLE_LLAMAFILE=ON \
    -DENGINE_BUILD_EXAMPLES=OFF -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_WARMBENCH=OFF
cmake --build "$SRC_DIR/build" --parallel "$JOBS" \
    --target audiocpp_server --target audiocpp_cli --target audiocpp_model_manager

STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/etc" "$STAGE/assets/silero_vad" "$STAGE/assets/demo_voices" "$STAGE/licenses"
for binary in audiocpp_server audiocpp_cli audiocpp_model_manager; do
    [[ -x "$SRC_DIR/build/bin/$binary" ]] || die "缺少 $binary"
    cp "$SRC_DIR/build/bin/$binary" "$STAGE/bin/"
done
find "$SRC_DIR/build" -name '*.so*' -exec cp -Pf {} "$STAGE/bin/" \;
for lib in libstdc++.so.6 libgcc_s.so.1 libgomp.so.1; do
    cp -Pf "$CONDA_DIR/lib/${lib}"* "$STAGE/bin/"
done
for file in "$STAGE/bin"/lib*.so.*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    soname="$(objdump -p "$file" | awk '/SONAME/{print $2}')"
    if [[ -n "$soname" && ! -e "$STAGE/bin/$soname" ]]; then
        ln -s "$(basename "$file")" "$STAGE/bin/$soname"
    fi
done
for file in "$STAGE/bin"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    patchelf --set-rpath "\$ORIGIN" "$file"
done
cp "$REPO_DIR/payload/bin/"*.sh "$REPO_DIR/payload/bin/"*.py "$STAGE/bin/"
chmod 755 "$STAGE/bin/"*.sh "$STAGE/bin/"*.py
cp "$REPO_DIR/payload/etc/server.json.template" "$REPO_DIR/payload/etc/models.lock.json" "$STAGE/etc/"
cp "$SRC_DIR/assets/framework/models/silero_vad/silero_vad_16k.safetensors" "$STAGE/assets/silero_vad/"
cp -a "$SRC_DIR/webui/native/demo_voices/." "$STAGE/assets/demo_voices/"

log "保留第三方许可证与精确构建清单"
python3 - "$SRC_DIR" "$CONDA_DIR" "$STAGE" "$REPO_DIR" <<'PY'
import json, os, pathlib, shutil, subprocess, sys
src, conda, stage, repo = map(pathlib.Path, sys.argv[1:])
for folder in [src / 'external', src / 'assets', src / 'src', src / 'build/_deps', src / 'LICENSE']:
    for path in ([folder] if folder.is_file() else folder.rglob('*')):
        if path.is_file() and path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
            target = stage / 'licenses/audio.cpp' / path.relative_to(src)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
for path in (conda / 'pkgs').glob('*/info/licenses'):
    shutil.copytree(path, stage / 'licenses/conda' / path.parent.parent.name, dirs_exist_ok=True)
shutil.copytree(conda / 'conda-meta', stage / 'licenses/conda-meta')
info = {
    'version': os.environ.get('AUDIOCPP_VERSION', 'dev'),
    'upstream_sha': subprocess.check_output(['git', '-C', str(src), 'rev-parse', 'HEAD'], text=True).strip(),
    'packager_sha': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
    'compiler': subprocess.check_output([os.environ['CXX'], '--version'], text=True).splitlines()[0],
    'conda_explicit': subprocess.check_output([str(conda / 'bin/conda'), 'list', '--explicit'], text=True).splitlines(),
    'debian_packages': subprocess.check_output(['dpkg-query', '-W'], text=True).splitlines(),
}
(stage / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
PY
python3 "$REPO_DIR/tools/check_payload.py" --stage "$STAGE" --smoke
mkdir -p "$(dirname "$OUT_TGZ")"
tar -czf "$OUT_TGZ" -C "$STAGE" .
log "完成：$OUT_TGZ"
