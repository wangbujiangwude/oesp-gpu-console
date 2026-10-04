# 项目梳理清单 · OESP GPU 控制台

> 扫描时间：2026-10-04　｜　工作区：`<WORKSPACE>`
> 原文扫描时工作区总体积 **2.66 GB**，其中 **2.0 GB 是 Android NDK**（不属于项目代码）

---

## 0. 发布范围（本仓库实际含有什么）

> 🔒 本节为 2026-10-04 收窄发布范围后的最新状态。
> 用户要求：**只开源 GPU 控制台代码 + FPK 安装包 + 测试过程中的部分数据，
> 删除一切与 SSH / 个人信息相关的内容。**

本仓库只发布三样东西：

| 内容 | 路径 | 说明 |
|---|---|---|
| **GPU 控制台源码** | `gpu-console/` | fnOS 原生应用（FPK）完整工程 |
| **FPK 安装包** | `release/gpuconsole_1.1.0.fpk` | 成品包，可直接安装 |
| **部分测试数据** | `docs/` | 17 篇实测报告，**已脱敏** |

**已移出仓库**（本地留底于 `_excluded_local/`，含敏感信息，绝不可公开）：

| 目录 | 内容 | 移出原因 |
|---|---|---|
| `omx-meson/` | OMX 插件 C++ 源码 | 超出发布范围（其预编译产物随 FPK 分发） |
| `tools/` | AOSP 头文件 + 2 GB NDK | 体积与非发布范围 |
| `cputype/` | 内核诊断程序 | 非发布范围 |
| `androidemu-gpu-adapt/` | compose 模板 | 含设备内网信息 |
| `_cmp/` | 历史 FPK 版本对比样本 | 非发布范围 |
| 根目录 394 个散落文件 | 远程运维脚本、调试脚本、截图 | **含明文设备密码 / 内网地址 / 本机路径** |

**脱敏处理**：已对发布范围内全部文本执行敏感串替换 ——
公网地址→`<PUBLIC_IP>`、内网地址→`<LAN_IP>`、容器网桥/容器地址→
`<DOCKER_BRIDGE_IP>`/`<CONTAINER_IP>`、登录账号与口令→`<REDACTED>`、
本机目录路径→`<WORKSPACE>`。

应用发布者署名（`manifest` 的 maintainer/distributor、控制台页面页脚）与
发布者主页链接属于作者**主动公开**的身份信息，**不在脱敏范围**，原样保留。
（此处不再列出原始值，避免二次泄露。）

---

## 0b. 原工作区实况（扫描结果，供追溯）

原始工作区**不是**一个规整的项目仓库，而是「**6 个真实项目目录 + 一个巨大的调试沙盒**」混在一起。
真正的项目代码约 **5 MB / 30 个源文件**；剩下的 **459 个 `.sh`、79 个 `.py`、33 个 `.md`、158 个 `_` 开头文件**
绝大多数是排查某个具体问题时写的一次性脚本。

| 类别 | 数量 | 是否纳入本仓库 |
|---|---|---|
| `gpu-console/` | 1 个 | ✅ 是（主体） |
| 其余项目目录（omx-meson / vdec_src / tools / cputype / androidemu-gpu-adapt） | 5 个 | ❌ 否 |
| 根目录一次性调试脚本 | 459 `.sh` | ❌ 否 |
| 根目录一次性 Python 脚本 | 79 `.py` | ❌ 否 |
| 技术报告 Markdown | 33 篇 | ⚠️ 17 篇入 `docs/`，14 篇因含个人信息剔除 |
| Android NDK | 2.0 GB | ❌ 否 |

---

## 1. 目录结构总览

