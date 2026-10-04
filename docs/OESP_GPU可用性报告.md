# OESP GPU 可用性报告

> 设备：OneThing Cloud OES Plus（Amlogic S922X / ARM64）
> 内核：`6.18.18.c997-trim` aarch64 ｜ 系统：fnOS
> 实测日期：2026-09-29 ~ 09-30 ｜ 所有结论均来自真机实测，非推断

---

## 〇、先纠正一个会误判的前提：本机"GPU"是两块独立硬件

问"这个 GPU 能干什么"必须先拆开看，它们驱动不同、能力不同、可观测性也不同：

| 硬件 | 型号 | 驱动 | 设备节点 | 中断线 |
|---|---|---|---|---|
| **3D 渲染 GPU** | ARM Mali-G52 | 开源 **panfrost**（mesa 25.0.7） | `/dev/dri/card0`、`renderD128` | `panfrost-job` |
| **视频硬解器** | Amlogic VDEC（G12A） | `meson-vdec`（内核 staging） | `/dev/video0` | `vdec` |

它们**互不相干**：串流画面走的是编码（CPU 软编），跟 VDEC 无关；硬解视频跟 Mali 无关。
把它们当一个"GPU"来问性能，永远得不到有意义的答案。

> ⚠️ 本机**没有** `/dev/mali`，不是闭源 Mali 驱动。3D 走的是 mesa 开源栈。

---

## 一、能干什么（全部实测）

### 1.1 视频硬件解码 ✅ 这是本机最强的能力

| 项目 | 实测值 |
|---|---|
| 720p H.264 | 500 帧 / **1.970 s = 254 fps**（10.2× 实时） |
| 1080p H.264 | 250 帧 / **1.949 s = 128 fps**（5.1× 实时） |
| 像素吞吐 | **约 250 Mpx/s**（720p 234 / 1080p 266，与分辨率无关） |
| CPU 占用 | **0.60 核**（软解需 1.94 核 → 省 **3.2 倍**） |
| 输出正确性 | **Y_MAE = 0.00、PSNR = 99.00 dB**，与 ffmpeg 软解**逐字节相同** |
| 端到端 | 解出帧 → libx264 封装 mp4，moov 完整可播 |

**规律：像素速率受限，与分辨率无关。** 估算任意分辨率吞吐直接按 250 Mpx/s 算：
```
预计 fps ≈ 250,000,000 / (宽 × 高)
例：4K(3840×2160) ≈ 30 fps
```

**固件层面还支持这些格式**（`/lib/firmware/meson/vdec/`）：
`g12a_h264 / g12a_hevc_mmu / g12a_vp9 / gxl_mpeg12 / gxl_mpeg4_5 / gxl_mjpeg / gxl_h263 / gxl_vp9 / sm1_hevc_mmu / sm1_vp9_mmu`

> ⚠️ 但**只有 H.264 实测通过**。HEVC / VP9 / MPEG2 / MJPEG **未验证**（固件和驱动都在，没跑通测试）。
> 结论：可以试，别当成已支持。

### 1.2 3D 图形渲染 ✅ 硬件后端，但当前几乎闲置

- 后端确认是**硬件**：`GLES: Mesa, Mali-G52 (Panfrost), OpenGL ES 3.1 Mesa 24.0.8`（容器内）
- 宿主 mesa 版本 **25.0.7**，`/dev/dri/renderD128` 可用
- GPU 频率：devfreq `ffe40000.gpu`，**125 MHz ~ 800 MHz**（当前空闲恒在最低 125 MHz）
- 安卓容器实测：连续滑动时 job 中断 **20.26/秒**，是空闲（0.26/秒）的 **78 倍** → 硬件确实能跑起来

### 1.3 容器直通 GPU ✅ 零性能损失

安卓容器里跑硬解：**1.972 s**，宿主 **1.974 s**，**零差异**；
容器内 / 宿主 / 软解三方输出**字节完全一致**。详见配套文档《容器调用 GPU 接口说明》。

### 1.4 转码 ✅ 能做，但应该用纯软件

| 方案 | 720p 500 帧耗时 |
|---|---|
| **纯软件（推荐）** | **7.9 s（63 fps）** |
| 硬解 + 软编（管道） | 12.4 s |
| 硬解 + 软编（落盘） | 13.6 s |

**反直觉结论：加硬解反而慢 55%。** 因为 500 帧 = 691 MB 要搬两次内核缓冲，
而 ffmpeg 内部软解是零拷贝。瓶颈 100% 在 libx264。

---

## 二、不能干什么（附证据）

