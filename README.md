# fnos-audiocpp-native

在 **Debian 12 / glibc 2.36** 中编译 audio.cpp 的 **Vulkan portable** 版本，用官方 **fnpack 1.2.3** 打包为飞牛 fnOS 可安装的 `.fpk`。

NAS 运行原生进程，不需要 Docker/podman。纯 API 模式 `--no-ui`，默认端口 **58009**，为 Home Assistant 提供中文 TTS（CosyVoice3）和 STT（SenseVoice）。CUDA 不包含在此包中。

## 1. 构建与发布

版本统一为 **`X.Y.Z-NNN`**：上游标准正式版本加三位打包修订号，例如 `0.9.4-003`。上游源码锁定 `vX.Y.Z` 正式 Release，而非 main。

| 入口 | 行为 |
| --- | --- |
| 手动运行 `build-fnos-fpk` | 预览构建，仅产出 artifact，不发布、不更新 Moo；修订号留空取现有最大值加一 |
| 推送 `vX.Y.Z-NNN` tag | 构建、验证、发布 Release，再通过 `workflow_call` 更新 Moo |
| `watch-upstream-release` | 每天 UTC 03:20 检查上游标准正式 Release，全自动构建及发布 |
| 手动运行 watcher | `base` 可指定标准版本；`force=true` 创建新修订号，不替换旧包 |
| 手动运行 `Update moo.json` | 必须填写已有 Release tag，只恢复索引同步，不重建包 |

不接受不带修订号的本仓库 tag，也不接受 `v0.9.2-drama3-base-small` 等专项后缀版本；监听器会跳过专项版本及 prerelease，避免构建错源码和版本排序歧义。三位修订号达到 `999` 后停止并报错。

### 自动恢复与不可变发布

“存在 tag”不再表示成功，监听器还会核对 Release 附件、大小、SHA256 和 Moo 节点：

- 无附件且尚未索引：允许重建；若旧 tag 指向不同打包源码，递增修订号，绝不移动旧 tag。
- 附件已完整上传、Moo 未完成：复用附件，只补发布草稿/同步索引。
- Release 与索引均完成：不重复工作。
- 上传中遗留的零字节 `starter` 占位附件：上传前清理后重试；非空附件不会被覆盖。
- 已被 Moo 索引的附件丢失或哈希变化：明确失败，不偷偷重建同版本。恢复原始附件或使用新修订号。
- 主分支同步冲突/分支保护：工作流失败并给出注解；下次监听或手动重跑会重新读取索引。

新 Release 先建草稿，tag 绑定本次打包 commit；上传后验证字节一致再公开。构建发布统一排队，所有 Moo 更新按 main 分支串行化。GitHub 的并发组只保留有限待运行任务，漏排时每日监听会再次核对状态。

`GITHUB_TOKEN` 创建的 Release 不会再触发普通 `release` 工作流，所以自动链路使用 `workflow_call`，不依赖二次事件触发。可复用工作流的事件名继承调用方，版本选择通过显式输入识别。

### 构建检查

- Debian 12 环境强制检查；GCC/G++ 13.4.0、sysroot 2.34、对应 GCC 运行库固定版本。
- 固定 Miniconda 安装器和 fnpack 版本及 SHA256；镜像下载必须提供相同文件字节。
- Vulkan-Headers 固定 `v1.3.290`；`ENGINE_ENABLE_NATIVE_CPU=OFF`、`ENGINE_ENABLE_CPU_ALL_VARIANTS=ON`，避免按 CI CPU 编译。
- 随包携带 C++/OpenMP 运行库，RPATH 统一为 `$ORIGIN`；扫描全部 ELF 的 GLIBC 要求和动态依赖。
- VAD、四段参考音频、prompt_text、运行脚本及配置缺失时禁止发布。
- 在 Debian 12 内用 CPU 后端启动 `/health` 和 `/v1/models` 冒烟检查；这不是 GPU 或真实推理测试，NAS 仍须完成下方 TTS→STT 验证。
- 官方 fnpack 产包后检查外层结构、载荷、版本和平台。
- `build-info.json` 记录上游/打包源码 SHA、编译器、conda 精确包清单及 Debian 包版本；载荷 `licenses/` 保留上游、内嵌依赖及 conda 缓存中的许可文件。