```
工作区根/
│
├── 【A】gpu-console/          ★ GPU 控制台（fnOS 原生应用）── 本项目对外主体
│   ├── server/gateway.py        核心：单文件 HTTP 网关 + 前端（1448 行）
│   ├── scripts/
│   │   ├── oesp_gpu_fix.sh      ★ 体检与修补引擎 v2（751 行，20+ 项检测）
│   │   ├── omx_autodeploy.sh    ★ 常驻自愈（cron 每分钟）：注入插件/修权限/刷 codec 缓存
│   │   ├── guard_autodeploy.sh  ★ 自愈完整性守卫：主脚本被截断时从备份自动恢复
│   │   ├── gpu_fix.sh           v1 修补脚本（已由 v2 取代，保留参考）
│   │   ├── gpu_status.sh        命令行只读状态查询（SSH 可直接用）
│   │   ├── grant_root.sh        最小 root 授权（写 sudoers，只放行固化脚本）
│   │   ├── vdec_test3.c         V4L2 硬解取帧参考实现（C）
│   │   └── libstagefrighthw32.so  随包分发的预编译 32 位 OMX 插件
│   ├── cmd/                     fnOS 生命周期钩子（install/upgrade/config/main…）
│   ├── config/{privilege,resource}
│   ├── ui/config                iframe 接入声明（gatewayPrefix + gatewaySocket）
│   ├── ui/images/               icon_64 / icon_256
│   ├── wizard/install           安装向导
│   ├── ICON.PNG / ICON_256.PNG  应用图标
│   ├── make_icon.py             生成图标
│   ├── manifest                 应用元信息（version=1.1.0, checksum=app.tgz 的 md5）
│   ├── LICENSE                  MIT（已存在）
│   ├── build_fpk.sh             打包脚本（99 行）
│   └── app.tgz                  打包中间产物（== 会变，已排除）
│
├── 【B】⛔ omx-meson/         Android OMX IL 硬解插件源码 —— **已移出仓库**
│   │                          （本地留底于 _excluded_local/omx-meson/）
│   ├── meson_omx_plugin.cpp     插件主体（2087 行）：OMX IL 组件实现
│   ├── meson_vdec.h             V4L2 后端封装（760 行）：meson-vdec 交互
│   ├── build_omx.sh             编译入口（同时出 64/32 位）
│   └── …
│   ⚠ 不在发布范围内，但其**预编译 32 位产物**随 FPK 分发：
│     gpu-console/scripts/libstagefrighthw32.so
│
├── 【C】⛔ _excluded_vdec_src/ 已移出仓库（原 vdec_src/）
│   ├── Linux 内核 meson-vdec 驱动源码：vdec.c (1121) / vdec_1.c /
│   │   vdec_helpers.c / vdec_platform.c / codec_h264.c (485) / esparser.c (457)
│   ├── Kconfig / Makefile / LICENSE（GPL-2.0）
│   └── 状态：**GPL-2.0+，非本项目原创**（BayLibre SAS / Maxime Jourdan）
│       为保持仓库纯 MIT，已移至本目录并被 .gitignore 排除；
│       本地留底仅供查阅，可随时删除。项目不依赖它的任何一行。
│
├── 【D】⛔ tools/             构建工具链 —— **已移出仓库**（AOSP 头文件 + 2 GB NDK）
│
├── 【E】⛔ cputype/           内核诊断小工具（LKM）—— **已移出仓库**
│
├── 【F】⛔ androidemu-gpu-adapt/ 安卓容器适配 —— **已移出仓库**（含设备内网信息）
│
├── 【G】⛔ _cmp/              历史 FPK 版本对比样本 —— **已移出仓库**
│
├── 【H】docs/                 ★ 测试数据（17 篇，已脱敏）
│   ├── README.md               索引 + 建议阅读顺序 + "已推翻结论"提醒
│   ├── 硬解优化与软硬解切换…md    硬解负收益实测
│   ├── 相册硬解失败与CPU实测…md    HEVC 为何无法硬解
│   └── …（其余见 docs/README.md）
│
├── 【I】release/              ★ FPK 安装包
│   └── gpuconsole_1.1.0.fpk    可直接安装到飞牛设备
│
├── ★ 开源准备文件
│   ├── LICENSE                 MIT（纯 MIT，署名 laowang）
│   ├── NOTICE                  第三方与闭源组件声明
│   ├── CONTRIBUTING.md         贡献指南（★ 5 条致命红线 + 踩坑自查）
│   ├── README.md               项目说明（★ 第 6 节：弊端与局限）
│   ├── PROJECT_INVENTORY.md    本文件
│   └── .gitignore
│
└── ⛔ _excluded_local/        本地留底、不入库（含敏感信息，绝不可公开）
    ├── omx-meson/ cputype/ tools/ androidemu-gpu-adapt/ _cmp/
    ├── docs_more/              14 篇含内网拓扑/远程登录细节的报告
    ├── run_many.py r.py switch_ssh.py …（**含明文设备密码**）
    └── 394 个一次性调试脚本与截图
```

