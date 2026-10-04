# OESP GPU 功能总览 · 安卓容器接入 GPU 改进清单

**日期**：2026-10-03　**设备**：OneThing Cloud OES Plus（Amlogic S922X / G12B）
**内核**：6.18.18.c997-trim　**容器**：androidemu-android（redroid 12 / Android 12）

---

# 第一部分：目前能实现的所有功能

## 1. 宿主原生硬解（V4L2 / meson-vdec）—— 生产可用

`meson-vdec` 驱动 + `/dev/video0`，已封装成命令行工具。**这是全项目最成熟的成果。**

```bash
ffmpeg -i in.mp4 -c:v copy -f h264 in.h264          # 必须 Annex-B 裸流
PRELUDE_AU=2 TAIL_AU=1 COMPACT=1 vdec-dec /dev/video0 in.h264 0 out.nv12
ffmpeg -f rawvideo -pix_fmt nv12 -s 1280x720 -r 25 -i out.nv12 -c:v libx264 -crf 23 out.mp4
hwdec-verify            # 17 项完整验收 / hwdec-verify --quick 13 项
```

| 分辨率 | 帧数 | 耗时 | 吞吐 | CPU | 像素速率 |
|---|---|---|---|---|---|
| 720p | 500 | 1.970 s | **254 fps** | 83% | 234 Mpx/s |
| 1080p | 250 | 1.949 s | **128 fps** | 80% | 266 Mpx/s |

- **正确性：Y_MAE = 0.00 / PSNR = 99.00 dB，与软解逐字节相同**
- CPU：硬解 0.60 核 vs 软解 1.94 核 → **省 3.2 倍**
- 瓶颈是像素速率（~250 Mpx/s），与分辨率无关

### 硬解支持的编码格式（本次实测枚举 VIDIOC_ENUM_FMT）

| FourCC | 格式 | 可用性 |
|---|---|---|
| `H264` | H.264 | ✅ 已打通（宿主 + 容器） |
| `VP90` | VP9 | ⚠️ 硬件支持，OMX 组件未接 |
| `MPG1` / `MPG2` | MPEG-1/2 ES | ⚠️ 硬件支持，未接 |
| ~~HEVC~~ | H.265 | ❌ **驱动不支持**，别指望 |
| ~~AV1~~ | AV1 | ❌ **无硬件** |

> 这条结论很重要：想看 H.265 只能软解；但 **VP9 值得接**，网页视频用得多。

### 关键参数（都踩过坑，别改）

| 参数 | 值 | 为什么 |
|---|---|---|
| `PRELUDE_AU` | 2 | 复制前 2 个 AU 拼到码流前，消除首 GOP 的 Y 偏移。只预热 1 个 IDR 无效 |
| `TAIL_AU` | 1 | 末尾追加首帧 IDR 顶出尾帧（尾部丢帧是固定常数 1-3 帧） |
| `COMPACT` | 1 | 输出紧凑 NV12（真实高度 720 而非对齐 768），ffmpeg 才能直接读 |
| `CAP_BUFS` | 24 | 平台 `max_buffers=24`；20/32 都会丢帧 |
| drain | 必开 | `V4L2_DEC_CMD_STOP`；1080p 不 drain = 0 帧 |
| OUTPUT 缓冲 | 2 MB × 8 | 4MB×16=64MB 超限，驱动只批 2 个 buffer |

---

## 2. 安卓容器硬解（OMX 组件）—— App 已能用

自研 `libstagefrighthw.so` 注入容器 `/vendor/lib/`，注册 `OMX.meson.h264.decoder`。
**容器里的 App 用标准 `MediaCodec` API 就能自动选中硬解，无需改 App 代码。**

| 验收项 | 结果 |
|---|---|
| 组件选择 | ★ 按 MIME **自动**选中 `OMX.meson.h264.decoder`（非强制指定） |
| 720p 正确性 | 100/100 帧，Y+UV **逐字节一致**（MAE = 0.0000） |
| 1080p 正确性 | 200/200 帧，**整文件 md5 与软解相同** |
| 帧内容真实性 | 真实帧 100/100（非全黑空壳） |
| 生命周期 | Loaded→Idle→Executing→Idle→Loaded→DeInit，RC=0 无悬挂 |
| 硬件侧证据 | 解码期间 `vdec` 中断 **+99 / 100 帧** |
| CPU 收益 | 720p 省 **41%**、1080p 省 **46%** |

容器内验证：`docker exec androidemu-android /data/local/tmp/mctest <video> <帧数>`

