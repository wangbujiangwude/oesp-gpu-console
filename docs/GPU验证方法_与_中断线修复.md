# OES Plus GPU 中断线修复 + 成果验证方法

设备：OneThing Cloud OES Plus（Amlogic S922X / Mali-G52），fnOS，内核 `6.18.18.c997-trim`
时间：2026-09-29 22:09–22:20

---

## 一、这次修了什么

### 问题
`dmesg` 长期刷 `panfrost ffe40000.gpu: gpu sched timeout, js=0/1, status=0x0, head==tail`，
空闲约 2 次/分钟，渲染压力下约 4 次/秒。此前已实测排除欠压/频率、`use_memfd`、电源域三个假设，方向都错了。

### 根因：中断线接错
`/proc/interrupts` 采样（修复前）：

| IRQ | GIC | 名称 | 计数 |
|-----|-----|------|------|
| 24 | 194 | panfrost-gpu | 100000（中断风暴，**已被内核禁用**） |
| 25 | 193 | panfrost-mmu | 5 |
| 26 | 192 | panfrost-job | **0（从未触发）** |

`dmesg` 里躺着决定性一行：
```
irq 24: nobody cared (try booting with the "irqpoll" option)
 ... panfrost_gpu_irq_handler [panfrost]
Disabling IRQ #24
```

对照原厂 DTB 备份发现**命名顺序是反的**：
- 原厂：`interrupt-names = "GPU","MMU","JOB"` → **160=GPU、161=MMU、162=JOB**
- 主线 panfrost 按名字取：期望 `job` 在第一位 → 拿到 160

结果：硬件上真正的 job 完成中断 **SPI 162** 被 `panfrost_gpu_irq_handler` 接管（Bifrost 读不到 GPU 状态寄存器 → 返回 `IRQ_NONE` → 内核判 nobody cared → 禁用），而真正的 job handler 挂在从不响的 160 上 → 每个作业都收不到完成通知，只能硬等 1 秒超时。

### 修复
只改 DTB 的 `gpu@ffe40000` 节点，交换 `interrupts` 第 1、3 项（名字保持 `job,mmu,gpu` 不变）：

```diff
- interrupts = <0x00 0xa0 0x04  0x00 0xa1 0x04  0x00 0xa2 0x04>;
+ interrupts = <0x00 0xa2 0x04  0x00 0xa1 0x04  0x00 0xa0 0x04>;
  interrupt-names = "job", "mmu", "gpu";
```

即：`job → SPI 162`（真正的 JOB 线），`mmu → 161`，`gpu → 160`（Bifrost 上该线本就不响）。
备份：`/boot/dtb/amlogic/meson-g12b-s922x-oes-plus-00050000.dtb.bak.irq.20260929-220933`

---

## 二、验证方法

### 方法 A：一键脚本（推荐）

脚本已部署到设备上 `/usr/local/bin/gpu-verify.sh`。

```bash
sudo bash /usr/local/bin/gpu-verify.sh
```

约 40 秒跑完，自动输出 18 项 `[PASS]/[FAIL]` 判定，覆盖五个层面：
1. 驱动栈（panfrost 加载、mali_kbase 已屏蔽、`/dev/dri/renderD128`、`/dev/dma_heap/system`、GPU 在 VPU 电源域）
2. 中断线（job 中断必须落在 GIC 194 且被触发过、无 `Disabling IRQ`、无 `nobody cared`）
3. job 超时（空闲 10 秒新增必须为 0）
4. 安卓 host GPU（`gpu_mode=host`、`gralloc=gbm`、`egl=mesa`、SurfaceFlinger 渲染器为 Mali-G52）
5. 实时渲染压力（20 次强制合成，统计 job 中断增量、timeout 增量、截图是否出画）

**当前结果：PASS=18 FAIL=0**

### 方法 B：手动逐条核对（不想跑脚本时）

