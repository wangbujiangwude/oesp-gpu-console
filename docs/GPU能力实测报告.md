# OneThing Cloud OES Plus（S922X / Mali-G52）GPU 能力实测报告

设备：fn-OESP（`OneThing Cloud OES Plus`），内核 `6.18.18.c997-trim`，aarch64 6 核，3.6 GiB
驱动：主线 `panfrost`（自编译）+ Mesa 25.0.7（系统自带）
测试方法：python ctypes 直接 dlopen `libEGL.so.1` / `libGLESv2.so.2`，surfaceless 平台离屏渲染（全程只读，未安装任何软件包）

---

## 一、确认可用的能力（已实测）

| 项目 | 实测结果 |
|---|---|
| GL 渲染器 | **`Mali-G52 (Panfrost)`**（root 下） |
| OpenGL ES | **3.1**，GLSL ES 3.10，134 个扩展 |
| Vulkan | Mali-G52，apiVersion **1.0.305**，需强制开关，非兼容实现 |
| 频率 | 125 MHz – 800 MHz（simple_ondemand），当前 500 MHz |
| 1080p 填充率 | 1205 Mpix/s（581 fps） |
| 4K 填充率 | 1620 Mpix/s（195 fps） |
| dma-buf | 支持 `EGL_EXT_image_dma_buf_import(_modifiers)`、`EGL_MESA_image_dma_buf_export` |
| 设备节点 | `/dev/dri/card0`、`/dev/dri/renderD128`、`/dev/dma_heap/system` |

Vulkan 启用方式（默认被 Mesa 封禁）：

```
export PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/panfrost_icd.json
```

---

## 二、确定不能做的事

| 用途 | 结论 | 依据 |
|---|---|---|
| 视频硬解（VDEC） | ❌ 一送流就硬挂 | `/dev/video26`(aml-vcodec-dec) probe 残缺，codec-io 总线表全空，已证实不可外部修复 |
| 视频硬编（VENC） | ❌ | 只有私有 `/dev/amvenc_avc`，非 v4l2，ffmpeg 无法使用 |
| VA-API / VDPAU 转码 | ❌ | `*_drv_video.so` 只有 d3d12/nouveau/r600/radeonsi/virtio，无 panfrost；本机 ffmpeg 也没编 vaapi |
| OpenCL / AI 推理加速 | ❌ | 仅 `libOpenCL.so.1` loader，无 `/etc/OpenCL/vendors/`，无 rusticl/clover 驱动 |
| 画面输出（HDMI/桌面） | ❌ | `/sys/class/drm/` 无任何 connector，是 render-only 节点 |
| GPU 图像处理再回读 | ⚠️ 不划算 | 1080p RGBA 上传 80.6 MB/s，渲染+回读仅 5.3 MB/s |

> 一句话：GPU 能画，但既不能解、不能编、也不能把结果快速搬回 CPU。

---

## 三、当前唯一有现实价值的用途：安卓容器图形加速

现状检查：

- 容器内 `/dev/dri` 有 card0 / renderD128（privileged 模式带进去的）
- 但 SurfaceFlinger 报告：`GLES: ANGLE (Google, Vulkan SwiftShader Device)` → **仍在软件渲染**，GPU 一点没用上
- `ro.hardware.gralloc = redroid`、`ro.hardware.egl = angle`
- 好消息：镜像内**自带 `gralloc.gbm.so` 和 `libgbm.so.1`**，具备切 host GPU 的条件

可行做法：给 redroid 启动参数加 `androidboot.redroid_gpu_mode=host`（配合 `/dev/dri` + `/dev/dma_heap` 映射），重建容器（数据卷 `androidemu-data` 保留，起不来可原样回退）。

---

## 四、两个需要处理的限制

1. **权限**：`/dev/dri/card0` 属 `root:video`、`renderD128` 属 `root:render`，而 `render`/`video` 组成员为空 →
   除 root 外任何服务都拿不到 GPU，Mesa 会**静默回退 llvmpipe**（普通账号实测 RENDERER 就是 llvmpipe）。
   修法：`sudo usermod -aG render,video <用户名>`，重登生效。
2. **软转码基线（对照参考）**：
   - 720p → libx264 ultrafast：5 s 片源耗时 0.78 s ≈ **6.4x 实时**
   - 1080p → libx264 veryfast：5 s 片源耗时 3.68 s ≈ **1.36x 实时**（单路可行，多路吃不住）

---

## 五、结论

这块 GPU 现在处于"**能用，但没人用**"的状态：驱动、频率、渲染管线全部正常，
却因为硬解/硬编/通用计算三条路都断着，加上没有任何服务具备访问它的权限，
实际负载为 0。

优先级建议：

1. 把安卓容器切到 host GPU（唯一能感知到的收益：界面流畅度、CPU 占用）
2. 打通 render/video 组权限（让非 root 服务有机会用上）
3. 若目标是**相册/影音转码**，别再投入 —— 只能软转（1 路 1080p），要真硬解必须换 ophub 主线内核（`meson_vdec`）