**⚠ 一个必须说清的性能事实**：ByteBuffer 模式下墙钟**硬解比软解慢 1.4–1.8 倍**
（1080p: 2832 ms vs 2052 ms），尽管 CPU 少用 46%。原因是 ACodec 每帧要再 memcpy 一次给 App
（1080p 每帧 3.1 MB × 200 帧 = 600 MB 额外拷贝），而软解零拷贝。
**真实播放器走 Surface 模式，这次拷贝消失** —— 那才是硬解占优的场景（见改进清单 P1-1）。

### 自愈机制
`omx_autodeploy.sh` 装在 root crontab，每分钟检查：插件 md5 → xml 条目 → 设备权限 →
预热属性 → mediaserver 缓存刷新。实测把插件还原成空壳后 1 秒内自动恢复。

---

## 3. 3D GPU（Mali-G52 / panfrost）

| 项 | 状态 |
|---|---|
| 宿主驱动 | panfrost 已加载（mesa 24.0.8），`/dev/dri/renderD128` 存在 |
| 频率 | devfreq `ffe40000.gpu`，可调 |
| 宿主 3D 可用性 | ✅ OpenGL ES 3.1 / Mesa Mali-G52 |
| 容器内 3D | ❌ **当前是 SwiftShader 软件渲染**（详见第二部分 P0-1） |

⚠ 本机"GPU"是两块独立硬件，必须分开看：

| 硬件 | 驱动 | 中断线 |
|---|---|---|
| Mali-G52（3D） | 开源 panfrost | `panfrost-job` |
| VDEC（硬解） | meson-vdec | `vdec` |

**负载指标是 `panfrost-job`，不是 `panfrost-gpu`**（后者恒为 0）。
读不到"使用率百分比"（panfrost 无 utilization 节点），只能用中断增长率做代理。

---

## 4. 云手机（scrcpy-over-webrtc）

- 控制台 `https://<ip>:8443/`（自带 TLS），账号 admin，公开注册已关闭
- coturn 3478（UDP+TCP），安卓容器 5555（adbd），宿主 5556 ADB 转发
- **连接方向是反的**：容器内 agent 主动注册到 `wss://<DOCKER_BRIDGE_IP>:8443/register_agent`，agent 一死设备就消失
- 一键拉起：`cloudphone_bringup.sh`（agent 必须显式 `-id androidemu`，否则产生僵尸离线设备）
- agent 守护：`agent_autodeploy.sh` 有"agent 在跑就直接退出"的坑 → 必须用 `--force` 才能装回守护

⚠ **串流编码是软件**（scrcpy 抓屏 → MediaCodec 编码，本机无硬编）。降 CPU 要降 agent 参数
（fps 60→30、size 1280→720），硬解帮不上。

---

## 5. 监控与一键修补（本次新增）

**GPU 控制台 1.0.4**（fnOS 原生应用，不占端口，走 Unix Socket）：

- 实时面板：3D 负载 / 硬解负载 / GPU 频率 / CMA / 温度 / 驱动模块 / 容器占用 / 趋势图
- **新增硬件体检**：20 项指标打分，逐项列出问题 + 修法
- **新增一键修补**：三级按钮（容器层 / 宿主层 / 切 GPU 直通）

详见第三部分。

---

## 6. 工具链清单

| 工具 | 位置 | 用途 |
|---|---|---|
| `vdec-dec` | `/usr/local/bin` | 生产解码器（宿主） |
| `hwdec-verify` | `/usr/local/bin` | 17 项验收器 |
| `mctest` | 容器 `/data/local/tmp` | App 视角 MediaCodec 验证器 |
| `vdec32` | 容器 `/data/local/tmp` | 32 位独立解码器（隔离排障用） |
| `omx_autodeploy.sh` | `/root/vdec/omx` | OMX 插件持久化自愈（cron 每分钟） |
| `oesp_gpu_fix.sh` | 控制台 scripts/ | 检测 + 分层修补（本次重写 v2） |
| `gpu_status.sh` | 控制台 scripts/ | 命令行状态速查（SSH 直接可用） |
| `switch_ssh.py` / `run_many.py` | 工作区 | SSH 公网/局域网切换、批量上传执行 |

---

## 7. 明确做不到的事

| 项 | 结论 |
|---|---|
| **H.265 / AV1 硬解** | 驱动无此格式，只能软解 |
| **硬件编码** | AVE-10 有硬件有驱动（`encoder.ko` 可 insmod），但 DT 无节点 → probe 从不触发；需改 DTB + 重启。且用户态零生态（私有 `AMVENC_AVC_IOC_*`，非 V4L2），ROI 低 |
| **视频转码加速** | 全软 720p 500 帧 7.9 s vs 硬解+软编 12.4 s。瓶颈 691 MB 帧搬运 + libx264，硬解只适合**纯解码场景** |
| **GPU 使用率百分比** | panfrost 无 utilization 节点，只能用中断速率代理 |

