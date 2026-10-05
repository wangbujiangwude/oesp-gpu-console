#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。

# -*- coding: utf-8 -*-
"""
GPU 控制台 · 飞牛 fnOS 统一网关服务

架构说明（fnOS 原生应用的关键机制）：
  · 应用【不监听 TCP 端口】，而是监听一个 Unix Socket（$TRIM_APPDEST/app.sock）
  · 飞牛的 Web 网关（nginx）把 /app/<appname>/* 的请求转发到这个 socket
  · 因此我们只需在这个 socket 上说标准 HTTP/1.1 即可
  · 依赖仅 python3 标准库，无需 flask / pip 安装

用法：gateway.py {serve|start|stop|restart|status|supervise|probe}

采集的数据全部来自只读安全路径（/proc、/sys/class/devfreq、/sys/class/thermal），
⛔ 绝不读取 /sys/class/vdec/*（整机死锁），绝不 open /dev/video26（整机死锁）。
"""

import os
import sys
import json
import time
import socket
import signal
import shutil
import threading
import subprocess

try:
    import fcntl          # 自愈加锁，防止并发拉起多个守护
except Exception:
    fcntl = None

VERSION = "1.3.1"
APP_NAME = "gpuconsole"

APP_DEST = os.environ.get("TRIM_APPDEST", "/var/apps/gpuconsole/target")
VAR_DIR = os.environ.get("TRIM_PKGVAR", "/var/apps/gpuconsole/var")
SOCK_PATH = os.path.join(APP_DEST, "app.sock")
PID_FILE = os.path.join(VAR_DIR, "gateway.pid")
CHILD_PID = os.path.join(VAR_DIR, "gateway.child.pid")
LOCK_FILE = os.path.join(VAR_DIR, "gateway.lock")
LOG_FILE = os.path.join(VAR_DIR, "gateway.log")
PREFIX = os.environ.get("TRIM_GW_PREFIX", "/app/gpuconsole")

GPU_DEVFREQ = "/sys/class/devfreq/ffe40000.gpu"
HISTORY_MAX = 300          # 保留 300 个采样点（2 秒一次 ≈ 10 分钟）
SAMPLE_INTERVAL = 2.0

_lock = threading.Lock()
_history = []              # [{t, job_rate, vdec_rate, freq, cma_free, ...}]
_last_irq = {}
_last_ts = 0.0


