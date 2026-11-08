# fnos-audiocpp-native

用 **GitHub Actions** 在 **Debian 12**（与 fnOS 同 glibc）里编译 audio.cpp 的 **Vulkan**
版本，并打包成可在飞牛 fnOS **应用中心直接安装的 `.fpk`**。

这是**原生（不用容器）**部署：fpk 里装的是编译好的 `audiocpp_server` 二进制，
由 `cmd/main` 以应用专用用户直接拉起，**不经过 Docker / podman**。因此不存在
"fpk 容器模板无法注入 `/dev/dri`" 的老问题——GPU 权限通过 `config/privilege` 的
`extra-groups: ["video","render"]` 授予，原生进程直接访问宿主核显/独显。

> 纯 API 模式（`--no-ui`），不启动 WebUI；为 Home Assistant / Assist 提供本地中文
> TTS(CosyVoice3) 与 STT(SenseVoice)，端口 **58009**。

---

## 1. 为什么必须在 Debian 12 里编

| | glibc | 能否在 fnOS(Debian 12) 运行 |
| --- | --- | --- |
| 官方 release 的 Linux Vulkan 二进制 | Ubuntu 24.04 = **2.39** | ❌ `GLIBC_2.38/GLIBCXX_3.4.32 not found` |
| 本方案（debian:12 容器内编译） | bookworm = **2.36** | ✅ |

glibc 只向后兼容。官方二进制在更新的 glibc 上链接，拿到 fnOS 直接跑会报符号缺失，
且无法靠 `LD_LIBRARY_PATH` 补（glibc 是加载器本身）。所以 CI 用 `container: debian:12`
编译，产物与 fnOS 同代 glibc。

## 1.1 为什么锁定"正式版 + portable 配方"

- **正式版**：CI 默认编译上游 `0xShug0/audio.cpp` 的**正式发布 tag**（当前 `v0.9.4`），
  而非 `main` 分支——保证可复现、可追溯。升级时改 `build-fpk.yml` 的 `default`，或手动触发时填新 tag；
  打 `v*` tag 时，tag 名即被视为要编译的上游 release tag（如本仓库打 `v0.9.4` → 编上游 `v0.9.4`）。
- **portable 配方**：上游 `ENGINE_ENABLE_NATIVE_CPU` 默认 **ON**，会按"编译机 CPU"下
  `-march=native`。本包在 GitHub runner 上编、却要跑在各不相同的 NAS CPU 上，native 编译
  可能触发 **SIGILL（非法指令）**。因此对齐官方 `linux-vulkan-portable` job：
  `-DENGINE_ENABLE_NATIVE_CPU=OFF -DENGINE_ENABLE_CPU_ALL_VARIANTS=ON`——CPU 后端编成按
  ISA 运行时自选的动态库（`ggml-cpu-*.so`，随 `.so` 一并打进 `bin/`），可在任意 x86-64 NAS 运行。

## 2. 目录结构

```
fnos-audiocpp-native/
├── .github/workflows/build-fpk.yml   # CI：debian:12 编译上游正式版 → 打包 fpk → artifact/Release
├── .github/workflows/moo-json.yml    # 发 Release 后自动把版本节点写进 moo.json
├── moo.json                          # Moo 应用商店（Blue-Mink/moo）应用源索引
├── tools/update_moo_json.py          # moo.json 维护脚本（vendor 自上游，离线自包含）
├── app/                              # fpk 骨架（元数据，不含二进制）
│   ├── manifest                      # appname/version/service_port=58009/checksum(打包时填)
│   ├── config/privilege              # run-as=package + extra-groups video,render（GPU）
│   ├── config/resource               # data-share(audiocpp) + port-config
│   ├── cmd/main                      # 自包含 start/stop/status，PID 管理 audiocpp_server
│   ├── cmd/install_init              # 预检 /dev/dri
│   ├── cmd/install_callback          # 渲染 server.json、建目录、seed VAD/demo 音频
│   ├── cmd/upgrade_callback          # 升级后重渲染配置（复用 install_callback）
│   ├── cmd/uninstall_callback        # 卸载保留模型，只记日志
│   ├── ui/config                     # 桌面入口（指向 /health）
│   ├── wizard/install                # 安装提示（模型放哪、GPU 说明）
│   ├── audiocpp.sc                   # 58009 端口转发声明
│   ├── ICON.PNG / ICON_256.PNG       # 应用图标
├── payload/etc/server.json.template  # 进 app.tgz；install 时把 __DATA_ROOT__ 换成共享路径
├── payload/bin/provision-models.sh   # 进 app.tgz；按 server.json 自动下载缺失模型
└── scripts/
    ├── build-audiocpp.sh             # 在 debian:12 内编译（portable 配方）并组装 app.tgz
    └── pack-fpk.sh                   # 骨架 + app.tgz → .fpk（自包含，不依赖 fnpack）
```