---

# 第二部分：安卓容器接入 GPU 需要哪些改进

## 切换前的体检（控制台 `/api/detect` 输出）

```
score = 80    正常 16 · 警告 2 · 故障 3

[FAIL] 容器 GPU 渲染模式   当前 guest（软件渲染）
[FAIL] 容器实际渲染器      GLES: ANGLE (Google, Vulkan 1.2.0 (SwiftShader Device (LLVM 10.0.0)))
[FAIL] compose GPU 直通项  缺少: /dev/dri  dma_heap  DRI驱动目录
[WARN] CMA 连续内存        仅 13 MB 空闲
[WARN] 特权容器暴露雷区    privileged 容器内可见 /dev/video26
```

**头号问题：容器 3D 渲染是纯软件（SwiftShader）。**
`dumpsys SurfaceFlinger` 实测渲染器为 SwiftShader，`ro.boot.redroid_gpu_mode=guest`。
而此前已验证过 host 模式可用（`GLES: Mesa, Mali-G52 (Panfrost)`）—— 是 **androidemu 应用升级
用包内模板覆盖了 compose**（`/vol1/@appcenter/androidemu/docker/docker-compose.yaml` 第 67 行
变回 `redroid_gpu_mode=guest`，devices 段只剩 `/dev/binder`）。

## 改进清单（按优先级）

### P0 — 立刻做，收益最大

| # | 改进 | 状态 | 做法 | 风险 |
|---|---|---|---|---|
| **P0-1** | **恢复 3D GPU 直通** | ✅ **已执行** | compose 加 `/dev/dri` + `/dev/dma_heap` + DRI 驱动目录挂载，`gpu_mode=host`，重建容器 | 重建时云手机中断 1–2 分钟 |
| **P0-2** | **把直通做成幂等自愈** | ⬜ 待做 | 仿 `omx_autodeploy.sh`：cron 每分钟校验 compose 直通项，缺失就调 `tune_compose.sh` 修回 | 无（只在缺失时改文件） |

#### P0-1 执行结果（实测）

| 项 | 切换前 | 切换后 |
|---|---|---|
| `ro.boot.redroid_gpu_mode` | `guest` | **`host`** |
| `ro.hardware.egl` | `angle` | **`mesa`** |
| `ro.hardware.gralloc` | `redroid` | **`gbm`** |
| SurfaceFlinger GLES | `ANGLE (SwiftShader Device (LLVM 10.0.0))` | **`Mesa, Mali-G52 (Panfrost), OpenGL ES 3.1 Mesa 24.0.8`** |
| 体检评分 | 80（故障 3） | **92（故障 0）** |
| App 硬解组件 | `OMX.meson.h264.decoder` | 不变（重建后由自愈 cron 拉回） |
| 云手机 agent | 在线 | 已重拉，在线 |

⚠ 重建容器时踩到一个连带问题：容器重建后 `/vendor` 恢复出厂，OMX 插件变回空壳；
自愈 cron 虽然把插件注回去了，但 **mediaserver 缓存的 codec 列表仍是重建那一刻的空壳版本**，
App 因此静默回退软解。根因是自愈脚本用「mediaserver 启动时间 < 插件源文件 mtime」判断要不要重启
mediaserver —— 源 .so 的 mtime 是编译时间（几小时前），条件永远不成立。
已改为**用注入时间戳标记文件**判据，重启后 App 立刻重新选中 `OMX.meson.h264.decoder`。

### P1 — 做了能显著拓宽可用性

| # | 改进 | 说明 |
|---|---|---|
| **P1-1** | **OMX 支持 Surface（零拷贝）输出** | 当前只有 ByteBuffer 模式，每帧多拷 3.1 MB（1080p），导致墙钟反而输给软解。实现 `OMX_IndexParamVideoAndroidNativeBuffer`（gralloc/dma-buf）后，播放器/云手机抓屏场景硬解才真正占优。**这是让硬解"有用"而非"能跑"的关键** |
| **P1-2** | **加 VP9 硬解** | 驱动已支持 `VP90`（实测枚举到），OMX 组件只需新增 MIME `video/x-vnd.on2.vp9` 分支 + 对应 AU 切分。H.265/AV1 硬件没有，别做 |
| **P1-3** | **动态分辨率切换** | 当前首次 `SOURCE_CHANGE` 后固定几何。真实播放中码流中途变分辨率（横竖屏、码率自适应）会出错，需处理二次 `V4L2_EVENT_SOURCE_CHANGE` 并重新协商 CAPTURE |