| 能力 | 状态 | 证据 |
|---|---|---|
| **硬件视频编码** | ❌ **不存在** | V4L2 只有 `video0`/`video26` 两个**解码**节点；厂商目录全是 `amvdec_*`；唯一带 enc 的 `encoder_common.ko` 描述是 *"Video Encoder **Bug Report** Driver"*；无编码固件、无 DT 节点、无 `/dev/amvenc*` |
| **硬件 Vulkan** | ❌ 实际是软件 | `vulkaninfo` 报告 `deviceName = llvmpipe (LLVM 15.0.6)`、`driverName = llvmpipe`。虽有 `panfrost_icd.json`，但**未生效** |
| **GPU 使用率百分比** | ❌ 读不到 | panfrost sysfs **无 utilization 节点**；devfreq 目录只有 `cur_freq/min/max/governor/trans_stat`，**没有 `load`**。只能用中断增长率做代理 |
| **GPU 温度** | ❌ 没有温区 | 只有 `cpu-thermal`(38.8°C) 和 `ddr-thermal`(39.8°C)，**无 GPU thermal zone** |
| **切换 GPU 调频策略** | ❌ 锁死 | `available_governors = simple_ondemand`（只有这一个，改不了 `performance`） |
| **Android 应用层的 MediaCodec 硬解** | ❌ 框架层不通 | `media_codecs.xml` 只有软件 codec；`/vendor/lib64` 只有 `libstagefright_soft_*`；无 vendor OMX 插件、无 Codec2 HAL。`libstagefrighthw.so` 是加载器但**没插件可加载** |
| **CUDA / OpenCL / ROCm** | ❌ 不适用 | ARM Mali 架构，无此类生态 |
| **读 VDEC 硬件状态** | ❌ **致命** | `/sys/class/vdec/*` 任意节点只读即**整机死锁**（见雷区） |

---

## 三、⛔ 雷区：碰了整机死锁，必须物理断电

这四条都经过实测确认，**无看门狗自愈**：

| # | 雷区 | 触发方式 | 后果 |
|---|---|---|---|
| 1 | `/dev/video26`（闭源 aml-vcodec-dec） | `open()` 一次 | 整机挂死，SSH 无响应 |
| 2 | `/sys/class/vdec/*` 任意节点 | `cat` 一次 | 整机挂死 |
| 3 | `ffmpeg -c:v h264_v4l2m2m` | 配合软编转码 | 整机挂死 |
| 4 | 运行时 `rmmod` 闭源 GPU 驱动 | `rmmod mali` | 整机挂死 |

**判定是否挂死**：单独探一次 22 端口能否拿到 SSH banner（6–8 秒超时）。
不要只凭脚本超时下结论——脚本超时可能是网络慢，端口不通才是真死。

**安全白名单**（可放心用）：
`/dev/video0` 标准 V4L2 ioctl、`/sys/class/video4linux/video*/name` 只读、
`/sys/class/devfreq/*`、`/sys/class/thermal/*`、`/proc/interrupts`、`/proc/meminfo`、
`lsmod`/`dmesg`、ffmpeg 软编解。

---

## 四、该用在哪：决策表

| 场景 | 建议 | 理由 |
|---|---|---|
| 批量抽帧（AI 训练/分析） | ✅ **必用硬解** | 254 fps、只占 0.6 核，比软解省 3.2 倍 CPU |
| 多路视频并发解码 | ✅ **必用硬解** | 单路省 3.2 核 → 6 核机器能开多路 |
| 播放器后端 / iptv | ✅ 用硬解 | 纯解码场景，无搬运瓶颈 |
| **视频转码（解+编）** | ❌ **用纯软件** | 实测硬解方案慢 55%，瓶颈在编码 |
| 云手机 / 屏幕串流 | ❌ 帮不上 | 串流是**编码**，本机无硬编。降 CPU 要降参数（fps 60→30、size 1280→720） |
| 3D 游戏 / 图形应用 | ⚠️ 能用但弱 | Mali-G52 + 开源驱动，性能有限；且当前负载极低 |
| 硬件 Vulkan 计算 | ❌ | 实际是 llvmpipe 软件实现 |
| GPU 挖矿 / 通用计算 | ❌ | 无 OpenCL/CUDA |

---

## 五、如何观测（本机唯一可行的方法）

```bash
# 3D GPU 负载代理指标（注意是 panfrost-job，不是 panfrost-gpu）
awk '$NF=="panfrost-job"{print $2+$3+$4+$5+$6+$7}' /proc/interrupts

# VDEC 负载
awk '$NF=="vdec"{print $2+$3+$4+$5+$6+$7}' /proc/interrupts

# GPU 频率
cat /sys/class/devfreq/ffe40000.gpu/cur_freq      # 125MHz=空闲, 800MHz=满载
cat /sys/class/devfreq/ffe40000.gpu/trans_stat    # 各频率驻留统计

# 温度（无 GPU 温区，只有 CPU/DDR）
cat /sys/class/thermal/thermal_zone0/temp

# CMA 连续内存（硬解缓冲池）
grep -E "CmaTotal|CmaFree" /proc/meminfo
```

> 🔑 **陷阱：`panfrost-gpu` 中断恒为 0**，盯它会得出"GPU 根本没用"的错误结论。
> 真正的负载指标是 **`panfrost-job`**。

### 实测基线（用于对比）

| 场景 | panfrost-job 速率 |
|---|---|
| 空闲（云手机串流中） | 0.26 /秒 |
| 停掉串流 | **0 /秒** |
| 连续滑动 30 次 | **20.26 /秒（78 倍）** |
| 硬解 500 帧 | VDEC **+454**（容器与宿主一致） |

---

## 六、一句话总结

> **能做的事很窄但很强：H.264 硬解（254 fps @720p，省 3.2 倍 CPU，与软解逐字节相同）。
> 做不到的事很硬：无硬件编码、无硬件 Vulkan、无 GPU 温度/利用率读数、Android App 层拿不到硬解。
> 转码不要用硬解。四条雷区碰了要断电。**