Debian apt 仓库和 conda 包构建号仍可能更新，构建清单用于追溯，并不承诺二进制逐字节可复现。重新构建已发布版本必须递增修订号。

## 2. 安装、配置与目录

前提：x86-64 fnOS、可用 Vulkan 驱动与 `/dev/dri/renderD*`、系统 `python3`（3.9+，支持 pidfd）、`curl`。安装前会检查必要命令和 pidfd 支持。

1. 应用中心 → 手动安装 → 选择 `.fpk`。
2. 安装脚本预置 VAD/参考音频，将配置放到文件管理 → 应用文件 → **audiocpp/server.json**。
3. 以应用用户后台下载默认模型，查看共享 `logs/model-download.status`。
4. 启动应用，执行第 4 节验证，然后连接 HA。

目录概要（具体存储卷由 fnOS 决定）：

```text
/var/apps/audiocpp/
├── cmd/main                        # start/stop/restart/status/download-models/diagnose
├── config/privilege                # package 用户，join-groups: video,render
├── config/resource                 # data-share，不负责防火墙放行
├── target/                         # 程序载荷，升级替换
│   ├── bin/                        # 二进制、动态库、下载器、进程管理
│   ├── etc/server.json.template
│   ├── etc/models.lock.json        # 默认模型的 SHA256/大小/下载地址
│   ├── assets/                     # VAD、参考音频
│   ├── ui/images/icon_*.png        # 桌面入口指向 /health，不是 WebUI
│   ├── licenses/
│   └── build-info.json
├── etc/runtime.json                # 安装时记录共享目录、应用用户、端口；不是服务配置
├── var/audiocpp.pid                 # 管理进程 PID、启动时间和 boot ID
└── shares/audiocpp/                 # 文件管理中的共享目录
    ├── server.json                 # 可直接编辑，升级不覆盖
    ├── models/
    ├── voices/
    └── logs/                       # 安装下载、手动重试与服务日志统一位置
        ├── server.log
        ├── model-download.log
        ├── model-download.status
        ├── service-launch.log
        └── provision-launch.log
```

没有共享路径时回退到 `var/data`，实际路径保存在 `etc/runtime.json`，可用 `diagnose` 查看。

### 升级和保留策略

- 已有共享 `server.json` 按原字节保留，不强制覆盖用户配置。
- 旧 `etc/server.json` 存在而共享配置缺失时，迁移到共享目录；将服务按配置目录解析的相对路径转换为原来的绝对路径，旧文件保留。
- VAD/参考音频只补缺失文件；升级、卸载前按精确进程身份停止应用进程。
- 脚本不删除共享模型、配置或参考音频；最终保留范围仍以 fnOS 卸载选项为准，请备份重要配置及自行添加的音频。
- 旧日志留在原处供查询，新日志全部写共享 `logs/`。服务日志每个文件约 10 MiB、下载日志约 5 MiB，各保留 3 份轮转备份；启动错误日志每次启动重新写入。

服务由轻量 Python 管理进程直接启动原生二进制、转存并轮转日志。状态和停止通过 PID、启动时间、boot ID、命令行及 pidfd 核验，不再使用模糊 `pgrep/pkill`。共享日志含模型路径和推理信息，请只向可信用户授予共享目录访问权。

### SSH 管理

无需手工设置 `TRIM_*`。普通管理员使用 `sudo`；入口会降权到安装记录的应用用户，不以 root 运行推理服务：

```bash
sudo /var/apps/audiocpp/cmd/main status; echo "exit=$?"   # 0 运行中；3 未运行；1 管理错误
sudo /var/apps/audiocpp/cmd/main diagnose
sudo /var/apps/audiocpp/cmd/main restart
sudo /var/apps/audiocpp/cmd/main download-models
```

