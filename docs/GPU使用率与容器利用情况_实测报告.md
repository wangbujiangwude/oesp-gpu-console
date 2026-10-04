# GPU 使用率检测 + 安卓容器是否真正用上 —— 实测报告

> 时间：2026-09-30 18:42–18:52
> 结论：**安卓容器确实用上了硬件 GPU（Mali-G52 / Panfrost）和硬件解码器（VDEC），
> 但当前 GPU 负载极低（近乎空闲），串流编码仍是软件。**

---

## 一、先说测量方法（重要）

这台机器上"GPU"是**两块独立硬件**，必须分开看：

| 硬件 | 驱动 | 中断线 | 用途 |
|---|---|---|---|
| **Mali-G52（3D/渲染）** | 开源 `panfrost`（mesa 24.0.8） | `panfrost-job` / `-mmu` / `-gpu` | UI 合成、OpenGL |
| **VDEC（视频硬解）** | `meson-vdec` | `vdec` | H.264/HEVC 解码 |

### 为什么不用 sysfs 读"使用率百分比"

- 没有 `/dev/mali`（闭源 Mali 驱动未暴露字符设备）
- panfrost 的 sysfs（`ffe40000.gpu`）只有 `drm/power/profiling` 等，**没有 utilization 节点**
- `/sys/class/vdec/*` 是**致命雷区**（只读 cat 就整机死锁），全程规避

所以改用 **中断计数增长率** 作为负载代理指标（只读 `/proc/interrupts`，绝对安全）。

> ⚠️ **踩过一个坑**：一开始盯的是 `panfrost-gpu`，它恒为 0，差点误判"GPU 没用"。
> 真正的负载指标是 **`panfrost-job`**（job 完成中断，累计已 49499 次）。

---

## 二、实测数据

### 1. GPU（Mali-G52 / Panfrost）

| 场景 | panfrost-job 速率 | 说明 |
|---|---|---|
| 空闲（云手机串流中） | **0.26 /秒** | 只有 agent 的周期性截图（10s 一次） |
| **停掉 cloudphone-agent** | **0 /秒** | 串流一停，GPU 立刻归零 |
| 恢复 agent | 0.2 /秒 | 恢复串流，GPU 重新工作 |
| **连续滑动 30 次（UI 渲染）** | **20.26 /秒** | **比空闲高 78 倍** |

**对照实验因果明确**：GPU job 只在串流时出现，停掉串流立刻归零 ——
说明这些 GPU 负载**就是安卓容器产生的**，不是宿主其他进程。

### 2. 渲染后端：确认是硬件，不是软件

```
dumpsys SurfaceFlinger:
  GLES: Mesa, Mali-G52 (Panfrost), OpenGL ES 3.1 Mesa 24.0.8
```

配置也指向 host GPU：
```
ro.hardware.egl = mesa
ro.hardware.vulkan = panfrost
gralloc.gbm.device = /dev/dri/renderD128
ro.boot.redroid_gpu_mode = host
```

**宿主持有 `renderD128` 的进程**（即安卓容器进程）：
`surfaceflinger`、`composer@2.1`、`allocator@2.0`、`systemui`、`launcher3`、
`settings`、`webview_shell`、`mark.via` —— 容器进程**确实打开了 GPU 设备节点**。

### 3. VDEC（视频硬解）

| 场景 | vdec 中断增量 |
|---|---|
| 云手机串流中 | **0**（串流是编码，不碰解码器） |
| **容器内跑硬解 500 帧** | **+454** |
| 宿主跑硬解 500 帧（对照） | **+454（完全相同）** |

---

## 三、结论：安卓容器到底用上没有？

| 能力 | 用上了吗 | 证据 |
|---|---|---|
| **3D GPU（Mali-G52）** | ✅ **是（硬件）** | 后端是 Panfrost 非 llvmpipe；容器进程持有 renderD128；停串流 GPU 归零、滑动时涨 78 倍 |
| **视频硬解（VDEC）** | ✅ **是** | 容器内硬解 vdec 中断 +454，与宿主逐次一致 |
| **视频硬编** | ❌ **没有** | 串流期间 vdec 中断为 0；本机无编码硬件 |
| **串流链路（scrcpy 抓屏编码）** | ❌ **走软件** | 编码不产生 vdec 中断，画面用 MediaCodec 软编 |

### 一句话总结

**GPU 和硬解都真正接上了，但目前几乎闲置。**
当前 GPU 只承担静态桌面合成（0.26 job/秒），真正吃 CPU 的是**软件 H.264 编码**——
那是云手机串流的瓶颈，而硬解帮不上忙（方向相反）。

---

## 四、实用建议

### 怎么自己看 GPU 是否在工作

```bash
# 看 job 中断增长（等 10 秒再读一次，算差值）
awk '$NF=="panfrost-job"{print $2+$3+$4+$5+$6+$7}' /proc/interrupts
# 看硬解是否触发
awk '$NF=="vdec"{print $2+$3+$4+$5+$6+$7}' /proc/interrupts
```

### 想让 GPU 真正跑起来

当前云手机桌面是静态的，所以 GPU 闲着。真正压 GPU 的场景：
- 云手机里**播放视频**（合成 + 渲染）
- 跑 **3D 游戏 / WebGL**
- 浏览器滑动、页面动画

### 想降低云手机串流的 CPU

瓶颈是软件编码，**硬解解决不了**。可行的方向：
- 降低串流参数：`-bitrate`、`-max-fps`、`-max-size`（agent 参数）
- 控制器里 `DEFAULT_SETTINGS` 现在是 `fps:60, size:1280, bitrate:10` ——
  **60fps + 1280 对软件编码太重**，降到 30fps / 720 能明显省 CPU
- 换有硬编的内核（本机没有编码驱动，代价大）

---

## 五、本次排查的坑（记录）

- ❌ `panfrost-gpu` 恒为 0，**不能**当负载指标 → 要用 `panfrost-job`
- ❌ 不能 `cat /sys/class/vdec/*`（三次整机死锁的教训）
- ⚠️ 对照实验里短暂停了 agent（约 20 秒），云手机会短暂离线后自动恢复
