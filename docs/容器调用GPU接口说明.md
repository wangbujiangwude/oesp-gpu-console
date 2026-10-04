# 容器调用 GPU 接口说明（OESP / fnOS）

> 实测日期：2026-09-30 ｜ 平台：Amlogic S922X · 内核 6.18.18 · Docker on fnOS

---

## 一、要挂哪些设备节点

本机"GPU"是两块独立硬件，按需选择挂载：

| 接口 | 设备节点 | 权限 | 用来干什么 |
|---|---|---|---|
| **视频硬解** | `/dev/video0` | `root:video` 660 | H.264 硬解（V4L2 stateful decoder） |
| **3D 渲染** | `/dev/dri/renderD128` | `root:render` 660 | OpenGL ES / EGL / GBM（**无显示输出时用这个**） |
| **3D + 显示** | `/dev/dri/card0` | `root:video` 660 | 需要 modesetting / 直接输出画面时 |
| 零拷贝缓冲 | `/dev/dma_heap/system` | `root:root` 600 | dma-buf 分配（**仅 root 可访问**） |

### 组 ID 速查（本机）

```bash
getent group video render
# video:x:44:
# render:x:105:
```

---

## 二、✅ 推荐方案：最小权限（非 privileged）

**实测结论：不打开 privileged 也能完整使用硬解，性能零损失。**

```bash
docker run -d --name myapp \
  --device=/dev/video0 \
  --device=/dev/dri/renderD128 \
  --device=/dev/dri/card0 \
  --group-add 44 \     # video
  --group-add 105 \    # render
  <arm64镜像> sleep infinity
```

### 实测数据（500 帧 720p H.264）

| 项目 | 结果 |
|---|---|
| 容器内耗时 | **1.948 s（256 fps）** |
| 宿主耗时 | 1.963 s（254 fps） |
| 性能损失 | **0%** |
| 容器 vs 宿主输出 | **字节完全一致**（`cmp` OK） |
| 容器 vs ffmpeg 软解 | **字节完全一致**（`cmp` OK） |

> ⚠️ **不要用 `--group-add video` 这种组名写法** —— 组名必须在容器内存在，
> 否则 `docker run` 直接报错退出。用 **GID 数字**（44 / 105）最稳。

### compose 写法

```yaml
services:
  myapp:
    image: your-image:arm64
    devices:
      - /dev/video0
      - /dev/dri/renderD128
      - /dev/dri/card0
    group_add:
      - "44"    # video
      - "105"   # render
```

---

## 三、⛔ privileged 方案（redroid 专用，有风险）

安卓容器（`androidemu-android`）必须是 `privileged: true`——redroid 上游要求，
非特权替代方案（`device_cgroup_rule` / `cap-add=ALL`）实测容器静默退出、无法开机。

**但 privileged 会把雷区一起暴露进容器**：

| 容器类型 | `/dev/video26` 可见？ | open 的后果 |
|---|---|---|
| 最小权限容器 | ❌ 不可见（`No such file or directory`） | 安全 |
| privileged 容器 | ✅ **可见** | **整机内核级死锁，必须物理断电** |

**所以：普通应用一律用最小权限方案。** 只有 redroid 这类必须特权的才开 privileged，
且要清楚容器里的操作能搞挂整机。

---

## 四、⛔ 雷区在容器里同样致命

这四条在容器内触发，后果与宿主**完全一样**（整机死锁、无看门狗、须断电）：

1. `open /dev/video26`
2. `cat /sys/class/vdec/*`
3. `ffmpeg -c:v h264_v4l2m2m`
4. `rmmod` 闭源 GPU 驱动

容器**不是安全边界**——容器和宿主共享同一个内核，驱动挂了整机一起死。

---

## 五、容器内怎么用硬解

### 5.1 准备：静态二进制是关键技巧

🔑 **宿主 `gcc -static` 编出的 Linux/arm64 二进制，可以直接跑在任意 Linux 容器里**
（同内核 → syscall ABI 一致，静态链接不依赖容器的 libc 版本）。
**甚至能跑在 Android 的 bionic 上**（已实测）。

```bash
# 宿主编译
gcc -O2 -static -o vdec-static vdec_test3.c

# 拷进容器直接用
docker cp vdec-static myapp:/vdec
docker exec myapp chmod +x /vdec
```

### 5.2 调用