---

## 2. 模块用途与依赖关系

### 2.1 依赖图

```
                    ┌─────────────────────────────────────┐
                    │  飞牛 fnOS 桌面 / nginx 网关         │
                    │  /app/gpuconsole/*  →  unix socket   │
                    └──────────────┬──────────────────────┘
                                   │ HTTP over Unix Socket
                    ┌──────────────▼──────────────────────┐
        【A】       │  gpu-console/server/gateway.py       │
      GPU 控制台     │  · /api/status   状态（只读采集）     │
                    │  · /api/detect   体检（20 项）        │
                    │  · /api/repair   修补（容器/宿主/重建）│
                    │  · /api/decoder  软硬解切换           │
                    │  · /api/android  容器信息             │
                    └───┬──────────────────────┬──────────┘
                        │ sudo -n              │ docker exec / docker cp
                        │（经 grant_root 授权） │
          ┌─────────────▼─────────┐   ┌───────▼────────────────────┐
          │ scripts/oesp_gpu_fix.sh│   │  安卓容器 androidemu-android│
          │ · modprobe / udev      │   │  （redroid 12, privileged） │
          │ · chmod /dev/video0    │   │                             │
          │ · 注入 OMX 插件 ────────┼──▶│  /vendor/lib/              │
          │ · 重建容器（compose）   │   │    libstagefrighthw.so     │
          └───────────────────────┘   └───────┬─────────────────────┘
                                              │ dlopen + createOMXPlugin
                        ┌─────────────────────▼──────────────────┐
             【B】       │  omx-meson/out/libstagefrighthw32.so    │
           OMX 插件       │  （32 位！HAL 进程 media.codec 是 32 位）│
                        │  meson_omx_plugin.cpp + meson_vdec.h    │
                        └─────────────────┬───────────────────────┘
                                          │ V4L2 ioctl
                        ┌─────────────────▼───────────────────────┐
                        │  宿主内核 meson-vdec 驱动 → /dev/video0   │
                        │  （闭源固件由 amlogic_codec_mm 等支撑）    │
                        └──────────────────────────────────────────┘
```

> 说明：开发期曾参考 Linux 内核 meson-vdec 源码来理清上面这层的协议行为，
> 但该参考代码（GPL-2.0+）**已移出仓库**，见 `_excluded_vdec_src/`。

### 2.2 各模块详解

#### 【A】GPU 控制台 —— **本项目对外的主体交付物**

| 文件 | 行数 | 用途 |
|---|---|---|
| `server/gateway.py` | 1448 | **入口**。单文件实现 HTTP 服务 + 前端页面（HTML/CSS/JS 内嵌为 Python 原始字符串）+ 数据采集 + API 路由。**零第三方依赖，仅标准库** |
| `scripts/oesp_gpu_fix.sh` | 724 | 体检与修补引擎。`--detect` 输出结构化 JSON（20 项），`--fix` 精准修补，`--decoder {status,soft,hard}` 切换软硬解 |
| `scripts/grant_root.sh` | — | 让用户 SSH 跑一次，把修补脚本固化到 root 拥有的 `/usr/local/lib/oesp-gpu/` 并写入 sudoers（**只放行脚本本身**，防提权） |
| `scripts/gpu_status.sh` | — | 命令行只读查询，SSH 直接可用，不依赖 Web |
| `scripts/gpu_fix.sh` | — | v1（照单全修），已被 v2 取代，保留作参考 |
| `scripts/vdec_test3.c` | — | V4L2 硬解取帧参考实现，也是 `meson_vdec.h` 的算法蓝本 |
| `cmd/main` | — | fnOS 生命周期入口，把 start/stop/status 转调 `gateway.py` |
| `manifest` | — | 应用元信息。**注意：`checksum` 字段 = `app.tgz` 的 md5，改任何文件后必须重算** |
| `build_fpk.sh` | 99 | 打包：生成 app.tgz → 算 md5 → 写 manifest → tar.gz → `.fpk` |