```bash
# 1) 中断线归位：job 必须在 GIC 194 且有计数；gpu(192) 为 0 属正常
grep -E "panfrost-(job|mmu|gpu)" /proc/interrupts

# 2) 中断没有被内核禁用 / 没有中断风暴
dmesg | grep -E "Disabling IRQ|nobody cared"     # 应无输出

# 3) job 超时（核心指标，修前 400+，修后应为 0）
dmesg | grep -c "gpu sched timeout"

# 4) 安卓确实在用真 GPU
docker exec androidemu-android getprop ro.hardware.gralloc     # gbm
docker exec androidemu-android getprop ro.hardware.egl         # mesa
docker exec androidemu-android dumpsys SurfaceFlinger | grep -i "GLES:"
# 期望: GLES: Mesa, Mali-G52 (Panfrost), OpenGL ES 3.1 Mesa 24.0.8
# 若是 ANGLE(Vulkan SwiftShader) 则说明回退到软渲染

# 5) 谁真的打开了 renderD128
cat /sys/kernel/debug/dri/0/clients
# 期望出现 surfaceflinger / composer / systemui / launcher3 / system_server

# 6) 施加渲染压力，看超时是否复发
T=$(dmesg | grep -c "gpu sched timeout")
for i in $(seq 1 20); do docker exec androidemu-android screencap -p /data/local/tmp/v.png >/dev/null 2>&1; done
sleep 6
echo "压力新增 timeout: $(( $(dmesg | grep -c 'gpu sched timeout') - T ))"   # 期望 0

# 7) 出画确认
docker exec androidemu-android screencap -p /data/local/tmp/s.png
docker exec androidemu-android ls -l /data/local/tmp/s.png    # 应 > 100KB
```

---

## 三、修复前后对比

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| panfrost-job 中断计数 | **0**（从未触发） | **706**，压力下持续响应 |
| panfrost-job 所在中断线 | GIC 192（SPI 160，GPU 线） | GIC 194（SPI 162，硬件 JOB 线） |
| panfrost-gpu 中断 | 100000，被内核禁用 | 0（Bifrost 上该线本就不响） |
| `Disabling IRQ #24` | 有 | 无 |
| 开机累计 gpu sched timeout | 400+（2 小时） | **0** |
| 压力 20 次合成新增 timeout | 约 40（10 秒内） | **0** |
| SurfaceFlinger 渲染器 | Mali-G52（但一直超时） | Mali-G52（无超时） |
| 容器 CPU 占用 | 0.03% ~ 0.07% | 0.03% ~ 0.07% |

---

## 四、回退

```bash
sudo cp /boot/dtb/amlogic/meson-g12b-s922x-oes-plus-00050000.dtb.bak.irq.20260929-220933 \
        /boot/dtb/amlogic/meson-g12b-s922x-oes-plus-00050000.dtb
sudo systemctl reboot
```

redroid 侧回退（回到软渲染）：`sudo bash /docker/rollback_hostgpu.sh`

---

## 五、还没解决的 / 要注意的

1. **应用模板会覆盖**：`/vol1/@appcenter/androidemu/docker/docker-compose.yaml` 第 59 行仍写死 `androidboot.redroid_gpu_mode=guest`。重装或升级 androidemu 应用后会被覆盖回软渲染。要持久化，得改应用包里这一行，并补 `/dev/dri`、`/dev/dma_heap` 直通。
2. **硬解仍然不可用**：`/dev/video26` 存在但送流会硬挂；`ffmpeg -hwaccels` 只有 cuda/drm/opencl/rkmpp/v4l2request，无 amlogic。官方 c997-trim 内核的晶晨媒体栈残缺（`registers.ko` 未注册 platform 驱动，codec-io 总线表为空）。要真硬解只能换 ophub 主线内核（`meson_vdec`）。
3. **`_opp_set_regulators: no regulator (mali) found`** 仍在——DT 里没有 GPU 供电 regulator，panfrost 管不了调压。这不影响本次修复后的稳定性，但意味着无法做 GPU 电压/超频调优。
4. webrtc 8443 裸 GET 返回 400（服务进程在），建议用浏览器实际打开一次确认。