两层结构：**fpk 根**（manifest/cmd/config/ui/wizard/图标/sc）是元数据；
**app.tgz** 是载荷，安装时解压到 `TRIM_APPDEST`(target/)，含
`bin/audiocpp_server`、`bin/*.so`（rpath=`$ORIGIN` 需同目录）、`etc/` 模板、`assets/`。

## 3. CI 产出 fpk

把本目录推到一个 GitHub 仓库后：

- **手动**：Actions → `build-fnos-fpk` → Run workflow，填 `audiocpp_ref`（默认 `v0.9.4`，
  上游正式 tag）与 `version`（留空则由 ref 推导）。产物在 Artifacts 里（`audiocpp-fnos-fpk`）。
- **打 tag**：`git tag v0.9.4 && git push --tags` → 自动构建上游 `v0.9.4` 并创建 Release 附上 `.fpk`。

CI 流程：checkout 本仓库 → checkout 上游 `0xShug0/audio.cpp`（锁定 release tag，不拉子模块，
纯 API 用不到 WebUI 前端）→ `docker run debian:12` 跑 `build-audiocpp.sh`（gcc-13 + Vulkan +
portable + `DEPLOYMENT_BUILD=ON`）产出 `app.tgz` → `pack-fpk.sh` 产出 `.fpk`。

> 首次编译约 20–60 分钟（audio.cpp 体量大，Vulkan + CPU 多 ISA 变体）。属正常。

## 4. 在 fnOS 上安装

1. 应用中心 → 手动安装 → 从电脑上传 → 选 `.fpk` → 确认来源 → 安装。
2. 安装时 `install_callback` 会：解析数据共享目录（文件管理 → 应用文件里的 **audiocpp**）、
   预置 silero VAD 权重与 demo 参考音频、按 `DATA_ROOT` 渲染出 `server.json`。
3. **模型自动下载**：安装完成后，`install_callback` 会以应用用户身份在后台（`setsid`）运行
   `bin/provision-models.sh`，**读取渲染好的 `server.json`**，对其中声明但文件缺失的模型调用随包的
   `audiocpp_model_manager` 从 HuggingFace 下载对应 GGUF 包：
   | server.json family | 包 id | 落点（= 配置的 `path`） | 大小 |
   | --- | --- | --- | --- |
   | `cosyvoice3` | `cosyvoice3_q8_0` | `models/CosyVoice3-GGUF/cosyvoice3-q8_0.gguf` | ~2.26 GB |
   | `sense_asr` | `sensevoice_small_q8` | `models/SenseVoice-Small-GGUF/sensevoice-small-q8-audiocpp-v1.gguf` | ~254 MB |

   下载落点与 `server.json` 里配置的 `path` 完全一致，下完即可被 lazy-load 直接使用。
   - 进度/状态：`audiocpp/logs/model-download.log`、`audiocpp/logs/model-download.status`（`running`/`done`/`failed`）。
   - **下载完成前 TTS/STT 请求会失败**（模型还没就位），属正常，等 `status=done` 即可。
   - 中断/失败可 SSH 前台续跑（幂等，只补缺失文件）：`/var/apps/audiocpp/cmd/main download-models`。
   - 想离线预置：手动把上表两个 GGUF 放到对应路径即可，脚本检测到已存在会跳过下载。
4. 在应用中心启动 audio.cpp；验证：
   ```
   curl -s http://<fnOS IP>:58009/health
   curl -s http://<fnOS IP>:58009/v1/models
   ```
5. HA 接入同主 README 第 4 节，URL 填 `http://<fnOS IP>:58009`。

**GPU**：应用用户已在 `render`/`video` 组，直接用宿主 `/dev/dri`。若 `/dev/dri` 不存在
（核显驱动未加载 / BIOS 关闭），安装会告警、服务启动后 GPU 不可用。