**体检 20+ 项**：宿主层 H1–H10（meson-vdec 模块、开机自启、/dev/video0 权限、mali_kbase 屏蔽、3D 节点、panfrost、解码工具、CMA、GPU 调度超时、udev），容器层 C1–C10（容器运行、GPU 模式、实际渲染器、设备节点、OMX 插件一致性、预热参数、临时目录权限等），风险项 R1（特权容器暴露雷区），自愈层 S1–S2（自愈定时任务、完整性守卫）。

**自愈链路（`--fix --host` 第 6 步自动装配）**：修补脚本把包内的 `omx_autodeploy.sh` + `guard_autodeploy.sh` + `libstagefrighthw32.so` 复制进 root 拥有的 `/usr/local/lib/oesp-gpu/`（应用目录是 777，直接在那儿跑 root 定时脚本等于开放提权），再往 root crontab 写两条每分钟任务：先跑守卫、再跑自愈。自愈做四件事：① meson-vdec 未加载则 modprobe 并轮询等 `/dev/video0` 出现；② 按 md5（不是文件大小）比对并注入插件、补 `media_codecs.xml`；③ 有变更就重启 `media.codec`，且当 mediaserver 启动早于最近一次注入时重启 mediaserver 刷新 codec 缓存；④ 健康探针写日志 + CMA 守卫 + 引用计数泄漏兜底。全程不碰 `/dev/video26` 与 `/sys/class/vdec/*`。

#### 【B】OMX 硬解插件 —— **技术核心**

- `meson_omx_plugin.cpp`：实现 OMX IL 组件 `OMX.meson.h264.decoder`，被 Android
  MediaCodec/ACodec 通过 HAL 加载。关键点：回答
  `OMX_IndexParamVideoAndroidRequiresSwRenderer=1` 让框架放弃 Surface 走 ByteBuffer；
  内置 4 帧溢出环解耦 App 供缓冲速度；`SendCommand` 走异步线程避免死锁。
- `meson_vdec.h`：封装 V4L2 stateful M2M 流程（S_FMT → REQBUFS → SUBSCRIBE_EVENT →
  STREAMON → drain）。**含本次新增的 `flock` 会话互斥**——驱动只允许一个会话。
- `mctest.c`：从 App 视角（NDK AMediaCodec）验证整条链路是否真的走通硬解。

#### 【C】`_excluded_vdec_src/` —— **GPL 代码，已移出仓库**

原 `vdec_src/`，从 Linux 内核 `drivers/staging/media/meson/vdec/` 复制，
**SPDX: GPL-2.0+，Copyright BayLibre SAS / Maxime Jourdan**。
用途是**读代码理解协议**（动态分辨率事件、缓冲区时序），**不参与编译**。

**决定**：为保持仓库纯 MIT，该目录已重命名为 `_excluded_vdec_src/` 并被
`.gitignore` 排除，**不随仓库分发**。本地留底仅供查阅，可随时删除 ——
项目其余部分**不依赖它的任何一行代码**，删掉照样编译运行。

#### 【D】`tools/`

- `aosp-headers/`：构建期头文件。⚠️ `include/media/` 下 11 个文件全是 14 字节的
  `404: Not Found`（当初下载失败把错误页存成了文件），**是废文件，建议删除**；
  有效的是 `openmax/`、`hardware/`、`utils/`、`log/`。
- `ndk/`：NDK r26d，2.0 GB，**不入库**。

---

## 3. 入口文件与运行方式

### 3.1 GPU 控制台