# --------------------------------------------------------------------------- 工具
def log(msg):
    try:
        os.makedirs(VAR_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def pyexe():
    """找到可用的 python 解释器。
    实测教训：fnOS 应用运行环境里 sys.executable 可能为空字符串，
    直接拿它去 Popen 会报 `PermissionError: [Errno 13] Permission denied: ''`，
    导致网关永远起不来（应用显示 running 但 socket 不存在）。必须逐个回退探测。
    """
    cands = [sys.executable, shutil.which("python3"), shutil.which("python"),
             "/usr/bin/python3", "/usr/local/bin/python3", "/usr/bin/python"]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return "python3"


def read_file(path, default=""):
    """安全读文件，任何异常都返回默认值，绝不抛"""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except Exception:
        return default


def sh(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout)
        return (r.stdout or b"").decode("utf-8", "replace").strip()
    except Exception:
        return ""


def irq_count(name):
    """读中断累计计数。⛔ 只读 /proc/interrupts，安全"""
    for line in read_file("/proc/interrupts").splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        if parts[-1] == name and parts[0].rstrip(":").isdigit():
            s = 0
            for c in parts[1:-1]:
                try:
                    s += int(c)
                except ValueError:
                    pass
            return s
    return 0


# --------------------------------------------------------------------------- 采集
def meminfo():
    d = {}
    for line in read_file("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        d[k.strip()] = v.strip().split()[0] if v.strip() else ""
    return d


def gpu_freq():
    cur = read_file(GPU_DEVFREQ + "/cur_freq", "0")
    try:
        cur = int(cur)
    except ValueError:
        cur = 0
    try:
        mn = int(read_file(GPU_DEVFREQ + "/min_freq", "0"))
    except ValueError:
        mn = 0
    try:
        mx = int(read_file(GPU_DEVFREQ + "/max_freq", "0"))
    except ValueError:
        mx = 0
    return {
        "cur_mhz": round(cur / 1e6, 1),
        "min_mhz": round(mn / 1e6, 1),
        "max_mhz": round(mx / 1e6, 1),
        "governor": read_file(GPU_DEVFREQ + "/governor", "-"),
        "freq_percent": round((cur - mn) * 100.0 / (mx - mn), 1) if mx > mn else 0.0,
    }


def thermal():
    """温度：本机只有 cpu-thermal / ddr-thermal，没有 GPU 温区（已知限制）"""
    out = []
    base = "/sys/class/thermal"
    try:
        for z in sorted(os.listdir(base)):
            if not z.startswith("thermal_zone"):
                continue
            t = read_file(os.path.join(base, z, "temp"), "")
            ty = read_file(os.path.join(base, z, "type"), z)
            try:
                out.append({"zone": z, "type": ty, "celsius": round(int(t) / 1000.0, 1)})
            except ValueError:
                pass
    except Exception:
        pass
    return out


def modules():
    """⛔ 不要用 lsmod：它常驻 /usr/sbin，而应用用户的 PATH 未必包含，
       命令不存在时字符串匹配必然为假 → 页面会显示"硬解模块未加载"的假警报。
       /proc/modules 是内核直接提供的，零依赖。
    """
    loaded = read_file("/proc/modules")
    def has(name):
        return any(ln.split()[0] == name for ln in loaded.splitlines() if ln.strip())
    return {
        "panfrost": has("panfrost") or os.path.isdir("/sys/bus/platform/drivers/panfrost"),
        "meson_vdec": has("meson_vdec"),
        "mali_kbase": has("mali_kbase"),
    }


def devices():
    r = {}
    for name, path in (
        ("vdec_video0", "/dev/video0"),
        ("dri_renderD128", "/dev/dri/renderD128"),
        ("dri_card0", "/dev/dri/card0"),
        ("dma_heap", "/dev/dma_heap/system"),
    ):
        r[name] = os.path.exists(path)
    r["video0_name"] = read_file("/sys/class/video4linux/video0/name", "-") if r["vdec_video0"] else "-"
    return r


# --------------------------------------------------------- GPU 客户端（按进程归因）
# 内核 6.x 的 DRM fdinfo 会为每个 GPU client 报告驱动名、当前频率与显存占用，
# 读法：ls -l /proc/<pid>/fd 找到指向 /dev/dri/* 的 fd，再 cat /proc/<pid>/fdinfo/<fd>。
# 这比"中断增长率"强在能按进程归因 —— 直接回答"谁在占 GPU"。
# ⛔ 全程只读 /proc，不碰 /sys/class/vdec 与 /dev/video26。
_gpuc_cache = {"ts": 0.0, "data": []}
# v1.3.1：该面板在前端默认折叠，多数时候没人看，采集放慢到 6 秒一次
# （走 sudo 通道时每次要 spawn 一个进程），展开后仍是秒级可见的近实时数据。
GPUC_TTL = 6.0


def _cgroup_of(pid):
    """从 cgroup 里提取容器 id 片段（docker-<id12> 或 libpod-<id>），宿主进程返回 ''"""
    try:
        txt = read_file("/proc/%s/cgroup" % pid, "")
    except Exception:
        return ""
    for ln in txt.splitlines():
        tail = ln.split("::")[-1] if "::" in ln else ln
        for key in ("docker-", "libpod-", "crio-", "lxc/"):
            i = tail.find(key)
            if i >= 0:
                seg = tail[i + len(key):]
                seg = seg.rstrip("/").replace(".scope", "")
                return seg[:12]
    return ""


_docker_names = {"ts": 0.0, "map": {}}


def docker_names():
    """容器 id 前 12 位 -> 容器名。拿不到 docker 就返回空表（前端退回显示短 id）"""
    now = time.time()
    if _docker_names["map"] and (now - _docker_names["ts"]) < 60:
        return _docker_names["map"]
    m = {}
    try:
        out = sh("docker ps --format '{{.ID}}|{{.Names}}' 2>/dev/null", 6)
        for ln in (out or "").splitlines():
            if "|" in ln:
                i, _, n = ln.partition("|")
                if i.strip():
                    m[i.strip()[:12]] = n.strip()
    except Exception:
        pass
    _docker_names["ts"] = now
    _docker_names["map"] = m
    return m


def _scan_local():
    """本地直读 /proc。应用以普通用户运行时，别的用户的 /proc/<pid>/fd 会
       Permission denied —— 那时列表为空，由 gpu_clients 退回 sudo 通道。"""

    seen = {}          # (pid, client-id) -> 记录，避免同一 client 的多个 fd 重复计数
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except Exception:
        pids = []

    for pid in pids:
        fdd = "/proc/%s/fd" % pid
        try:
            fds = os.listdir(fdd)
        except Exception:
            continue
        for fd in fds:
            try:
                link = os.readlink(os.path.join(fdd, fd))
            except Exception:
                continue
            if "/dev/dri/" not in link:
                continue
            info = {}
            try:
                for ln in read_file("/proc/%s/fdinfo/%s" % (pid, fd), "").splitlines():
                    if ln.startswith("drm-"):
                        k, _, v = ln.partition(":")
                        info[k.strip()] = v.strip()
            except Exception:
                continue
            if not info.get("drm-driver"):
                continue          # 驱动没实现 fdinfo，跳过

            def kb(key):
                try:
                    return int(info.get(key, "0").split()[0])
                except (ValueError, IndexError):
                    return 0

            def mhz(key):
                try:
                    return int(round(int(info.get(key, "0").split()[0]) / 1000000.0))
                except (ValueError, IndexError):
                    return 0

            cid = info.get("drm-client-id", fd)
            k = (pid, cid)
            if k in seen:
                continue
            try:
                comm = read_file("/proc/%s/comm" % pid, "?").strip()
            except Exception:
                comm = "?"
            cgrp = _cgroup_of(pid)
            seen[k] = {
                "ctr": docker_names().get(cgrp, ""),
                "pid": int(pid),
                "comm": comm,
                "dev": link.rsplit("/", 1)[-1],
                "driver": info.get("drm-driver", "?"),
                "cid": cid,
                "res_mb": kb("drm-resident-memory") // 1024,
                "shared_mb": kb("drm-shared-memory") // 1024,
                "total_mb": kb("drm-total-memory") // 1024,
                "cur_mhz": mhz("drm-curfreq-fragment") or mhz("drm-curfreq-vertex-tiler"),
                "max_mhz": mhz("drm-maxfreq-fragment") or mhz("drm-maxfreq-vertex-tiler"),
                "cgroup": cgrp,
            }

    return sorted(seen.values(), key=lambda x: -x["res_mb"])[:12]


def gpu_clients(force=False):
    """GPU 客户端列表（按常驻显存降序）。
       两级：① 本地直读 /proc（root 时可用）② 退回已放行的修补脚本
       `sudo -n ... --gpu-clients`（该脚本由 root 固化，sudoers 只放行它本身）。
    """
    now = time.time()
    # ⚠ 判据必须是【上次采集时间】而不是 "data 非空"：
    # 没有任何 GPU 客户端时结果为空列表，若按 data 判断则缓存永不生效，
    # 变成每 2 秒 spawn 一次 sudo 进程（白烧 CPU）。空结果也要缓存。
    if not force and _gpuc_cache["ts"] and (now - _gpuc_cache["ts"]) < GPUC_TTL:
        return _gpuc_cache["data"]

    out = []
    src = "local"
    try:
        out = _scan_local()
    except Exception:
        out = []

    if not out:
        fx = fix_script()
        if os.path.isfile(fx):
            try:
                r = _run(["sudo", "-n", fx, "--gpu-clients"], 25)
                txt = (r.stdout or b"").decode("utf-8", "replace").strip()
                if txt.startswith("["):
                    out = json.loads(txt)
                    src = "sudo"
                    for c in out:
                        c["ctr"] = docker_names().get(c.get("cgroup", ""), "")
            except Exception as e:
                log("gpu_clients sudo 通道失败: %s" % e)

    if src == "local":
        for c in out:
            c.setdefault("ctr", docker_names().get(c.get("cgroup", ""), ""))

    _gpuc_cache["ts"] = now
    _gpuc_cache["data"] = out
    return out


_ctr_cache = {"ts": 0.0, "data": None, "err": False}
CTR_TTL = 10.0    # 容器列表变化不频繁；docker exec 探测比 2 秒采样慢，做缓存


def containers(force=False):
    """哪些容器在用 GPU。判据分两层：
      ① 普通容器 —— docker inspect 的 HostConfig.Devices 里能看到 /dev/dri|renderD128|video0；
      ② 特权容器 —— devices 段通常只剩 /dev/binder（设备靠 privileged 全量放行），
         只看 inspect 会误报"未见 GPU 设备"，必须进容器实测节点才准。
    应用以普通用户运行时可能读不到 docker socket —— 返回 None 让前端给出提示，
    而不是静默显示"没有容器"造成误解。
    """
    now = time.time()
    if not force and _ctr_cache["data"] is not None and now - _ctr_cache["ts"] < CTR_TTL:
        return _ctr_cache["data"]
    probe = sh("docker ps --format '{{.Names}}' 2>&1")
    if "permission denied" in probe.lower() or "cannot connect" in probe.lower():
        _ctr_cache.update(ts=now, data=None)
        return None
    out = []
    for n in probe.split()[:20]:
        devs = sh("docker inspect %s --format '{{json .HostConfig.Devices}}' 2>/dev/null" % n)
        priv = sh("docker inspect %s --format '{{.HostConfig.Privileged}}' 2>/dev/null" % n)
        is_priv = (priv == "true")
        use_gpu = ("video0" in devs) or ("renderD128" in devs) or ("dri" in devs)
        how = "devices" if use_gpu else ""
        if not use_gpu and is_priv:
            seen = sh("docker exec %s ls /dev/dri/renderD128 /dev/video0 2>/dev/null" % n)
            if "/dev/dri" in seen or "/dev/video0" in seen:
                use_gpu, how = True, "privileged"
        if use_gpu or is_priv:
            # 渲染器属性只有安卓类容器有（mesa=硬件 / angle=软渲染）。非安卓容器没有 getprop，
            # docker 会把 "OCI runtime exec failed..." 整段报错塞回来 —— 只接受干净的单 token，
            # 否则前端会把这串错误当成渲染器名显示出来。
            renderer = ""
            if use_gpu:
                r = sh("docker exec %s getprop ro.hardware.egl 2>/dev/null" % n)
                if r and len(r) <= 32 and all(ch.isalnum() or ch in "_.-" for ch in r):
                    renderer = r
            out.append({
                "name": n,
                "gpu": use_gpu,
                "how": how,                 # devices=显式直通 / privileged=特权全放行
                "renderer": renderer,       # 仅安卓容器有值
                "privileged": is_priv,
                "risk": is_priv,            # privileged 容器能看到雷区 /dev/video26
            })
    _ctr_cache.update(ts=now, data=out)
    return out


# --------------------------------------------------------------------------- 安卓容器
CTR = os.environ.get("GPU_FIX_CONTAINER", "androidemu-android")
# grant_root.sh 会把修补脚本固化到 root 拥有的目录，sudoers 只授权【那一份】。
# 优先用它：既保证是最新版被授权的副本，也避免直接授权应用目录里（777）可篡改的脚本。
FIX_SH_SECURE = "/usr/local/lib/oesp-gpu/oesp_gpu_fix.sh"


def fix_script():
    return FIX_SH_SECURE if os.path.isfile(FIX_SH_SECURE) \
        else os.path.join(APP_DEST, "scripts", "oesp_gpu_fix.sh")


FIX_SH = fix_script()
# 授权命令要给出一条用户复制过去必定能跑的路径：运行时目录是权威位置，
# 安装源目录（APP_DEST 有时指向 /vol1/@appcenter/...）作为兜底。
_GRANT_RT = "/var/apps/gpuconsole/target/scripts/grant_root.sh"
GRANT_SH = _GRANT_RT if os.path.isfile(_GRANT_RT) \
    else os.path.join(APP_DEST, "scripts", "grant_root.sh")

_android_cache = {"ts": 0.0, "data": None}
ANDROID_TTL = 20.0          # 容器探测要跑 docker exec，比 2 秒采样慢，做缓存


def android_info(force=False):
    """安卓容器 GPU 状态。只读，⛔ 不碰 /dev/video26 与 /sys/class/vdec/*"""
    now = time.time()
    if not force and _android_cache["data"] and now - _android_cache["ts"] < ANDROID_TTL:
        return _android_cache["data"]

    up = False
    names = sh("docker ps --format '{{.Names}}' 2>/dev/null").split()
    up = CTR in names
    d = {"name": CTR, "up": up, "gpu_mode": "", "gpu_node": "",
         "renderer": "", "renderer_hw": False, "omx_plugin": False,
         "omx_md5": "", "codecs_meson": 0, "video0_perm": "",
         "privileged": False, "error": ""}
    if not up:
        d["error"] = "容器未运行"
        _android_cache.update(ts=now, data=d)
        return d

    d["gpu_mode"] = sh("docker exec %s getprop ro.boot.redroid_gpu_mode 2>/dev/null" % CTR)
    d["gpu_node"] = sh("docker exec %s getprop ro.boot.redroid_gpu_node 2>/dev/null" % CTR)
    if not d["gpu_node"]:
        # 多数 redroid 镜像没设 redroid_gpu_node，直接报容器内真实存在的节点更实在
        nodes = [x for x in sh("docker exec %s ls /dev/dri 2>/dev/null" % CTR).split()
                 if x in ("renderD128", "card0", "card1")]
        if nodes:
            d["gpu_node"] = "、".join("/dev/dri/" + x for x in nodes[:2])
    # 整行再截断：早期只匹配到 "ANGLE (Google" 会漏掉后面的 SwiftShader，造成假阴性
    rend = sh("docker exec %s timeout 8 dumpsys SurfaceFlinger 2>/dev/null | grep -m1 'GLES:'" % CTR, timeout=12)
    d["renderer"] = rend[:140]
    r = rend.lower()
    d["renderer_hw"] = bool(rend) and not any(k in r for k in
                                              ("swiftshader", "llvmpipe", "softpipe"))
    md5 = sh("docker exec %s md5sum /vendor/lib/libstagefrighthw.so 2>/dev/null" % CTR).split()
    d["omx_md5"] = md5[0] if md5 else ""
    src = sh("md5sum /root/vdec/omx/libstagefrighthw32.so 2>/dev/null").split()
    if not src:
        src = sh("md5sum %s/scripts/libstagefrighthw32.so 2>/dev/null" % APP_DEST).split()
    d["omx_plugin"] = bool(d["omx_md5"]) and bool(src) and d["omx_md5"] == src[0]
    try:
        d["codecs_meson"] = int(sh("docker exec %s grep -c OMX.meson /vendor/etc/media_codecs.xml 2>/dev/null"
                                   % CTR).strip() or 0)
    except ValueError:
        d["codecs_meson"] = 0
    d["video0_perm"] = sh("docker exec %s stat -c %%a /dev/video0 2>/dev/null" % CTR)
    d["privileged"] = (sh("docker inspect %s --format '{{.HostConfig.Privileged}}' 2>/dev/null" % CTR)
                       == "true")
    _android_cache.update(ts=now, data=d)
    return d


# --------------------------------------------------------------------------- 体检 / 修补
_repair = {"running": False, "level": "", "log": "", "rc": None, "started": 0.0,
           "finished": 0.0}


def can_root():
    """当前进程能否以 root 执行【修补脚本】。

    ⚠ 不能只测 `sudo -n true`：sudoers 里只放行了特定脚本，`sudo -n true` 必然失败，
      那样会误判成"无 root"而永久禁用按钮。必须针对目标脚本探测（sudo -l <cmd>）。
    """
    try:
        if os.geteuid() == 0:
            return True
    except Exception:
        pass
    try:
        tgt = fix_script()
        r = subprocess.run(["sudo", "-n", "-l", tgt], capture_output=True, timeout=8)
        out = (r.stdout or b"").decode("utf-8", "replace")
        return r.returncode == 0 and tgt in out
    except Exception:
        return False


def _run(cmd, timeout):
    """带 root 执行，失败自动降级为普通执行。

    ⚠ 必须以【脚本本身】作为 sudo 的命令，不能写成 `sudo bash <script>`：
       sudoers 放行的是脚本路径，写成 bash 时 sudo 比较的是 argv[0]="bash"，
       匹配不上就会提示 "a password is required"（实测踩过）。
       脚本自带 shebang 且已 755，可直接执行。
    """
    if os.geteuid() != 0 and can_root():
        try:
            r = subprocess.run(["sudo", "-n"] + cmd, capture_output=True, timeout=timeout)
            if (r.stdout or b"").strip():
                return r
            log("sudo 执行无输出(rc=%s)，降级为普通执行: %s"
                % (r.returncode, (r.stderr or b"").decode("utf-8", "replace")[:200]))
        except Exception as e:
            log("sudo 执行异常，降级: %s" % e)
    return subprocess.run(cmd, capture_output=True, timeout=timeout)


def run_detect():
    """调修补脚本做只读体检"""
    sh_ = fix_script()
    if not os.path.isfile(sh_):
        return {"error": "修补脚本缺失: %s" % sh_}
    try:
        r = _run([sh_, "--detect"], 150)
        out = (r.stdout or b"").decode("utf-8", "replace")
    except Exception as e:
        return {"error": "检测失败: %s" % e}
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception:
        return {"error": "检测输出解析失败", "raw": out[:500]}


def do_repair(level):
    """后台执行修补。level: container | host | rebuild"""
    args = ["--fix"]
    if level in ("host", "rebuild"):
        args.append("--host")
    if level == "rebuild":
        args.append("--rebuild")
    sh_ = fix_script()
    cmd = [sh_] + args
    if os.geteuid() != 0 and can_root():
        cmd = ["sudo", "-n", sh_] + args
    _repair.update(running=True, level=level, log="", rc=None,
                   started=time.time(), finished=0.0)
    # ⚠ 2026-10-04 修复：原实现是 `p.wait()` 无超时 + 阻塞式 readline，
    #   一旦修补脚本挂起（已知：容器内 `cmd gpu vkjson` 会挂起、docker compose up 可能卡住），
    #   running 永远为 True → 前端按钮永久禁用且无法取消，只能重启应用。
    #   这里改为「读输出线程 + 限时等待 + 超时杀进程组」。
    TIMEOUT = {"container": 90, "host": 180, "rebuild": 420}.get(level, 120)
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True)
        buf = []

        def _reader():
            try:
                for line in iter(p.stdout.readline, b""):
                    s = line.decode("utf-8", "replace").rstrip()
                    buf.append(s)
                    _repair["log"] = "\n".join(buf)
                    if len(buf) > 400:
                        del buf[0: len(buf) - 400]
            except Exception:
                pass

        t = threading.Thread(target=_reader)
        t.daemon = True
        t.start()
        try:
            p.wait(timeout=TIMEOUT)
            _repair["rc"] = p.returncode
        except Exception:
            # 超时：杀掉整个进程组，避免留下挂起的子进程占着锁
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass
            try:
                p.wait(timeout=10)
            except Exception:
                pass
            _repair["rc"] = -9
            _repair["log"] += ("\n[超时] 修补超过 %d 秒被强制终止。"
                               "常见原因：容器内 cmd gpu vkjson 挂起、docker compose 卡住。"
                               "可重试；若持续超时请到 SSH 里手动执行排查。" % TIMEOUT)
    except Exception as e:
        _repair["log"] += "\n[异常] %s" % e
        _repair["rc"] = -1
    _repair["running"] = False
    _repair["finished"] = time.time()
    log("修补(%s) 完成 rc=%s" % (level, _repair["rc"]))
    # 修补后立刻刷新容器状态缓存
    try:
        android_info(force=True)
    except Exception:
        pass


def collect():
    """采集一帧快照"""
    now = time.time()
    irq = {
        "panfrost-job": irq_count("panfrost-job"),
        "panfrost-mmu": irq_count("panfrost-mmu"),
        "panfrost-gpu": irq_count("panfrost-gpu"),
        "vdec": irq_count("vdec"),
    }
    mi = meminfo()

    global _last_irq, _last_ts
    rate = {"job": 0.0, "vdec": 0.0}
    if _last_irq and now > _last_ts:
        dt = now - _last_ts
        rate["job"] = round((irq["panfrost-job"] - _last_irq.get("panfrost-job", irq["panfrost-job"])) / dt, 2)
        rate["vdec"] = round((irq["vdec"] - _last_irq.get("vdec", irq["vdec"])) / dt, 2)
    _last_irq = irq
    _last_ts = now

    try:
        cma_free = int(mi.get("CmaFree", "0")) // 1024
        cma_total = int(mi.get("CmaTotal", "0")) // 1024
    except ValueError:
        cma_free = cma_total = 0

    ctrs = containers()
    snap = {
        "ts": now,
        "time": time.strftime("%H:%M:%S"),
        "irq": irq,
        "rate": rate,
        "gpu": gpu_freq(),
        "thermal": thermal(),
        "modules": modules(),
        "devices": devices(),
        "containers": ctrs or [],
        "docker_error": (ctrs is None),
        "cma": {"free_mb": cma_free, "total_mb": cma_total,
                "used_percent": round((cma_total - cma_free) * 100.0 / cma_total, 1) if cma_total else 0},
        "loadavg": read_file("/proc/loadavg", "-").split()[0:3],
        "uptime_s": int(float(read_file("/proc/uptime", "0").split()[0] or 0)),
        "sched_timeout": int(sh("dmesg 2>/dev/null | grep -c 'gpu sched timeout'") or 0),
        "gpu_clients": gpu_clients(),
        "android": android_info(),
        "decoder": decoder_info(),
        "can_root": can_root(),
        "euid": (os.geteuid() if hasattr(os, "geteuid") else -1),
    }
    return snap


def sampler_loop():
    """后台采样线程"""
    while True:
        try:
            s = collect()
            with _lock:
                _history.append(s)
                if len(_history) > HISTORY_MAX:
                    del _history[0: len(_history) - HISTORY_MAX]
        except Exception as e:
            log("采样异常: %s" % e)
        time.sleep(SAMPLE_INTERVAL)


# --------------------------------------------------------------------------- HTTP
def api_status():
    s = collect()
    return json.dumps(s, ensure_ascii=False).encode("utf-8")


# --------------------------------------------------------------- 解码器软/硬解
# 2026-10-04：实测硬解在真实播放器里是负收益（1.4 核 vs 软解 0.87 核），
# 因此把选择权交给用户。切换动作走已放行的修补脚本（--decoder soft|hard），
# 不需要用户重新做 sudo 授权。
_dec_cache = {"ts": 0.0, "data": {}}


def decoder_info(force=False):
    now = time.time()
    if not force and _dec_cache["data"] and (now - _dec_cache["ts"]) < 20:
        return _dec_cache["data"]
    sh_ = fix_script()
    if not os.path.isfile(sh_):
        return {"mode": "unknown", "error": "修补脚本缺失"}
    try:
        r = _run([sh_, "--decoder", "status"], 25)
        out = (r.stdout or b"").decode("utf-8", "replace").strip().splitlines()[-1]
        d = json.loads(out)
    except Exception as e:
        d = {"mode": "unknown", "error": str(e)[:120]}
    _dec_cache["ts"] = now
    _dec_cache["data"] = d
    return d


def decoder_switch(mode):
    sh_ = fix_script()
    if not os.path.isfile(sh_):
        return {"ok": False, "msg": "修补脚本缺失"}
    try:
        r = _run([sh_, "--decoder", mode], 90)
        out = (r.stdout or b"").decode("utf-8", "replace").strip().splitlines()[-1]
        d = json.loads(out)
    except Exception as e:
        return {"ok": False, "msg": "切换失败: %s" % str(e)[:200]}
    _dec_cache["ts"] = 0.0      # 让下次 status 立即重查
    return d


def api_history():
    with _lock:
        pts = [{
            "t": h["time"], "job": h["rate"]["job"], "vdec": h["rate"]["vdec"],
            "freq": h["gpu"]["cur_mhz"], "cma": h["cma"]["free_mb"],
        } for h in _history]
    return json.dumps({"points": pts}, ensure_ascii=False).encode("utf-8")


def send(conn, code, ctype, body):
    if isinstance(body, str):
        body = body.encode("utf-8")
    conn.sendall(
        ("HTTP/1.1 %s\r\nContent-Type: %s\r\nAccess-Control-Allow-Origin: *\r\n"
         "Cache-Control: no-store\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
         % (code, ctype, len(body))).encode("utf-8") + body
    )


def handle_request(conn):
    try:
        f = conn.makefile("rb")
        raw = f.readline()
        if not raw:
            conn.close()
            return
        # 读剩余头部（本应用不关心，但必须读掉以免连接错乱）
        while True:
            line = f.readline()
            if not line or line in (b"\r\n", b"\n"):
                break
        parts = raw.split()
        method = parts[0] if len(parts) > 0 else b"GET"
        target = parts[1].decode("latin1") if len(parts) > 1 else "/"

        path = target
        if path.startswith(PREFIX):
            path = path[len(PREFIX):] or "/"
        bare = path.split("?")[0]
        if not bare.startswith("/"):
            bare = "/" + bare

        if method == b"OPTIONS":
            conn.sendall(b"HTTP/1.1 204 No Content\r\n"
                         b"Access-Control-Allow-Origin: *\r\n"
                         b"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                         b"Access-Control-Allow-Headers: Authorization, Content-Type\r\n"
                         b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            conn.close()
            return

        if bare in ("/", "/index.html"):
            send(conn, "200 OK", "text/html; charset=utf-8", PAGE)
        elif bare == "/api/status":
            send(conn, "200 OK", "application/json; charset=utf-8", api_status())
        elif bare == "/api/history":
            send(conn, "200 OK", "application/json; charset=utf-8", api_history())
        elif bare == "/api/version":
            send(conn, "200 OK", "application/json; charset=utf-8",
                 json.dumps({"version": VERSION, "app": APP_NAME}).encode())
        elif bare == "/api/detect":
            t0 = time.time()
            d = run_detect()
            d["elapsed"] = round(time.time() - t0, 1)
            d["can_root"] = can_root()
            d["fix_script"] = fix_script()
            d["grant_cmd"] = "sudo bash %s" % GRANT_SH
            d["granted"] = os.path.isfile(FIX_SH_SECURE)
            send(conn, "200 OK", "application/json; charset=utf-8",
                 json.dumps(d, ensure_ascii=False).encode("utf-8"))
        elif bare == "/api/repair":
            # 用 query 带参数（前端按钮直接 GET，省掉 POST body 的麻烦）
            level = "container"
            if "level=host" in target:
                level = "host"
            elif "level=rebuild" in target:
                level = "rebuild"
            if _repair["running"]:
                send(conn, "200 OK", "application/json; charset=utf-8",
                     json.dumps({"started": False, "reason": "已有修补任务在跑"}).encode())
            else:
                threading.Thread(target=do_repair, args=(level,), daemon=True).start()
                send(conn, "200 OK", "application/json; charset=utf-8",
                     json.dumps({"started": True, "level": level}).encode())
        elif bare == "/api/repair_log":
            send(conn, "200 OK", "application/json; charset=utf-8",
                 json.dumps(_repair, ensure_ascii=False).encode("utf-8"))
        elif bare == "/api/decoder":
            mode = None
            if "mode=soft" in target:
                mode = "soft"
            elif "mode=hard" in target:
                mode = "hard"
            d = decoder_switch(mode) if mode else decoder_info(force=True)
            send(conn, "200 OK", "application/json; charset=utf-8",
                 json.dumps(d, ensure_ascii=False).encode("utf-8"))
        elif bare == "/api/android":
            send(conn, "200 OK", "application/json; charset=utf-8",
                 json.dumps(android_info(force=True), ensure_ascii=False).encode("utf-8"))
        else:
            send(conn, "404 Not Found", "text/plain; charset=utf-8", "404 Not Found")
    except Exception as e:
        log("请求处理异常: %s" % e)
        try:
            send(conn, "500 Internal Server Error", "text/plain; charset=utf-8", "500")
        except Exception:
            pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def bind_listen():
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    srv.listen(64)
    os.chmod(SOCK_PATH, 0o666)
    return srv


def serve():
    os.makedirs(VAR_DIR, exist_ok=True)
    srv = bind_listen()
    with open(CHILD_PID, "w") as fp:
        fp.write(str(os.getpid()))
    threading.Thread(target=sampler_loop, daemon=True).start()
    log("已监听 %s（前缀 %s）版本 %s" % (SOCK_PATH, PREFIX, VERSION))
    while True:
        try:
            conn, _ = srv.accept()
        except Exception:
            continue
        threading.Thread(target=handle_request, args=(conn,), daemon=True).start()


def supervise():
    """守护：代理挂了自动拉起"""
    while True:
        try:
            r = subprocess.run([pyexe(), os.path.abspath(__file__), "serve"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            log("serve 退出 code=%s，2 秒后重启" % r.returncode)
        except Exception as e:
            log("supervise 异常: %s" % e)
        time.sleep(2)


def pid_alive(pidfile, must_have=None):
    """校验 PID 文件指向的进程【确实是本网关】。

    ⚠ 实测教训（v1.0.3 修复的核心 bug）：
      旧版只做 os.kill(pid, 0) 判断进程存活。设备重启后 PID 文件残留在持久目录，
      一旦新系统有无关进程复用了这个 PID，就会误判"已在运行"而拒绝启动 ——
      表现为：应用中心显示 running，但 app.sock 不存在，页面打不开。
    因此必须再读 /proc/<pid>/cmdline，确认它是本 gateway.py 且角色匹配。
    """
    try:
        with open(pidfile) as f:
            pid = int(f.read().strip())
    except Exception:
        return 0
    if pid <= 0:
        return 0
    try:
        os.kill(pid, 0)
    except Exception:
        return 0
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except Exception:
        return 0
    if "gateway.py" not in cmd:
        return 0                       # PID 被别的进程复用了 → 视为无效
    if must_have and must_have not in cmd:
        return 0                       # 角色不对（supervise / serve）
    return pid


def healthy():
    """守护在 + 服务在 + socket 在，三者缺一即不健康"""
    return (pid_alive(PID_FILE, "supervise") > 0
            and pid_alive(CHILD_PID, "serve") > 0
            and os.path.exists(SOCK_PATH))


class _Lock(object):
    """跨进程文件锁，避免应用中心高频轮询 status 时并发拉起多个守护"""

    def __init__(self):
        self.fp = None

    def __enter__(self):
        try:
            os.makedirs(VAR_DIR, exist_ok=True)
            self.fp = open(LOCK_FILE, "w")
            if fcntl:
                fcntl.flock(self.fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:
            self.fp = None
        return self

    def __exit__(self, *a):
        try:
            if self.fp:
                if fcntl:
                    fcntl.flock(self.fp.fileno(), fcntl.LOCK_UN)
                self.fp.close()
        except Exception:
            pass
        return False


def start(wait=15.0):
    os.makedirs(VAR_DIR, exist_ok=True)
    if healthy():
        print("已在运行 守护=%d 服务=%d" % (pid_alive(PID_FILE, "supervise"),
                                            pid_alive(CHILD_PID, "serve")))
        return 0
    # 清理陈旧状态（断电重启后 PID 文件必然残留）
    for pf in (PID_FILE, CHILD_PID):
        try:
            os.unlink(pf)
        except OSError:
            pass
    p = subprocess.Popen([pyexe(), os.path.abspath(__file__), "supervise"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    with open(PID_FILE, "w") as f:
        f.write(str(p.pid))
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(0.3)
        if os.path.exists(SOCK_PATH) and pid_alive(CHILD_PID, "serve"):
            print("已启动 守护=%d 服务=%d socket=%s" % (
                p.pid, pid_alive(CHILD_PID, "serve"), SOCK_PATH))
            return 0
    print("已发出启动命令（socket 尚未就绪）")
    return 1


def stop():
    # 先杀服务进程，再杀守护 —— 反了的话守护会临死前再拉起一个 serve
    for pf, sig in ((CHILD_PID, signal.SIGTERM), (PID_FILE, signal.SIGTERM)):
        try:
            with open(pf) as f:
                os.kill(int(f.read().strip()), sig)
        except Exception:
            pass
    time.sleep(0.5)
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    for pf in (PID_FILE, CHILD_PID):
        try:
            os.unlink(pf)
        except OSError:
            pass
    print("已停止")


def status():
    """⚠ 本函数是 fnOS 应用中心每 30 秒轮询一次的入口。

    实测教训（v1.0.3）：设备重启后，飞牛的 hastart 探测看到残留的陈旧 app.sock
    文件就认为服务已启动，此后【只轮询 status，再也不调 start】；而陈旧 socket
    随即被清掉，于是应用永远停在"显示 running / 实际没进程 / 页面打不开"的状态。
    因此这里必须自带自愈：发现不健康就立刻拉起。这样最坏情况 30 秒内自动恢复。
    """
    sup = pid_alive(PID_FILE, "supervise")
    child = pid_alive(CHILD_PID, "serve")
    sock = os.path.exists(SOCK_PATH)
    print("守护: %s" % ("running(%d)" % sup if sup else "not running"))
    print("服务: %s" % ("running(%d)" % child if child else "not running"))
    print("socket: %s" % ("OK" if sock else "missing"))
    print("版本: %s" % VERSION)
    if not (sup and child and sock):
        print("── 检测到未运行，触发自愈 ──")
        with _Lock():
            if healthy():               # 持锁后二次确认，避免重复拉起
                print("  （并发期间已被拉起）")
                return 0
            log("status 自愈：守护=%s 服务=%s socket=%s → 重新拉起"
                % (sup or "无", child or "无", "有" if sock else "无"))
            return start()
    return 0


# --------------------------------------------------------------------------- 前端页面
# ⚠ 必须是【原始字符串 r"""】：页面 JS 里含有 \n、\?、\s 等转义。
# 若用普通字符串，Python 会把 \n 变成真换行塞进 JS 字符串字面量，
# 浏览器解析时直接 SyntaxError，整个主脚本不执行 —— 表现就是页面永远停在"加载中"。
# （v1.0.4 就是这个原因：新增的 repair() 里第一次出现了 \n）
PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GPU 控制台</title>
<style>
  :root{
    --bg:#0f1419; --panel:#171d24; --panel2:#1e252e; --line:#2a333d;
    --txt:#e6edf3; --dim:#8b98a5; --green:#3fb950; --yellow:#d29922;
    --red:#f85149; --blue:#58a6ff; --purple:#bc8cff;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--txt);font:14px/1.5 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif;padding:16px}
  h1{font-size:18px;font-weight:600;margin-bottom:4px}
  .sub{color:var(--dim);font-size:12px;margin-bottom:16px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px;margin-bottom:16px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px}
  .card h2{font-size:12px;color:var(--dim);font-weight:500;margin-bottom:10px;letter-spacing:.5px}
  .big{font-size:26px;font-weight:600;line-height:1.2}
  .unit{font-size:12px;color:var(--dim);margin-left:3px}
  .bar{height:6px;background:var(--panel2);border-radius:3px;overflow:hidden;margin-top:8px}
  .bar>i{display:block;height:100%;background:var(--green);border-radius:3px;transition:width .4s}
  table{width:100%;border-collapse:collapse;font-size:13px}
  td{padding:5px 0;border-bottom:1px solid var(--line)}
  td:last-child{text-align:right;color:var(--dim)}
  .tag{display:inline-block;padding:1px 7px;border-radius:9px;font-size:11px;margin-left:6px}
  .t-ok{background:rgba(63,185,80,.15);color:var(--green)}
  .t-warn{background:rgba(210,153,34,.15);color:var(--yellow)}
  .t-bad{background:rgba(248,81,73,.15);color:var(--red)}
  .t-info{background:rgba(88,166,255,.15);color:var(--blue)}
  canvas{width:100%;height:150px;display:block;margin-top:6px}
  .legend{font-size:11px;color:var(--dim);margin-top:6px}
  .legend span{margin-right:12px}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px;vertical-align:middle}
  .warnbox{background:rgba(248,81,73,.08);border:1px solid rgba(248,81,73,.3);border-radius:8px;padding:10px 12px;font-size:12px;color:#ffb4ae;margin-top:12px}
  .foot{color:var(--dim);font-size:11px;margin-top:16px;text-align:center}
  .btn{background:var(--panel2);border:1px solid var(--line);color:var(--txt);padding:6px 12px;
       border-radius:6px;cursor:pointer;font-size:12px;font-family:inherit}
  .btn:hover:not(:disabled){border-color:var(--blue);color:var(--blue)}
  .btn:disabled{opacity:.45;cursor:not-allowed}
  .btn-warn{border-color:rgba(210,153,34,.45)}
  .btn-danger{border-color:rgba(248,81,73,.45)}
  .btn-go{border-color:rgba(63,185,80,.45);color:var(--green)}
  .acts{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
  pre#fixlog{background:#0b0f14;border:1px solid var(--line);border-radius:6px;padding:10px;
             font:11px/1.55 ui-monospace,Consolas,monospace;max-height:280px;overflow:auto;
             white-space:pre-wrap;word-break:break-all;color:#a9b6c4;margin-top:12px}
  .notice{background:rgba(88,166,255,.08);border:1px solid rgba(88,166,255,.3);border-radius:8px;
          padding:10px 12px;font-size:12px;color:#9ecbff;margin-top:10px}
  .notice code{background:rgba(255,255,255,.07);padding:1px 5px;border-radius:4px;color:#cfe6ff}
  .rowflex{display:flex;align-items:center;gap:14px;margin-bottom:10px}
  .lv{display:inline-block;width:6px;height:6px;border-radius:50%;margin-right:6px;vertical-align:middle}
  .iss td{padding:6px 0;vertical-align:top}
  .iss td:last-child{text-align:right;white-space:nowrap}
  /* 可折叠次要面板：默认收起，只占一行，不挤占主控制台版面 */
  .fold{background:var(--panel);border:1px solid var(--line);border-radius:10px;margin-bottom:12px}
  .fold>summary{cursor:pointer;padding:10px 14px;font-size:12px;color:var(--dim);
                letter-spacing:.5px;display:flex;align-items:center;gap:8px;
                list-style:none;user-select:none}
  .fold>summary::-webkit-details-marker{display:none}
  .fold>summary:hover{color:var(--txt)}
  .fold>summary::before{content:'\25B8';display:inline-block;transition:transform .18s;
                        font-size:11px;color:var(--dim)}
  .fold[open]>summary::before{transform:rotate(90deg)}
  .fold>summary:focus{outline:none}
  .foldbrief{margin-left:auto;font-size:11px;color:var(--blue);letter-spacing:0}
  .foldbody{padding:10px 14px 12px;border-top:1px solid var(--line)}
</style>
</head>
<body>
<h1>GPU 控制台</h1>
<div class="sub" id="sub">加载中…</div>
<script>
/* ① 存在性标记：只要这一句被执行，页面就会显示"正在请求数据…"。
   如果一直停在"加载中…"，说明浏览器根本没执行本页脚本（而不是接口有问题）。*/
window.__GW_JS = 1;
(function(){ var s = document.getElementById('sub'); if (s) s.textContent = '正在请求数据…'; })();
window.__errs = [];
window.addEventListener('error', function(e){
  window.__errs.push((e.message || '?') + ' @line ' + (e.lineno || '?'));
});
window.addEventListener('unhandledrejection', function(e){
  window.__errs.push('Promise: ' + ((e.reason && e.reason.message) || e.reason));
});
</script>
<div class="warnbox" id="errbox" style="display:none"></div>
<div class="foot" id="diag" style="text-align:left;margin-top:6px;display:none"></div>
<noscript><div class="warnbox" style="display:block">⚠️ 浏览器没有执行本页脚本（JavaScript 被禁用或被安全策略拦截），所以一直停在“加载中”。请允许本应用页面执行脚本后重新打开。</div></noscript>

<div class="grid">
  <div class="card">
    <h2>3D GPU 负载（job 中断/秒）</h2>
    <div class="big" id="jobrate">–<span class="unit">/s</span></div>
    <div class="bar"><i id="jobbar" style="width:0%"></i></div>
    <div style="font-size:11px;color:var(--dim);margin-top:6px">空闲约 0.26/s ｜ 连续滑动可达 20/s</div>
  </div>
  <div class="card">
    <h2>VDEC 硬解负载（中断/秒）</h2>
    <div class="big" id="vdecrate">–<span class="unit">/s</span></div>
    <div class="bar"><i id="vdecbar" style="width:0%"></i></div>
    <div style="font-size:11px;color:var(--dim);margin-top:6px">500 帧硬解约产生 454 次中断</div>
  </div>
  <div class="card">
    <h2>GPU 频率</h2>
    <div class="big" id="freq">–<span class="unit">MHz</span></div>
    <div class="bar"><i id="freqbar" style="width:0%"></i></div>
    <div style="font-size:11px;color:var(--dim);margin-top:6px" id="freqrange">–</div>
  </div>
  <div class="card">
    <h2>CMA 连续内存</h2>
    <div class="big" id="cma">–<span class="unit">MB 空闲</span></div>
    <div class="bar"><i id="cmabar" style="width:0%"></i></div>
    <div style="font-size:11px;color:var(--dim);margin-top:6px" id="cmarange">–</div>
  </div>
</div>

<div class="grid">
  <div class="card">
    <h2>趋势（最近 10 分钟，2 秒采样）</h2>
    <canvas id="chart" width="600" height="150"></canvas>
    <div class="legend">
      <span><i class="dot" style="background:#58a6ff"></i>job/s</span>
      <span><i class="dot" style="background:#3fb950"></i>vdec/s</span>
      <span><i class="dot" style="background:#bc8cff"></i>频率 MHz</span>
    </div>
  </div>
  <div class="card">
    <h2>硬件状态</h2>
    <table id="tbl"></table>
  </div>
</div>

<details class="fold" id="gpucFold">
  <summary>GPU 客户端（按进程归因）<span class="foldbrief" id="gpucBrief">读取中…</span></summary>
  <div class="foldbody">
    <table id="gpuc"></table>
    <div style="font-size:11px;color:var(--dim);margin-top:8px" id="gpucsub">读取中…</div>
  </div>
</details>

<div class="card" style="margin-bottom:16px">
  <h2>硬件体检与一键修补</h2>
  <div class="rowflex">
    <div class="big" id="score">–<span class="unit">分</span></div>
    <div style="flex:1">
      <div class="bar"><i id="scorebar" style="width:0%"></i></div>
      <div style="font-size:11px;color:var(--dim);margin-top:5px" id="scoresub">尚未检测</div>
    </div>
    <button class="btn" id="btnDetect">重新检测</button>
  </div>
  <div class="notice" id="nopriv" style="display:none"></div>
  <table class="iss" id="issues"></table>
  <div class="acts">
    <button class="btn btn-go"   id="btnFixC">① 修补容器层（无需 root）</button>
    <button class="btn btn-warn" id="btnFixH">② 修补宿主层（需 root）</button>
    <button class="btn btn-danger" id="btnFixR">③ 切 GPU 硬件直通（重建容器）</button>
  </div>
  <pre id="fixlog" style="display:none"></pre>
</div>

<div class="card" style="margin-bottom:16px">
  <h2>安卓容器 GPU 详情</h2>
  <table id="ctr2"></table>
</div>

<div class="card" style="margin-bottom:16px">
  <h2>安卓视频解码方式（软解 / 硬解）</h2>
  <div class="rowflex">
    <div style="flex:1">
      <div id="decNow" style="font-size:13px;margin-bottom:6px">读取中…</div>
      <div style="font-size:11px;color:var(--dim);line-height:1.6">
        本机实测（同一 720p 素材、同一播放器）：<b>硬解约 1.4 核</b>（OMX.meson → VDEC）
        vs <b>软解约 0.87 核</b>（OMX.google）。因为容器 gralloc 让 Surface 零拷贝走不通，
        硬解省下的算力被帧搬运和软件上屏吃光还倒挂 —— <b>当前硬解是负收益</b>。<br>
        播放发热 / 卡顿 / CPU 高时切软解；需要低功能耗且能接受较高 CPU 时切回硬解。
      </div>
    </div>
    <button class="btn" id="btnDecSoft">切软解（省 CPU）</button>
    <button class="btn" id="btnDecHard">切硬解（VDEC）</button>
  </div>
  <div class="notice" id="decMsg" style="display:none"></div>
</div>

<div class="card" style="margin-bottom:16px">
  <h2>容器 GPU 使用</h2>
  <table id="ctrs"></table>
</div>

<div class="warnbox" id="warnbox" style="display:none"></div>

<div class="warnbox" style="display:block;margin-top:12px">⚠️ <b>致命雷区警告</b>：本机的 <b>/dev/video26</b> 与 <b>/sys/class/vdec</b> 一旦被任何程序访问（哪怕只是 cat 读取），会立即造成整机内核死锁，只能物理断电恢复。本控制台仅做只读采集，已全程规避这两个路径；也请务必不要用其它工具或脚本去触碰它们。</div>

<div class="foot">GPU 控制台 v1.3.1 · 默认只读监控，仅在你点击修补/切换按钮时才改配置 · 开发者与发布者：老汪不讲武德</div>

<script>
const $ = id => document.getElementById(id);
let maxJob = 25, maxVdec = 120;
let firstDetect = true;
let loading = false;

/* ────────────────────────────────────────────────────────────────────────────
   ★ 网关鉴权：每个 API 请求都必须带上页面自身的查询串（含 token）

   【v1.0.4 读不到数据 / 永远"加载中"的根因】
     fnOS 桌面打开应用时，iframe 地址形如 /app/gpuconsole/?token=<一次性票据>；
     nginx 把 /app/ 全部交给 trim_http_cgi，它对每一个请求都校验 token，
     校验失败时返回的是纯文本 "invalid token"（不是 JSON）。
     而 fetch('api/status') 这种【相对路径】在 URL 解析时只继承"路径"，
     ★ 查询串会被整段丢弃 → API 请求变成无票据 → 网关拒绝 → 页面拿不到数据。

   修法三层：
     ① 所有请求都用 apiUrl() 拼装，把 ?token= 原样带上；
     ② 请求加 AbortController 超时，绝不无限等（旧版会一直挂在"加载中"）；
     ③ 仍失败时向 /app/token 换一张新票据重试一次；再失败就明确报错而不是空转。
*/
let gwToken = '';
try{ gwToken = new URLSearchParams(location.search).get('token') || ''; }catch(e){ gwToken = ''; }
const QS = location.search || '';
// 网关前缀显式取自当前路径，不依赖相对 URL 解析（更稳，也能兼容 ?token= 之类参数）
let BASE = location.pathname || '/';
if (BASE.charAt(BASE.length - 1) !== '/') BASE = BASE.slice(0, BASE.lastIndexOf('/') + 1);

function apiUrl(p){
  // 页面查询串整段保留（可能含 token / entry-token 等任意网关参数）
  let q = QS.replace(/^\?/, '');
  if (gwToken){
    // 换到新票据后必须以新票据为准，否则旧值仍排在前面，重试依旧被拒
    const parts = q.split('&').filter(s => s && s.indexOf('token=') !== 0);
    parts.unshift('token=' + encodeURIComponent(gwToken));
    q = parts.join('&');
  }
  const sep = (p.indexOf('?') >= 0) ? '&' : '?';    // 路径已带参数（如 ?level=host）时用 & 连接
  return BASE + p + (q ? (sep + q + '&') : sep) + '_=' + Date.now();
}

function diag(txt){
  const d = $('diag');
  if (!d) return;
  d.style.display = 'block';
  d.textContent = '诊断：' + txt;
}

function showErr(msg){
  $('sub').textContent = '获取失败：' + msg;
  if (window.__errs && window.__errs.length) msg += '（脚本错误：' + window.__errs.join('；') + '）';
  $('errbox').style.display = 'block';
  $('errbox').innerHTML = '⚠️ <b>读不到监控数据</b>：' + msg
    + '<br><span style="color:var(--dim)">最常见原因是本页缺少 fnOS 网关票据（例如直接在地址栏输入 URL 打开、'
    + '或票据已过期）。请关闭本窗口后<b>从桌面/应用中心重新打开</b>；'
    + '若刚升级过应用，也可点右边按钮刷新本页。</span> '
    + '<button class="btn" style="margin-left:6px" onclick="location.reload()">重新加载本页</button>';
}

async function gwFetch(p, timeout){
  const ac = new AbortController();
  const tm = setTimeout(function(){ ac.abort(); }, timeout || 12000);
  const url = apiUrl(p), t0 = Date.now();
  try{
    const r = await fetch(url, {signal: ac.signal, credentials: 'same-origin', cache: 'no-store'});
    const txt = await r.text();
    diag(p + ' → ' + r.status + ' · ' + (txt ? txt.length : 0) + ' 字节 · ' + (Date.now() - t0) + ' ms');
    if (!txt || txt.trim().charAt(0) !== '{'){
      if (/invalid token|Unauthorized/i.test(txt || '')) throw new Error('网关票据无效（invalid token）');
      throw new Error('网关返回非 JSON（' + (txt || '空响应').slice(0, 40).replace(/\s+/g, ' ') + '）');
    }
    const j = JSON.parse(txt);
    if (j && j.token) gwToken = j.token;      // 网关若下发新票据，后续请求自动沿用
    return j;
  }catch(e){
    if (e && e.name === 'AbortError') throw new Error('请求超时（' + (timeout || 12000) + 'ms 未返回）');
    throw e;
  } finally { clearTimeout(tm); }
}

async function refreshToken(){
  try{
    const r = await fetch('/app/token', {credentials: 'same-origin', cache: 'no-store'});
    const j = await r.json();
    if (j && j.token){ gwToken = j.token; return true; }
  }catch(e){}
  return false;
}

async function load(){
  if (loading) return;                        // 防止 2 秒轮询叠加
  loading = true;
  try{
    const d = await gwFetch('api/status', 12000);
    render(d);
    if (d && d.decoder){ window.__dec = d.decoder; decRender(); }
    $('errbox').style.display = 'none';
    try{ draw(await gwFetch('api/history', 12000)); }catch(e){}
    // 体检要跑 docker 探测，比状态刷新慢得多，只在首屏做一次，之后手动或修补后触发
    if (firstDetect){ firstDetect = false; detect(); }
    loading = false;
    return;
  }catch(e){
    // 票据过期是最高频原因：换一张新票据后立刻重试一次
    if (await refreshToken()){
      try{
        const d = await gwFetch('api/status', 12000);
        render(d);
        $('errbox').style.display = 'none';
        try{ draw(await gwFetch('api/history', 12000)); }catch(e2){}
        if (firstDetect){ firstDetect = false; detect(); }
        loading = false;
        return;
      }catch(e2){ e = e2; }
    }
    showErr(String((e && e.message) ? e.message : e));
  }
  loading = false;
}

function render(d){
  window.__last = d;                           // 折叠面板展开时可立即补渲染
  $('sub').textContent = '内核 ' + (d.devices.video0_name !== '-' ? 'VDEC 就绪' : 'VDEC 未就绪')
    + ' · 运行 ' + Math.floor(d.uptime_s/3600) + ' 小时 · 更新 ' + d.time;

  const job = d.rate.job, vdec = d.rate.vdec;
  $('jobrate').innerHTML = job.toFixed(2) + '<span class="unit">/s</span>';
  maxJob = Math.max(maxJob, job);
  $('jobbar').style.width = Math.min(100, job / maxJob * 100) + '%';

  $('vdecrate').innerHTML = vdec.toFixed(2) + '<span class="unit">/s</span>';
  maxVdec = Math.max(maxVdec, vdec);
  $('vdecbar').style.width = Math.min(100, vdec / maxVdec * 100) + '%';

  $('freq').innerHTML = d.gpu.cur_mhz + '<span class="unit">MHz</span>';
  $('freqbar').style.width = d.gpu.freq_percent + '%';
  $('freqrange').textContent = '范围 ' + d.gpu.min_mhz + '–' + d.gpu.max_mhz + ' MHz ｜ 策略 ' + d.gpu.governor;

  $('cma').innerHTML = d.cma.free_mb + '<span class="unit">MB 空闲</span>';
  $('cmabar').style.width = d.cma.used_percent + '%';
  $('cmarange').textContent = '总量 ' + d.cma.total_mb + ' MB ｜ 已用 ' + d.cma.used_percent + '%';

  const rows = [
    ['3D 驱动 panfrost', d.modules.panfrost ? '已就位<span class="tag t-ok">OK</span>' : '未加载<span class="tag t-bad">FAIL</span>'],
    ['硬解模块 meson-vdec', d.modules.meson_vdec ? '已加载<span class="tag t-ok">OK</span>' : '未加载<span class="tag t-warn">需 modprobe</span>'],
    ['闭源 mali_kbase', d.modules.mali_kbase ? '已加载<span class="tag t-warn">冲突</span>' : '已屏蔽<span class="tag t-ok">OK</span>'],
    ['/dev/video0 (VDEC)', d.devices.vdec_video0 ? d.devices.video0_name + '<span class="tag t-ok">OK</span>' : '不存在<span class="tag t-bad">FAIL</span>'],
    ['/dev/dri/renderD128', d.devices.dri_renderD128 ? '存在<span class="tag t-ok">OK</span>' : '不存在<span class="tag t-bad">FAIL</span>'],
    ['gpu sched timeout 累计', d.sched_timeout === 0 ? '0<span class="tag t-ok">OK</span>' : d.sched_timeout + '<span class="tag t-bad">异常</span>'],
    ['job 中断累计', d.irq['panfrost-job']],
    ['vdec 中断累计', d.irq.vdec]
  ];
  $('tbl').innerHTML = rows.map(r => '<tr><td>' + r[0] + '</td><td>' + r[1] + '</td></tr>').join('')
    + d.thermal.map(t => '<tr><td>温度 ' + t.type + '</td><td>' + t.celsius + ' °C</td></tr>').join('');

  const cs = d.containers || [];
  const noDocker = (d.docker_error === true);
  $('ctrs').innerHTML = cs.length
    ? cs.map(c => '<tr><td>' + c.name + '</td><td>'
        + (c.privileged ? '<span class="tag t-warn">privileged</span>' : '')
        + (c.gpu
            ? (c.renderer
                ? '<span class="tag t-ok">用 GPU</span>'
                  + '<span class="tag ' + (c.renderer === 'angle' ? 't-warn' : 't-ok') + '">'
                  + c.renderer + (c.renderer === 'angle' ? '（软渲染）' : '') + '</span>'
                : '<span class="tag t-info">可见 GPU 设备</span>')
              + (c.how === 'privileged' ? '<span class="tag t-info">特权放行</span>' : '')
            : '<span class="tag t-info">未见 GPU 设备</span>')
        + '</td></tr>').join('')
    : (noDocker
        ? '<tr><td colspan="2" style="color:var(--dim)">无法读取 Docker（应用以普通用户运行，无 docker socket 权限）。'
          + '如需显示容器 GPU 占用，在应用配置中让运行用户加入 docker 组。</td></tr>'
        : '<tr><td colspan="2" style="color:var(--dim)">当前没有容器在使用 GPU</td></tr>');

  renderGpuClients(d);
  renderAndroid(d);

  const risky = cs.filter(c => c.privileged).map(c => c.name);
  if (risky.length){
    $('warnbox').style.display = 'block';
    $('warnbox').innerHTML = '⚠️ 特权容器 <b>' + risky.join('、') + '</b> 能看到雷区设备 '
      + '<code>/dev/video26</code> 与 <code>/sys/class/vdec/*</code>。'
      + '在容器内访问它们会<b>整机内核级死锁，必须物理断电</b>。'
      + '普通应用建议改用最小权限：<code>--device=/dev/video0 --group-add 44 --group-add 105</code>';
  } else {
    $('warnbox').style.display = 'none';
  }
}

// ---------- GPU 客户端（按进程归因） ----------
// 该面板默认折叠：只占一行标题，不挤占主控制台版面；
// 摘要（客户端数 / 常驻显存合计）始终随 2 秒轮询更新，表格仅在展开时渲染。
function renderGpuClients(d){
  const gc = d.gpu_clients || [];
  const el = $('gpuc'), fold = $('gpucFold');
  if (!el || !fold) return;
  const total = gc.reduce((s, c) => s + c.res_mb, 0);
  const brief = $('gpucBrief');
  if (brief){
    brief.textContent = gc.length
      ? (gc.length + ' 个客户端 · 常驻 ' + total + ' MB')
      : '无进程占用';
    brief.style.color = gc.length ? 'var(--blue)' : 'var(--dim)';
  }
  if (!fold.open) return;                      // 折叠 → 只留摘要
  if (!gc.length){
    el.innerHTML = '<tr><td colspan="3" style="color:var(--dim)">当前没有进程持有 /dev/dri 节点'
      + '（或该驱动未提供 DRM fdinfo）</td></tr>';
    $('gpucsub').textContent = '本页数据来自 /proc/<pid>/fdinfo 的 drm-* 字段，只读采集';
    return;
  }
  el.innerHTML = gc.map(c => {
    const who = c.ctr
      ? '<span class="tag t-info">' + c.ctr + '</span>'
      : (c.cgroup ? '<span class="tag t-info">' + c.cgroup + '</span>' : '');
    return '<tr><td>' + c.comm + ' <span style="color:var(--dim)">#' + c.pid + '</span> ' + who
      + '<div style="font-size:11px;color:var(--dim)">' + c.dev + ' · ' + c.driver
      + ' · client ' + c.cid + '</div></td>'
      + '<td style="white-space:nowrap">' + c.res_mb + ' MB'
      + '<div style="font-size:11px;color:var(--dim)">共享 ' + c.shared_mb + ' MB</div></td>'
      + '<td style="white-space:nowrap">' + c.cur_mhz + ' / ' + c.max_mhz + ' MHz'
      + '<div style="font-size:11px;color:var(--dim)">当前 / 上限</div></td>'
      + '</tr>';
  }).join('');
  $('gpucsub').textContent = '共 ' + gc.length + ' 个 GPU 客户端，常驻显存合计 ' + total
    + ' MB ｜ 数据来自内核 DRM fdinfo，只读采集';
}

// ---------- 安卓容器 GPU 详情 ----------
function renderAndroid(d){
  const a = d.android || {};
  const tag = (ok, yes, no) => ok
    ? '<span class="tag t-ok">' + yes + '</span>'
    : '<span class="tag ' + (ok === false ? 't-bad' : 't-warn') + '">' + no + '</span>';
  if (!a.up){
    $('ctr2').innerHTML = '<tr><td colspan="2" style="color:var(--dim)">安卓容器 '
      + (a.name || 'androidemu-android') + ' 未运行（' + (a.error || '-') + '）</td></tr>';
    return;
  }
  const hw = a.renderer_hw;
  const rows = [
    ['容器 GPU 模式', (a.gpu_mode || '未设置') + (a.gpu_mode === 'host'
        ? tag(true, '硬件直通') : tag(false, '软件渲染'))],
    ['渲染节点', a.gpu_node || '—'],
    ['实际渲染器', '<span style="font-size:11px">' + (a.renderer || '未知')
        + '</span>' + (hw ? tag(true, '硬件') : tag(false, 'SwiftShader 软渲染'))],
    ['OMX 硬解插件', a.omx_plugin ? '已注入且最新' + tag(true, 'OK')
        : '容器内与源不一致' + tag(false, '需注入')],
    ['media_codecs 注册', (a.codecs_meson || 0) + ' 处 OMX.meson'
        + (a.codecs_meson ? tag(true, 'OK') : tag(false, 'App 只能软解'))],
    ['容器内 /dev/video0', (a.video0_perm || '未知')
        + (a.video0_perm === '666' ? tag(true, 'OK') : tag(false, '硬解会失效'))],
  ];
  $('ctr2').innerHTML = rows.map(r =>
    '<tr><td>' + r[0] + '</td><td>' + r[1] + '</td></tr>').join('')
    + (a.privileged
       ? '<tr><td colspan="2" style="color:var(--yellow);font-size:11px">'
         + '⚠️ 特权容器：容器内可见雷区 /dev/video26，访问即整机死锁</td></tr>'
       : '');
}

// ---------- 体检 ----------
let lastDetect = null, pollTimer = null;

async function detect(){
  const b = $('btnDetect');
  b.disabled = true; $('scoresub').textContent = '检测中…（需跑若干条 docker 探测，约 3-10 秒）';
  try{
    const d = await gwFetch('api/detect', 60000);
    renderDetect(d);
  }catch(e){
    $('scoresub').textContent = '检测失败: ' + ((e && e.message) ? e.message : e);
  }
  b.disabled = false;
}

function renderDetect(d){
  if (d.error){
    $('scoresub').textContent = '检测失败: ' + d.error;
    $('issues').innerHTML = '';
    return;
  }
  lastDetect = d;
  const s = d.score;
  $('score').innerHTML = s + '<span class="unit">分</span>';
  $('scorebar').style.width = s + '%';
  $('scorebar').style.background = s >= 85 ? 'var(--green)' : (s >= 60 ? 'var(--yellow)' : 'var(--red)');
  $('scoresub').textContent = '正常 ' + d.ok + ' · 警告 ' + d.warn + ' · 故障 ' + d.fail
    + ' · 耗时 ' + d.elapsed + 's' + (d.root ? ' · root 可用' : ' · 无 root');

  const bad = d.checks.filter(c => c.level !== 'ok');
  const col = {fail:'var(--red)', warn:'var(--yellow)'};
  $('issues').innerHTML = bad.length
    ? bad.map(c => '<tr><td><i class="lv" style="background:' + col[c.level] + '"></i>'
        + '<b>' + c.title + '</b><br><span style="color:var(--dim);font-size:11px">'
        + c.detail + '</span></td><td style="font-size:11px;color:var(--dim)">'
        + (c.fix || '—') + (c.need_root ? '<br><span class="tag t-warn">需 root</span>' : '')
        + (c.rebuild ? '<br><span class="tag t-bad">需重建容器</span>' : '') + '</td></tr>').join('')
    : '<tr><td colspan="2" style="color:var(--green)">✓ 全部检测项正常</td></tr>';

  const np = $('nopriv');
  if (!d.can_root){
    np.style.display = 'block';
    np.innerHTML = '当前<b>没有 root 权限</b>，②③ 按钮不可用（① 不需要 root，照常可用）。'
      + '<br>只需在 SSH 里执行<b>一次</b>授权命令，之后就永久可用：'
      + '<div style="margin:8px 0"><code>' + (d.grant_cmd || 'sudo bash /var/apps/gpuconsole/target/scripts/grant_root.sh') + '</code></div>'
      + '<span style="color:var(--dim)">它会把修补脚本复制到 root 拥有的目录再放行（仅这一个脚本），'
      + '不会开放 shell。升级本应用后重跑一次即可同步新版脚本。</span>';
    $('btnFixH').disabled = true; $('btnFixR').disabled = true;
  } else {
    np.style.display = 'none';
    $('btnFixH').disabled = false; $('btnFixR').disabled = false;
  }
}

// ---------- 修补 ----------
async function repair(level){
  if (level === 'rebuild' && !confirm(
      '将修改安卓容器编排并重建容器：\n· 云手机会短暂中断（约 1-2 分钟）\n'
      + '· 重建后 GPU 由 SwiftShader 软渲染切换为硬件直通\n确定继续？')) return;
  ['btnFixC','btnFixH','btnFixR','btnDetect'].forEach(i => $(i).disabled = true);
  const lg = $('fixlog');
  lg.style.display = 'block';
  lg.textContent = '正在执行修补（' + level + '）…\n';
  try{
    const r = await gwFetch('api/repair?level=' + level, 20000);
    if (!r.started){
      lg.textContent += '未启动：' + (r.reason || '未知');
      ['btnFixC','btnFixH','btnFixR','btnDetect'].forEach(i => $(i).disabled = false);
      return;
    }
  }catch(e){
    lg.textContent += '请求失败: ' + ((e && e.message) ? e.message : e);
    ['btnFixC','btnFixH','btnFixR','btnDetect'].forEach(i => $(i).disabled = false);
    return;
  }
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    try{
      const s = await gwFetch('api/repair_log', 15000);
      lg.textContent = s.log || '(等待输出…)';
      lg.scrollTop = lg.scrollHeight;
      if (!s.running){
        clearInterval(pollTimer); pollTimer = null;
        lg.textContent += '\n──── 完成 rc=' + s.rc + ' ────';
        ['btnFixC','btnFixH','btnFixR','btnDetect'].forEach(i => $(i).disabled = false);
        detect();            // 修补后自动复检
      }
    }catch(e){ /* 网络抖动，下一拍再取 */ }
  }, 1000);
}

function draw(h){
  const c = $('chart'), x = c.getContext('2d'), W = c.width, H = c.height;
  x.clearRect(0,0,W,H);
  const pts = h.points || [];
  if (pts.length < 2) return;
  const series = [
    {k:'job',   col:'#58a6ff', max:Math.max(maxJob, 1)},
    {k:'vdec',  col:'#3fb950', max:Math.max(maxVdec, 1)},
    {k:'freq',  col:'#bc8cff', max:800}
  ];
  x.strokeStyle = '#2a333d'; x.lineWidth = 1;
  for (let i=1;i<4;i++){ const y = H*i/4; x.beginPath(); x.moveTo(0,y); x.lineTo(W,y); x.stroke(); }
  series.forEach(s => {
    x.strokeStyle = s.col; x.lineWidth = 2; x.beginPath();
    pts.forEach((p,i) => {
      const px = W * i / (pts.length - 1);
      const py = H - (Math.min(p[s.k], s.max) / s.max) * (H - 10) - 5;
      i ? x.lineTo(px,py) : x.moveTo(px,py);
    });
    x.stroke();
  });
}

/* ---- 解码方式切换 ---- */
function decRender(){
  const d = window.__dec || {};
  const soft = (d.mode === 'soft');
  const col  = soft ? '#3fb950' : '#58a6ff';
  const txt  = soft ? '软解（OMX.google.*，省 CPU）' : '硬解（OMX.meson.h264 → VDEC）';
  $('decNow').innerHTML = '当前：<b style="color:' + col + '">' + txt + '</b>' +
    (d.error ? ' <span style="color:#f85149">(' + d.error + ')</span>' : '') +
    (d.plugin_in_place === 0 && !soft ? ' <span style="color:var(--dim)">（插件未注入）</span>' : '');
}
async function decSet(mode){
  const el = $('decMsg');
  el.style.display = 'block';
  el.textContent = '切换中…（需重启安卓媒体服务，约 10 秒）';
  try{
    const r = await gwFetch('api/decoder?mode=' + mode, 90000);
    el.textContent = (r.msg || ('已切换为 ' + r.mode)) + (r.ok ? '' : '（未完全生效，稍后自愈会再试）');
    window.__dec = await gwFetch('api/decoder', 30000);
    decRender();
  }catch(e){
    el.textContent = '切换失败：' + e;
  }
}

/* 折叠面板：记住用户选择（localStorage）；展开瞬间用最后一份快照补渲染，
   免得要等下一次 2 秒轮询才看到内容 */
(function(){
  const fold = $('gpucFold');
  if (!fold) return;
  try{ if (localStorage.getItem('oesp.gpucFold') === '1') fold.open = true; }catch(e){}
  fold.addEventListener('toggle', function(){
    try{ localStorage.setItem('oesp.gpucFold', fold.open ? '1' : '0'); }catch(e){}
    if (fold.open && window.__last) renderGpuClients(window.__last);
  });
})();

$('btnDetect').onclick = () => detect();
$('btnFixC').onclick   = () => repair('container');
$('btnFixH').onclick   = () => repair('host');
$('btnFixR').onclick   = () => repair('rebuild');
$('btnDecSoft').onclick = () => decSet('soft');
$('btnDecHard').onclick = () => decSet('hard');

load();
setInterval(load, 2000);
// 看门狗：首屏 15 秒还没拿到数据就明确报错，绝不让页面一直停在"加载中"
setTimeout(function(){
  const t = $('sub').textContent || '';
  if (t.indexOf('正在请求') >= 0 || t.indexOf('加载中') >= 0){
    showErr('15 秒仍未取到数据（接口无响应 / 被网关拦截 / 脚本被阻止）');
  }
}, 15000);
</script>
</body>
</html>
"""


# 自检：PAGE 必须是原始字符串。若有人误删了 r 前缀，JS 里的 \n 会变成真换行，
# 浏览器解析时报 SyntaxError、整个主脚本不执行 —— 页面就会永远停在"加载中"。
# 这里启动时直接把它记进日志，避免这个坑再次静默复发。
if "\\n" not in PAGE:
    log("⚠ PAGE 不是原始字符串：JS 里的 \\n 已被 Python 转义，页面会停在加载中！")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "serve":
        serve()
    elif cmd == "start":
        start()
    elif cmd == "stop":
        stop()
    elif cmd == "restart":
        stop(); time.sleep(1); start()
    elif cmd == "status":
        sys.exit(status() or 0)
    elif cmd == "healthy":
        print("healthy" if healthy() else "unhealthy")
        sys.exit(0 if healthy() else 1)
    elif cmd == "supervise":
        supervise()
    elif cmd == "probe":
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(3); s.connect(SOCK_PATH)
            s.sendall(b"GET /api/version HTTP/1.1\r\nHost: x\r\n\r\n")
            print(s.recv(400).decode("utf-8", "replace").splitlines()[0])
        except Exception as e:
            print("probe 失败: %s" % e)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