### P2 — 长期

| # | 改进 | 说明 |
|---|---|---|
| **P2-1** | 权限最小化 | 现在 privileged 把雷区 `/dev/video26` 也暴露进容器（open 即整机死锁）。改为 `--device=/dev/video0 --device=/dev/dri --device=/dev/dma_heap --group-add 44,105`。⚠ redroid 非特权曾实测静默退出，需验证 |
| **P2-2** | CMA 扩容 | 当前仅 7–13 MB 空闲（总 1204 MB，闭源驱动预占）。单路可解，**多路并发必失败**。需调内核 `cma=` 参数并重启 |
| **P2-3** | 多路并发硬解 | 依赖 P2-2。当前 CMA 只够 1 路 |
| **P2-4** | 硬件编码（AVE-10） | 需改 DTB 加 `amvenc_avc` 节点 + 重启 + 移植 libamcodec。**ROI 低于 P1-1**，且串流编码走的是 MediaCodec 编码路径，与硬解无关 |

## 一句话排序

> **先把 3D 直通修回来（P0-1）并锁住（P0-2）→ 再做 Surface 零拷贝（P1-1）→ 顺手加 VP9（P1-2）。**
> 编码（P2-4）投入产出比最低，建议最后再评估。

---

# 第三部分：GPU 控制台 1.0.4（本次交付）

## 新增：硬件体检与一键修补

页面新增两块卡片：**「硬件体检与一键修补」**与**「安卓容器 GPU 详情」**。

### 检测项（20 项，按实际硬件状态动态判定）

| 类别 | 项 |
|---|---|
| 宿主 host | 3D 渲染节点 / panfrost / mali 屏蔽 / GPU 调度超时 / meson-vdec 模块 / 开机自启 / `/dev/video0` 权限 / CMA / vdec-dec / udev |
| 容器 container | 容器存活 / GPU 渲染模式 / **实际渲染器** / compose 直通项 / OMX 插件 md5 / media_codecs / video0 权限 / tmp 权限 / 预热参数 |
| 自愈 selfheal | cron 定时任务 |
| 风险 risk | 特权容器暴露雷区 |

### 三个修补按钮（显式分级，默认安全）

| 按钮 | 需要 | 做什么 |
|---|---|---|
| ① 修补容器层 | docker 组（控制台自带） | 容器内 `/dev/video0` 666、tmp 777、预热属性、OMX 插件注入、xml 补写、重启 media.codec + mediaserver |
| ② 修补宿主层 | root | 屏蔽 mali、modprobe meson-vdec + 开机自启、宿主 chmod、udev、编译 vdec-dec、装自愈 cron |
| ③ 切 GPU 硬件直通 | root + 二次确认 | 调官方 `tune_compose.sh` 补齐直通参数并重建容器（**云手机中断 1–2 分钟**） |

①② 都不中断任何服务；③ 必须弹窗二次确认，且不带 `--rebuild` 时只改配置不重建。

### root 授权（一次性）

控制台以应用用户运行，没有 root。装好后**在 SSH 里执行一次**：

```bash
sudo bash /var/apps/gpuconsole/target/scripts/grant_root.sh
```

它会：① 把修补脚本**复制到 root 拥有的 `/usr/local/lib/oesp-gpu/`** ② 用 `visudo -cf` 校验后
写 sudoers，**只放行这一个脚本**。不开放 shell。升级应用后重跑一次即可同步新版。

> 为什么不在安装钩子里自动写：实测 fnOS 的 `install_callback` 是**以应用用户而非 root 执行的**
> （日志明确记录"非 root，跳过"），写不了 `/etc/sudoers.d`。

### 安全设计

- 脚本绝不 open `/dev/video26`、绝不读 `/sys/class/vdec/*`（整机内核级死锁，无看门狗，必须物理断电）
- sudoers 只放行固化到 root 目录的那一份脚本，应用目录里的副本即使被改也提不了权
- 破坏性操作（改 compose）前先备份到 `/var/backups/oesp-gpu/`

## 部署

```bash
appcenter-cli uninstall gpuconsole
appcenter-cli install-fpk gpuconsole_1.0.4.fpk -v 1
sudo bash /var/apps/gpuconsole/target/scripts/grant_root.sh
```

（同 appname 的 `install-fpk` 不会升级，必须先 uninstall）