| 场景 | 入口 | 命令 |
|---|---|---|
| fnOS 内运行（正常） | `gpu-console/cmd/main` | 由 fnOS 调用 `main start/stop/status` |
| 手动调试 | `gpu-console/server/gateway.py` | `python3 gateway.py serve`（前台）<br>`python3 gateway.py start`（后台）<br>`python3 gateway.py status` / `probe` / `healthy` |
| 打包 | `gpu-console/build_fpk.sh` | `bash build_fpk.sh` → `gpuconsole_<ver>.fpk` |
| 安装 | — | `appcenter-cli install-fpk <fpk> -v 1`（同 appname 需先 uninstall） |

**运行依赖**：Python 3（标准库即可）、fnOS ≥ 1.1.8、应用以 `package` 用户运行、
加入 `docker` 组。可选 root 授权（用于宿主层修补）。

### 3.2 OMX 插件

```bash
bash omx-meson/build_omx.sh      # 需 tools/ndk 就位
# → out/libstagefrighthw.so（64 位，参考）
# → out/libstagefrighthw32.so（32 位，★ 实际部署用这个）
```

**运行依赖**：Android NDK r26d（编译期）；部署目标为 32 位 `media.codec` 进程。

### 3.3 验证工具

```bash
bash omx-meson/build_mctest.sh    # 编译 mctest
# 在容器内：mctest <mp4> [帧数] [强制组件名]
```

---

## 4. 环境依赖清单

| 依赖 | 版本/说明 | 必需性 | 是否入库 |
|---|---|---|---|
| Python 3 | 标准库，无 pip 依赖 | 控制台必需 | — |
| Android NDK | r26d | 仅**重新构建** OMX 插件时需要 | ❌ 2GB，自行下载 |
| AOSP 头文件 | 构建期依赖 | 仅重建插件时需要 | ❌ 不在发布范围 |
| fnOS | ≥ 1.1.8（manifest `os_min_version`） | 控制台必需 | — |
| Linux 内核 | 6.18.x + `meson-vdec` 模块 | 硬解必需 | — |
| Amlogic S922X / G12B | 目标硬件 | 硬解必需 | — |
| Docker + redroid 12 | 安卓容器 | 容器功能必需 | — |
| 内核头文件 + gcc + make + dtc | 设备本机 | 可选（编译内核模块） | — |

---

## 5. 最终发布范围（已执行）

### ✅ 纳入仓库

```
LICENSE  NOTICE  README.md  CONTRIBUTING.md  PROJECT_INVENTORY.md  .gitignore
gpu-console/         （含随包分发的 libstagefrighthw32.so；app.tgz 已排除）
release/gpuconsole_1.1.0.fpk
docs/                （17 篇，已脱敏）
```

> ⛔ **不含** OMX 插件源码（其预编译产物随 FPK 分发）、GPL 参考代码 —— 仓库为纯 MIT。

### ❌ 排除（`.gitignore` 已处理，且物理移入 `_excluded_local/`）

```
_excluded_local/                含明文设备密码 / 内网地址 / 本机路径，绝不可公开
  ├─ omx-meson/ cputype/ tools/ androidemu-gpu-adapt/ _cmp/
  ├─ docs_more/                 14 篇含内网拓扑与远程登录细节的报告
  ├─ run_many.py r.py switch_ssh.py omx_autodeploy.sh guard_autodeploy.sh
  └─ 394 个一次性调试脚本与截图
.workbuddy/                     会话记忆（含设备凭据）
**/app.tgz                      打包中间产物
```

### ✅ 已拍板并执行的决定

1. **`vdec_src/` 不入库** —— 已移至 `_excluded_local/_excluded_vdec_src/` 并排除。
   仓库为**纯 MIT**，无 GPL 传染风险。
2. **33 篇技术报告** → 17 篇入 `docs/`（已脱敏），14 篇因含个人信息移出，
   3 篇纯过程记录同时移出。
3. **版权署名**：`Copyright (c) 2026 laowang`（LICENSE、NOTICE 与源文件 SPDX 头）。
4. **发布范围收窄**（用户 2026-10-04 指示）：只发布 GPU 控制台代码 + FPK +
   部分测试数据；一切 SSH / 个人信息相关内容已删除或移出。
5. **个人信息清理**：manifest 与页面页脚中的昵称已统一为 `laowang`；
   个人主页链接（B 站空间）已移除；FPK 已按清理后的源码**重新打包**并校验。