**卸载**：系统删除程序与配置，但**保留**共享目录里的模型与参考音频（避免误删 GB 级文件）。

### 4.1 安装后的 fnOS 目录结构

分两套：**程序目录**（升级替换）与**数据目录**（各 `@app*` 卷，卸载保留）。`vol1` 为安装时所选存储卷，可能是 `vol2` 等。

```
/var/apps/audiocpp/                # 应用主目录（元数据 + 生命周期脚本）
├── manifest                       # 身份证：appname/version/service_port=58009/checksum
├── ICON.PNG  ICON_256.PNG         # 图标
├── audiocpp.sc                    # 58009 端口转发声明
├── cmd/                           # 应用中心调用的脚本
│   ├── main                       #   start / stop / status / download-models
│   ├── install_init               #   预检 /dev/dri
│   ├── install_callback           #   渲染 server.json + 预置资产 + 后台下载模型
│   ├── upgrade_callback           #   升级后重渲染配置
│   └── uninstall_callback         #   卸载保留数据，只记日志
├── config/privilege               # run-as=package + extra-groups video,render（GPU）
├── config/resource                # data-share(audiocpp) + port-config
├── ui/config                      # 桌面入口（→ :58009/health）
├── wizard/install                 # 安装向导
│  ── 以下为系统建立的软链接 ──
├── target -> /vol1/@appcenter/audiocpp    # app.tgz 解压处（TRIM_APPDEST）
├── etc    -> /vol1/@appconf/audiocpp      # 渲染后的 server.json（TRIM_PKGETC，持久）
├── var    -> /vol1/@appdata/audiocpp      # 运行日志 / PID（TRIM_PKGVAR）
├── tmp    -> /vol1/@apptemp/audiocpp
├── home   -> /vol1/@apphome/audiocpp
└── shares/audiocpp -> /vol1/@appshare/audiocpp   # 模型/音频/下载日志（DATA_ROOT）
```

**程序载荷 `target/`**（= `@appcenter/audiocpp`，随 app.tgz 解压）：

```
target/
├── bin/
│   ├── audiocpp_server            # 主服务
│   ├── audiocpp_cli
│   ├── audiocpp_model_manager     # 模型下载器（内置 BoringSSL）
│   ├── provision-models.sh        # 按 server.json 下载缺失模型
│   └── *.so*                      # 依赖库 + ggml-cpu-*.so（rpath=$ORIGIN，须同目录）
├── etc/server.json.template       # 配置模板（含 __DATA_ROOT__ 占位）
└── assets/
    ├── silero_vad/silero_vad_16k.safetensors
    └── demo_voices/*.wav, prompt_text
```

**配置 `etc/`**（= `@appconf/audiocpp`，持久）：`server.json`（由模板渲染）。

**运行数据 `var/`**（= `@appdata/audiocpp`）：

```
var/
├── audiocpp.pid                   # main 写的 PID
├── info.log                       # 启停日志
└── logs/server.log                # 服务运行日志（--log-file）
```

**共享数据 `shares/audiocpp/`**（= `@appshare/audiocpp`，即 DATA_ROOT，**卸载保留**；文件管理 →「应用文件」可见）：

```
audiocpp/
├── models/
│   ├── CosyVoice3-GGUF/cosyvoice3-q8_0.gguf                        # 自动下载 ~2.26 GB
│   ├── SenseVoice-Small-GGUF/sensevoice-small-q8-audiocpp-v1.gguf  # 自动下载 ~254 MB
│   └── silero_vad/silero_vad_16k.safetensors                       # 安装包预置
├── voices/                                                        # demo 参考音频，安装包预置
│   └── demo_1_man.wav … prompt_text
└── logs/
    ├── model-download.log         # 下载进度
    └── model-download.status      # running / done / failed
```

要点：
- 模型下载落点由 `etc/server.json` 的 `models_root` + 各 `models[].path` 决定，均在 `shares/audiocpp/models/` 下，下载后正好落在配置指定路径。
- **两个 logs 别混**：`var/logs/server.log` 是服务运行日志；`shares/audiocpp/logs/model-download.log` 是模型下载日志。
- **卸载**删 `target/`、`etc/`、`var/`，**保留** `shares/audiocpp/`；**升级**换 `target/` 程序、重渲染 `etc/server.json`，`shares/` 数据不动。

## 5. 本地手动构建（不用 CI）

需要 Docker（用于提供 debian:12 构建环境）：

