#!/bin/bash
# ==============================================================================
# audio.cpp · fnOS native fpk —— 模型自动下载（按初始化配置文件 server.json 驱动）
#
# 读取渲染后的 server.json：取其 models_root 与声明的每个模型（family + path），
# 对“已配置但文件缺失”的模型，用随包附带的 audiocpp_model_manager 从 HuggingFace
# 下载对应 GGUF 包。下载落点与 server.json 里配置的 path 完全一致（manager 按
# spec 的 target_directory/strip_prefix 归位），因此下载完即可被 lazy-load 直接使用。
#
# 用法：provision-models.sh <server.json> <bin_dir> [log_dir]
#   server.json  已渲染（__DATA_ROOT__ 已替换）的配置
#   bin_dir      含 audiocpp_model_manager 的目录（一般 = APPDEST/bin）
#   log_dir      进度/状态输出目录（默认取 server.json 同级 logs，或 /tmp）
#
# 设计：安装时后台跑（约 2.5 GB），也可由 `cmd/main download-models` 前台重跑。
# 幂等：已存在的模型跳过；失败不删已下载内容，可重试续跑。
# ==============================================================================
set -u

CONFIG="${1:-}"; BIN_DIR="${2:-}"; LOG_DIR="${3:-}"
[[ -f "$CONFIG" ]] || { echo "provision: 找不到配置 $CONFIG" >&2; exit 1; }
[[ -x "$BIN_DIR/audiocpp_model_manager" ]] || { echo "provision: 找不到 $BIN_DIR/audiocpp_model_manager" >&2; exit 1; }
MM="$BIN_DIR/audiocpp_model_manager"

# portable 构建下后端/依赖是 bin/ 里的 .so（rpath=$ORIGIN 已能定位）；再显式给一份
# LD_LIBRARY_PATH 兜底 dlopen，且不依赖调用方（install_callback 未导出它，main 导出了）。
export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"

# family → 默认 GGUF 包 id（取自上游 model_specs/*.json 的 default 包）
pkg_id_for_family() {
    case "$1" in
        cosyvoice3) echo "cosyvoice3_q8_0" ;;
        sense_asr)  echo "sensevoice_small_q8" ;;
        *)          echo "" ;;
    esac
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
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_DIR/model-download.log"; }

set_status() { echo "$1" > "$STATUS" 2>/dev/null || true; }

log "模型根目录：$MODELS_ROOT"
set_status "running"

NEED=0; FAIL=0
while IFS=$'\t' read -r kind family path; do
    [[ "$kind" == "MODEL" ]] || continue
    if [[ -z "$path" ]]; then log "跳过无 path 的条目（family=$family）"; continue; fi
    if [[ -f "$path" ]]; then
        log "已存在，跳过：$path"
        continue
    fi
    pid="$(pkg_id_for_family "$family")"
    if [[ -z "$pid" ]]; then
        log "警告：family='$family' 无内置下载映射，请手动放置：$path"
        continue
    fi
    NEED=$((NEED+1))
    log "下载 $family → 包 '$pid'（目标 $path）"
    if "$MM" install "$pid" --models-dir "$MODELS_ROOT" >>"$LOG_DIR/model-download.log" 2>&1; then
        if [[ -f "$path" ]]; then
            log "完成：$path"
        else
            log "警告：'$pid' 安装成功但未见预期文件 $path（可能包内文件名不同），请核对"
            FAIL=$((FAIL+1))
        fi
    else
        log "错误：下载 '$pid' 失败（网络/磁盘？可稍后重试 cmd/main download-models）"
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
