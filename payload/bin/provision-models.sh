#!/bin/bash
# ==============================================================================
# audio.cpp · fnOS native fpk —— 模型自动下载（按初始化配置文件 server.json 驱动）
#
# 读取渲染后的 server.json：取其 models_root 与声明的每个模型（family + path），
# 对“已配置但文件缺失”的模型，用 curl 直接从镜像源下载对应 GGUF，落点与
# server.json 里配置的 path 完全一致，因此下载完即可被 lazy-load 直接使用。
#
# 下载源（默认 modelscope.cn，国内 CDN 加速）：
#   AUDIOCPP_MODEL_SOURCE=modelscope   # 默认：modelscope 优先，失败回退 HF → hf-mirror
#   AUDIOCPP_MODEL_SOURCE=hf           # HuggingFace 优先，回退 hf-mirror → modelscope
#   AUDIOCPP_MODEL_SOURCE=hf-mirror    # hf-mirror.com 优先（注意：Xet 仓库会 302 弹回 HF CDN）
#   也可用 AUDIOCPP_MS_BASE_URL / AUDIOCPP_HF_BASE_URL 覆盖各自基址。
#
# 为什么默认 modelscope：这两个 GGUF 在 HF 上是 Xet 存储，hf-mirror 的 /resolve
# 只是 302 弹回 HF 自己的 cas-bridge.xethub.hf.co（海外 CDN），基本不加速；
# modelscope 则原生托管字节（cdn-lfs-cn-*.modelscope.cn），国内实测明显更快。
#
# 用法：provision-models.sh <server.json> <bin_dir> [log_dir]
#   server.json  已渲染（__DATA_ROOT__ 已替换）的配置
#   bin_dir      含 audiocpp_model_manager 的目录（一般 = APPDEST/bin），作兜底下载器
#   log_dir      进度/状态输出目录（默认取 server.json 同级 logs，或 /tmp）
#
# 设计：安装时后台跑（约 2.5 GB），也可由 `cmd/main download-models` 前台重跑。
# 幂等：已存在的模型跳过；下载写 .part 并支持断点续传（curl -C -），失败不删已下内容。
# ==============================================================================
set -u

CONFIG="${1:-}"; BIN_DIR="${2:-}"; LOG_DIR="${3:-}"
[[ -f "$CONFIG" ]] || { echo "provision: 找不到配置 $CONFIG" >&2; exit 1; }
MM="$BIN_DIR/audiocpp_model_manager"

# portable 构建下后端/依赖是 bin/ 里的 .so（rpath=$ORIGIN 已能定位）；再显式给一份
# LD_LIBRARY_PATH 兜底 dlopen（供 model_manager 兜底路径使用）。
export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"

# ── 下载源基址（可被环境变量覆盖）──────────────────────────────────────────────
MS_BASE="${AUDIOCPP_MS_BASE_URL:-https://www.modelscope.cn/models}"
HF_BASE="${AUDIOCPP_HF_BASE_URL:-https://huggingface.co}"
HFM_BASE="${AUDIOCPP_HF_MIRROR_BASE_URL:-https://hf-mirror.com}"
SOURCE="$(printf '%s' "${AUDIOCPP_MODEL_SOURCE:-modelscope}" | tr '[:upper:]' '[:lower:]')"

# family → 下载描述（repo<TAB>revision<TAB>repo 内文件路径）
# modelscope 与 HF 的 repo 命名空间/revision 可能不同，分别维护。
ms_desc() {
    case "$1" in
        cosyvoice3) printf 'audio-cpp/audio.cpp-gguf\tmaster\tCosyVoice3-GGUF/cosyvoice3-q8_0.gguf' ;;
        sense_asr)  printf 'callxxa/SenseVoiceSmall-GGUF-audiocpp\tmaster\tsensevoice-small-q8-audiocpp-v1.gguf' ;;
        *)          return 1 ;;
    esac
}
hf_desc() {
    case "$1" in
        cosyvoice3) printf 'audio-cpp/audio.cpp-gguf\tmain\tCosyVoice3-GGUF/cosyvoice3-q8_0.gguf' ;;
        sense_asr)  printf 'FunAudioLLM/SenseVoiceSmall-GGUF-audiocpp\t5c3fcfe748a8714216bc135476d5863084fddb72\tsensevoice-small-q8-audiocpp-v1.gguf' ;;
        *)          return 1 ;;
    esac
}
# family → model_manager 包 id（取自上游 model_specs/*.json 的 default 包，作兜底）
pkg_id_for_family() {
    case "$1" in
        cosyvoice3) echo "cosyvoice3_q8_0" ;;
        sense_asr)  echo "sensevoice_small_q8" ;;
        *)          echo "" ;;
    esac
}

# 按 AUDIOCPP_MODEL_SOURCE 决定尝试顺序（源名列表）
source_order() {
    case "$SOURCE" in
        hf)        printf 'hf hf-mirror modelscope' ;;
        hf-mirror) printf 'hf-mirror hf modelscope' ;;
        modelscope|*) printf 'modelscope hf hf-mirror' ;;
    esac
}
base_for() {
    case "$1" in
        modelscope) echo "$MS_BASE" ;;
        hf-mirror)  echo "$HFM_BASE" ;;
        hf)         echo "$HF_BASE" ;;
    esac
}
# 给定源名+family，产出完整下载 URL；该源无此 family 映射则返回非 0
url_for() {
    local src="$1" family="$2" desc repo rev file base
    case "$src" in
        modelscope) desc="$(ms_desc "$family")" || return 1 ;;
        hf|hf-mirror) desc="$(hf_desc "$family")" || return 1 ;;
        *) return 1 ;;
    esac
    IFS=$'\t' read -r repo rev file <<<"$desc"
    base="$(base_for "$src")"
    printf '%s/%s/resolve/%s/%s' "$base" "$repo" "$rev" "$file"
}