```bash
docker exec -e PRELUDE_AU=2 -e TAIL_AU=1 -e COMPACT=1 myapp \
  /vdec /dev/video0 /in.h264 0 /dev/null
```

| 环境变量 | 值 | 作用 |
|---|---|---|
| `PRELUDE_AU` | 2 | 预热：复制前 2 个 AU（IDR+第1个P）。**不设会 Y 偏移**，只预热 1 个 IDR 无效 |
| `TAIL_AU` | 1 | 末尾追加首帧 IDR 顶出尾帧（尾部固定丢 1–3 帧） |
| `COMPACT` | 1 | 输出紧凑 NV12（真实高度 720 而非对齐 768），ffmpeg 才能直接读 |

### 5.3 消费帧

```bash
# 方案 A：管道（推荐，无落盘开销）
docker exec myapp /vdec /dev/video0 in.h264 0 - | ffmpeg -f rawvideo -pix_fmt nv12 -s 1280x720 -r 25 -i - ...

# 方案 B：落盘后拷出
docker cp myapp:/out.nv12 ./out.nv12
ffmpeg -f rawvideo -pix_fmt nv12 -s 1280x720 -r 25 -i out.nv12 -c:v libx264 -crf 23 out.mp4
```

> ⚠️ **容器内落盘要小心**：安卓容器实测 → `/dev/null` 1.97 s，→ `/data` 7.70 s（慢 3.9 倍）。
> 这不是磁盘慢（容器内 `dd` 有 307 MB/s），是**边解边写小块争抢**。**一律优先用管道。**

---

## 六、验证清单

```bash
# 1. 节点可见 + 权限正确
docker exec myapp sh -c 'ls -l /dev/video0 /dev/dri/renderD128; id'

# 2. 硬解可用性（最简单的一票否决测试）
docker exec -e PRELUDE_AU=2 -e TAIL_AU=1 -e COMPACT=1 myapp \
  /vdec /dev/video0 /in.h264 0 /dev/null
# 期望：取出帧数 500、用时 ~1.95s

# 3. 正确性（容器内 vs 软解）
docker exec ... /vdec /dev/video0 /in.h264 60 /out.nv12
docker cp myapp:/out.nv12 ./c.nv12
ffmpeg -f h264 -framerate 25 -i in.h264 -frames:v 60 -pix_fmt nv12 -f rawvideo ./s.nv12
cmp c.nv12 s.nv12 && echo "✓ 字节一致"

# 4. 3D GPU 是否被容器用上（宿主侧看中断增长）
awk '$NF=="panfrost-job"{print $2+$3+$4+$5+$6+$7}' /proc/interrupts
```

---

## 七、3D GPU（OpenGL ES）在容器里的用法

硬解是"打开设备节点就能用"，3D 渲染还需要**用户态图形栈**：

```bash
# 需要把宿主的 mesa 驱动映射进容器（ARM64 路径）
-v /usr/lib/aarch64-linux-gnu/dri:/usr/lib/aarch64-linux-gnu/dri:ro
```

容器内确认后端：

```bash
# Android 容器实测报告
GLES: Mesa, Mali-G52 (Panfrost), OpenGL ES 3.1 Mesa 24.0.8
```

> 注意：**Vulkan 在本机实际是 llvmpipe 软件实现**（`vulkaninfo` 报 `deviceName = llvmpipe`），
> 虽有 `panfrost_icd.json` 但未生效。需要硬件加速就用 **OpenGL ES**，别用 Vulkan。

---

## 八、常见坑速查

| 现象 | 原因 | 解决 |
|---|---|---|
| `docker run` 报 "Run 'docker run --help'" | `--group-add video` 组名在容器内不存在 | 改用 GID 数字 `44`/`105` |
| 容器起不来 `Exited(255)` | 镜像是 amd64，机器是 arm64 | 用 `docker inspect --format '{{.Architecture}}'` 确认镜像架构 |
| 容器内解 0 帧 | 没设 `PRELUDE_AU` / 没 drain | 设 `PRELUDE_AU=2 TAIL_AU=1` |
| 输出帧错位/花屏 | 高度被对齐成 768 | 设 `COMPACT=1` |
| 尾部少 1–3 帧 | 固件固有问题（固定常数，非按比例） | 设 `TAIL_AU=1`，容差 3 内可接受 |
| 容器内解码慢 4 倍 | 落盘争抢 | 改用管道输出 |
| 整机挂死 | 碰了雷区（见第四节） | 物理断电 |