`diagnose` 显示运行用户、组、配置和日志目录、端口、render 节点的读写权限。GPU 不可用时检查 fnOS 驱动、BIOS 和应用用户的 `render/video` 组；**Vulkan 不会自动回退 CPU**。

## 3. 模型下载与配置

默认从 **ModelScope** 下载，失败按顺序尝试 HuggingFace、hf-mirror。hf-mirror 的 Xet 文件可能仍重定向到海外 HF CDN，不能保证国内加速。

| id / family | 默认文件 | 字节数 |
| --- | --- | ---: |
| `zh-tts` / `cosyvoice3` | `models/CosyVoice3-GGUF/cosyvoice3-q8_0.gguf` | 2257658336 |
| `zh-asr` / `sense_asr` | `models/SenseVoice-Small-GGUF/sensevoice-small-q8-audiocpp-v1.gguf` | 254211200 |

下载器使用 curl 传输、Python 标准库解析配置与校验：

- HF 地址锁定 commit；ModelScope 文件必须匹配同一锁定哈希。
- 校验大小、GGUF 文件头与完整 SHA256，通过后原子替换；已有文件也校验，不把零字节/HTML 当成功。
- `.part` 按来源 URL 与内容哈希隔离；同源可续传，不跨源拼接旧字节。旧版无来源标记的 `.part` 不复用、不自动删除。
- 同一配置及模型目标有互斥锁；并发调用返回 `75`，不覆盖正在运行任务的状态。
- 下载失败返回非零，状态为 `failed`；安装允许后台下载稍后失败，但目录、配置或预置资产初始化失败会阻止安装。
- 仅自动管理锁定的默认 family/文件名；不向自定义模型文件名写入默认模型。自定义模型应手动下载和验证，自动下载器会明确报告不支持。
- 相对 `models[].path` 与上游一致，按 **server.json 所在目录**解析，不是按 `models_root` 拼接。
- `done` 表示默认模型校验完成，不表示 GPU 或模型推理已经验证。

临时切换源后前台重试：

```bash
sudo env AUDIOCPP_MODEL_SOURCE=hf /var/apps/audiocpp/cmd/main download-models
sudo env AUDIOCPP_MODEL_SOURCE=hf-mirror /var/apps/audiocpp/cmd/main download-models
```

可通过 `AUDIOCPP_MS_BASE_URL`、`AUDIOCPP_HF_BASE_URL`、`AUDIOCPP_HF_MIRROR_BASE_URL` 指向可信 HTTP(S) 镜像；优先使用 HTTPS。这些环境变量只影响本次调用，不自动写入配置。没有未校验的 model_manager 下载回退。

离线安装可自行放入上表文件，再运行 `download-models` 校验。校验失败时原文件保留到新文件下载成功；确认旧 `.part` 不再需要后可在停止下载的情况下手动清理。

新安装默认 `keep_tags=false`，适合 HA 获取纯转写文本。升级保留原配置；已有用户若需要此行为，编辑 `zh-asr.default_request_options.keep_tags` 后重启。内存紧张时可按需要设置 `idle_unload_ms`，这里不强制改变已有常驻策略。

## 4. 服务验证

以下在 NAS SSH 执行，远程客户端将 `127.0.0.1` 换为 NAS IP。

```bash
sudo /var/apps/audiocpp/cmd/main diagnose
curl -fsS http://127.0.0.1:58009/health
curl -fsS http://127.0.0.1:58009/v1/models | python3 -m json.tool
```

模型列表应包含 `zh-tts` 和 `zh-asr`，但 lazy-load 模式下列表出现不代表模型已加载。共享日志 `model-download.status` 应为 `done`，继续执行真实推理：