```bash
# 1) 取上游正式版源码（锁定 release tag）
git clone --depth 1 --branch v0.9.4 https://github.com/0xShug0/audio.cpp audio.cpp-src

# 2) 在 debian:12 里编译（portable 配方）→ dist/app.tgz
docker run --rm -v "$PWD":/work \
  -e SRC_DIR=/work/audio.cpp-src -e REPO_DIR=/work -e OUT_TGZ=/work/dist/app.tgz \
  -e AUDIOCPP_VERSION=0.9.4 \
  debian:12 bash /work/scripts/build-audiocpp.sh

# 3) 打包 → audiocpp_0.9.4_x86.fpk
bash scripts/pack-fpk.sh app dist/app.tgz 0.9.4 x86 dist
```

## 6. 与另外两种部署方式的关系

| | 本 fpk（原生） | 主 README 第 7 节（Docker Compose） | 主 README 第 8 节 / `native/`（systemd 原生） |
| --- | --- | --- | --- |
| 安装入口 | 应用中心 GUI | Docker 管理 → 项目 | systemd 服务 |
| 运行时 | 宿主原生进程 | 容器 | 宿主原生进程 |
| GPU | extra-groups 授权 /dev/dri | devices + group_add | 用户在 render/video 组 |
| 升级 | 应用中心一键 | 换镜像 tag | 重跑构建脚本 |
| 编译 | CI 编好 | 不用编（用镜像） | 在 fnOS 上编 |

三者数据可互通（都是 `models/`+`voices/`+`server.json` 约定）。想"装个应用就用"选 fpk；
想跟着上游镜像走选 Compose；想在 NAS 上完全自管选 systemd。

## 7. 已知限制

- fpk 只支持单端口（`service_port`），本应用固定 58009。
- `platform = x86`（AMD/Intel 核显 Vulkan）。ARM fnOS 需另编 `arm` 平台包。
- 首次 TTS/STT 请求触发 lazy 加载，等待数十秒属正常。
- **模型自动下载需要 NAS 能访问 HuggingFace**（`huggingface.co`，约 2.5 GB）。网络受限/被墙时
  后台下载会失败（`model-download.status=failed`），此时改为手动把两个 GGUF 放到对应路径，
  或配置好代理后 `cmd/main download-models` 续跑。下载器不依赖系统 curl/OpenSSL（内置 BoringSSL）。
- 构建在 GitHub 公共 runner 上，源码与产物会经过 CI 环境；介意可自建 runner。

## 8. 作为 Moo 应用商店的应用源

仓库根的 [`moo.json`](moo.json) 让本仓库成为一个可被
[Moo 应用商店](https://github.com/Blue-Mink/moo)（第三方飞牛应用中心）收录的**应用源**。
用户在 Moo 里"添加源"填入本仓库地址即可浏览 / 安装 / 更新本应用。

- **骨架已写好**：`schema_version=moo`、`source_info`、`apps.audiocpp`（展示名 / 简介 /
  分类 `AI` / 图标 / 端口 / `install_type=package`）。键名 `audiocpp` 与 manifest 的 `appname` 一致。
- **版本节点自动生成**：`releases` 初始为空；发布 Release 后由
  [`.github/workflows/moo-json.yml`](.github/workflows/moo-json.yml) 自动下载 `.fpk`、
  校验 sha256、把 `download_url / sha256 / size` 写进 `releases.<版本>` 并提交回 `main`。
  维护脚本已 vendor 到 [`tools/update_moo_json.py`](tools/update_moo_json.py)，离线自包含。
- **仓库地址已填**：`moo.json` 里 `source_info.homepage` / `bug_report_url` / `icon_url` /
  `readme_url` 均指向 `kylin7226/fnos-audiocpp-native`。下载直链由 CI 按 `git remote origin`
  自动推导，无需手填。若日后迁移仓库，改这 4 处即可。

本地预览一次写入（不改文件，只看 diff）：

```bash
python3 tools/update_moo_json.py --file moo.json --repo kylin7226/fnos-audiocpp-native \
  --tag v0.9.4 --fpk dist/audiocpp_0.9.4_x86.fpk --keep 2 --dry-run
```

> 发布流程：`git tag v0.9.4 && git push --tags` → `build-fpk` 构建并创建 Release 附 `.fpk`
> → Release published 触发 `Update moo.json` 自动把该版本写进索引。