# ── 从 server.json 解析 models_root 与 models[]（family<TAB>path）──────────────
parse_json() {
    python3 - "$CONFIG" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("parse error: %s\n" % e); sys.exit(2)
print("ROOT\t" + str(d.get("models_root", "")))
for m in d.get("models", []) or []:
    print("MODEL\t%s\t%s" % (m.get("family", ""), m.get("path", "")))
PY
}

if command -v python3 >/dev/null 2>&1; then
    PARSED="$(parse_json)" || { echo "provision: server.json 解析失败" >&2; exit 1; }
else
    # 无 python3 时的兜底：从模板已知结构 grep 出 root 与两个默认模型路径
    echo "provision: 未找到 python3，使用内置默认模型清单兜底" >&2
    ROOT="$(grep -oE '"models_root"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG" | head -1 | sed -E 's/.*"models_root"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    PARSED="ROOT	${ROOT}
MODEL	cosyvoice3	${ROOT}/CosyVoice3-GGUF/cosyvoice3-q8_0.gguf
MODEL	sense_asr	${ROOT}/SenseVoice-Small-GGUF/sensevoice-small-q8-audiocpp-v1.gguf"
fi

MODELS_ROOT="$(printf '%s\n' "$PARSED" | awk -F'\t' '$1=="ROOT"{print $2; exit}')"
[[ -n "$MODELS_ROOT" ]] || { echo "provision: server.json 里没有 models_root" >&2; exit 1; }

[[ -n "$LOG_DIR" ]] || LOG_DIR="$(dirname "$CONFIG")/../logs"
mkdir -p "$LOG_DIR" "$MODELS_ROOT" 2>/dev/null || true
STATUS="$LOG_DIR/model-download.status"
DLOG="$LOG_DIR/model-download.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$DLOG"; }
set_status() { echo "$1" > "$STATUS" 2>/dev/null || true; }

HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1

# curl 下载到 dest（断点续传 + 重试）；成功且非空返回 0
curl_download() {
    local url="$1" dest="$2" tmp="${2}.part"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    curl -fL --connect-timeout 20 --retry 3 --retry-delay 5 -C - -o "$tmp" "$url" >>"$DLOG" 2>&1
    local rc=$?
    if [[ $rc -eq 0 && -s "$tmp" ]]; then
        mv -f "$tmp" "$dest" && return 0
    fi
    return 1
}

# model_manager 兜底下载（无 curl，或所有 curl 源都失败时）
mm_download() {
    local family="$1" pid
    [[ -x "$MM" ]] || return 1
    pid="$(pkg_id_for_family "$family")"
    [[ -n "$pid" ]] || return 1
    log "  兜底：audiocpp_model_manager install $pid"
    "$MM" install "$pid" --models-dir "$MODELS_ROOT" >>"$DLOG" 2>&1
}

log "模型根目录：$MODELS_ROOT"
log "下载源优先级：$(source_order)（AUDIOCPP_MODEL_SOURCE=${SOURCE}）"
set_status "running"

NEED=0; FAIL=0
while IFS=$'\t' read -r kind family path; do
    [[ "$kind" == "MODEL" ]] || continue
    if [[ -z "$path" ]]; then log "跳过无 path 的条目（family=$family）"; continue; fi
    if [[ -f "$path" ]]; then
        log "已存在，跳过：$path"
        continue
    fi
    NEED=$((NEED+1))
    log "下载 $family → $path"

    ok=0
    if [[ "$HAVE_CURL" -eq 1 ]]; then
        for src in $(source_order); do
            url="$(url_for "$src" "$family")" || continue
            log "  尝试 [$src] $url"
            if curl_download "$url" "$path"; then
                log "  完成（$src）：$path"
                ok=1; break
            else
                log "  失败（$src），换下一个源…"
            fi
        done
    else
        log "  未找到 curl，直接用 model_manager 兜底"
    fi

    if [[ "$ok" -eq 0 ]]; then
        if mm_download "$family" && [[ -f "$path" ]]; then
            log "  完成（model_manager）：$path"
            ok=1
        fi
    fi

    if [[ "$ok" -eq 0 ]]; then
        log "错误：$family 全部下载源均失败（网络/磁盘？可稍后重试 cmd/main download-models）"
        FAIL=$((FAIL+1))
    fi
done <<< "$(printf '%s\n' "$PARSED" | grep -E '^MODEL')"

if [[ "$NEED" -eq 0 ]]; then
    log "所有已配置模型均已就位，无需下载。"
    set_status "done"
elif [[ "$FAIL" -eq 0 ]]; then
    log "全部模型下载完成（本次 $NEED 个）。"
    set_status "done"
else
    log "结束，但有 $FAIL 项失败。可重跑：/var/apps/audiocpp/cmd/main download-models"
    set_status "failed"
fi
exit 0