```bash
curl -fS --max-time 300 http://127.0.0.1:58009/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"zh-tts","input":"你好，这是本地语音合成测试。","voice":"demo_3_woman","response_format":"wav"}' \
  -o /tmp/tts.wav
file /tmp/tts.wav

curl -fS --max-time 300 http://127.0.0.1:58009/v1/audio/transcriptions \
  -F model=zh-asr -F file=@/tmp/tts.wav -F language=zh | python3 -m json.tool
```

应得到合法 WAV，随后返回含相近中文内容的转写。Voice 可选 `demo_1_man`、`demo_2_man`、`demo_3_woman`、`demo_4_woman`。首次请求需要加载约 2.5 GB 权重，可能较慢。

若失败，先检查共享 `logs/server.log`、`service-launch.log` 和 `model-download.log`；服务未启动时也能从文件管理查看，不需要先通过 PID 反推目录。

HA 地址为 `http://<NAS_IP>:58009`，TTS 模型 `zh-tts`、STT 模型 `zh-asr`、Voice `demo_3_woman`。

### 网络访问限制

默认兼容局域网 HA，监听 `0.0.0.0:58009`。本打包层**没有配置 API 认证**，`--no-ui` 也不是认证：

- 在 NAS 防火墙仅允许 HA 与管理设备 IP 访问 TCP 58009。
- 不直接做公网端口映射；远程访问使用受认证的 VPN/反向代理。
- 可在共享 `server.json` 设置 `"host": "127.0.0.1"` 或指定 NAS 局域网地址；重启生效。旧配置没有 `host` 时仍按原行为监听 `0.0.0.0`。
- 包内不自动更改 NAS 防火墙，避免误断已有访问。

## 5. 开发与本地构建

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
shellcheck app/cmd/* scripts/*.sh payload/bin/*.sh
actionlint
```

CI 的 `Check packager` 在 main push/PR 运行，也作为正式构建前置检查。测试覆盖版本边界、发布恢复、模型错误内容/续传/锁、配置迁移、SSH 管理、PID 误判及 Moo 幂等/防降级。

本地构建同样必须在 Debian 12 容器中完成，容器只用于构建，不是 NAS 运行依赖：

```bash
git clone --depth 1 --branch v0.9.4 git@github.com:0xShug0/audio.cpp.git audio.cpp-src
docker run --rm -v "$PWD":/work \
  -e SRC_DIR=/work/audio.cpp-src -e REPO_DIR=/work -e OUT_TGZ=/work/dist/app.tgz \
  -e AUDIOCPP_VERSION=0.9.4-003 \
  debian:12 bash /work/scripts/build-audiocpp.sh
sudo chown -R "$(id -u):$(id -g)" dist
bash scripts/pack-fpk.sh app dist/app.tgz 0.9.4-003 x86 dist
python3 tools/check_payload.py --fpk dist/audiocpp_0.9.4-003_x86.fpk --version 0.9.4-003
```

版本仅为示例，实际发布前确认修订号尚未使用。下载工具支持镜像地址 `AUDIOCPP_CONDA_CHANNEL`、`AUDIOCPP_MINICONDA_URL`、`FNPACK_URL`；安装器/fnpack 校验值不会因更换镜像而放宽。

`pack-fpk.sh` 优先使用 `FNPACK` 指定的文件或 PATH 内 fnpack，否则下载官方固定版本；所有入口都会校验同一 SHA256。不要手工拼 tar 替代官方 fnpack。

## 6. Moo 应用源

仓库根 [moo.json](moo.json) 是 [Moo](https://github.com/Blue-Mink/moo) 应用源，用户在 Moo 中添加本仓库地址即可安装/更新。

维护脚本 [tools/update_moo_json.py](tools/update_moo_json.py) 固定随仓库提供，缺失直接失败，不从远程 main 下载执行。同步时核对附件 digest（旧附件缺 digest 时告警并计算本地哈希）、大小、FPK 结构和 manifest 版本；保留最近两版索引，拒绝降级和同版本更换 SHA。

旧 Release 不因索引保留数量而自动删除，可用于手动回退。当前索引只在真正发布成功后更新，不要手改 SHA 或拿预览包覆盖正式版。
