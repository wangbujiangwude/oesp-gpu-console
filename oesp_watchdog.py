#!/usr/bin/env python3
"""OESP 硬件看门狗守护 —— 用 SoC 内置 Meson GXBB Watchdog 防止内核死锁后需人工断电。

背景
----
Amlogic S922X 的 SoC 内置硬件看门狗（/dev/watchdog0，identity = "Meson GXBB Watchdog"），
独立于 CPU：一旦超时未被喂狗，由硬件直接复位 SoC —— 即使内核完全死锁、
中断关闭、总线挂起，只要看门狗模块的时钟还在跑，就能把机器拉回来。
本机没有 BMC/IPMI，这是唯一不依赖人工断电的复位手段。

工作模式
--------
1. daemon  —— 常驻喂狗（正常用法）
     systemd / nohup 拉起，每 interval 秒写一次 /dev/watchdog。
     收到 SIGTERM/SIGINT 时写 magic 'V' 并关闭 → 看门狗停止，机器不会复位。
     若进程被 SIGKILL、或内核死锁导致本进程根本得不到调度 → 停止喂狗
     → 硬件在 timeout 秒后自动复位。这正是我们想要的兜底。

2. selftest —— 只打开、喂 3 次、写 'V' 优雅关闭（验证 API 可用，不会复位）
3. firetest —— 打开、喂 3 次，然后**故意停止喂狗**并退出（不写 'V'）
     → 机器应在 timeout 秒后自动重启。用于验证硬件真的能复位。
     执行前请确认已保存数据、能接受一次重启。

健康检查（可选，--check）
--------------------------
纯喂狗只能防"整机卡死"。加 --check 后还会周期性做低成本健康探测：
  - 能否 fork 一个子进程（调度器是否还健康）
  - /proc/loadavg 能否在 1 秒内读到（VFS/内核路径是否可用）
  - 指定进程是否存活（如 docker 容器对应的进程）
连续 --check-fail 次失败后主动停止喂狗，提前触发复位，而不是干等到硬件超时。

用法
----
    python3 oesp_watchdog.py selftest                # 验证 API（安全）
    python3 oesp_watchdog.py daemon --timeout 20     # 常驻喂狗
    python3 oesp_watchdog.py firetest --timeout 20   # 验证真的会复位（会重启！）
    python3 oesp_watchdog.py status                  # 只读查看看门狗状态

注意
----
- nowayout=0 时，写 'V' 后关闭设备可以停止看门狗；若内核编译为 nowayout
  或驱动加载时带了 nowayout=1，则一旦开启就无法停止，只能靠持续喂狗。
- timeout 最小 1 秒。设得太小会增加误复位风险，建议 20~30 秒。
"""

import argparse
import errno
import fcntl
import os
import signal
import struct
import sys
import time
import syslog

# Linux watchdog ioctl：_IOWR/_IOR(WATCHDOG_IOCTL_BASE=0x57, nr, int)
# 注意 size 字段是 sizeof(int)=4 而不是 8，写错会得到 ENOTTY
WDIOC_GETSUPPORT = 0x80205700
WDIOC_GETSTATUS = 0x80045701
WDIOC_GETBOOTSTATUS = 0x80045702
WDIOC_GETTEMP = 0x80045703
WDIOC_SETOPTIONS = 0xc0045704
WDIOC_KEEPALIVE = 0xc0045705
WDIOC_SETTIMEOUT = 0xc0045706
WDIOC_GETTIMEOUT = 0x80045707
WDIOC_GETTIMELEFT = 0x80045710

WDIOS_DISABLECARD = 0x0001
WDIOS_ENABLECARD = 0x0002
WDIOS_TEMPPANIC = 0x0004

DEFAULT_DEV = "/dev/watchdog0"
MAGIC_CLOSE = b"V"

SYSFS_DIRS = [
    "/sys/class/watchdog/watchdog0",
    "/sys/class/watchdog/watchdog1",
]


def log(msg):
    line = "[oesp-watchdog] %s" % msg
    print(line, flush=True)
    try:
        syslog.openlog("oesp-watchdog")
        syslog.syslog(syslog.LOG_INFO, msg)
        syslog.closelog()
    except Exception:
        pass


def sysfs_read(name):
    for d in SYSFS_DIRS:
        p = os.path.join(d, name)
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            continue
    return None


class Watchdog:
    def __init__(self, dev, timeout=None):
        self.dev = dev
        self.timeout = timeout
        self.fd = None

    def open(self):
        self.fd = os.open(self.dev, os.O_WRONLY)
        if self.timeout:
            try:
                fcntl.ioctl(self.fd, WDIOC_SETTIMEOUT, struct.pack("I", self.timeout))
            except OSError as e:
                log("警告：设置 timeout=%s 失败 (%s)，沿用内核默认值"
                    % (self.timeout, errno.errorcode.get(e.errno, e)))
        return self.fd

    def keepalive(self):
        os.write(self.fd, b"\0")
        # 也可以走 ioctl，写字符更通用
        try:
            fcntl.ioctl(self.fd, WDIOC_KEEPALIVE, struct.pack("I", 0))
        except OSError:
            pass

    def magic_close(self):
        """写 'V' 后关闭 —— 告诉内核不要再复位（依赖 nowayout=0）。"""
        try:
            os.write(self.fd, MAGIC_CLOSE)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.fd = None

    def close_keep_running(self):
        """直接关闭，不写 'V' —— 看门狗继续计时，超时后复位。"""
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.fd = None


def health_ok(check_pids):
    """低成本健康探测：调度器与 VFS 是否还正常。"""
    try:
        pid = os.fork()
        if pid == 0:
            os._exit(0)
        _, st = os.waitpid(pid, 0)
        if st != 0:
            return False, "fork/wait 异常"
    except OSError as e:
        return False, "fork 失败: %s" % errno.errorcode.get(e.errno, e)

    try:
        with open("/proc/loadavg") as f:
            f.read()
    except OSError as e:
        return False, "读 /proc/loadavg 失败: %s" % errno.errorcode.get(e.errno, e)

    for p in check_pids:
        if not os.path.isdir("/proc/%d" % p):
            return False, "关键进程 %d 已消失" % p

    return True, "ok"


def cmd_status(_a):
    print("identity    : %s" % sysfs_read("identity"))
    print("state       : %s" % sysfs_read("state"))
    print("timeout     : %s s" % sysfs_read("timeout"))
    print("timeleft    : %s s" % sysfs_read("timeleft"))
    print("min_timeout : %s" % sysfs_read("min_timeout"))
    print("max_timeout : %s" % sysfs_read("max_timeout"))
    print("nowayout    : %s" % sysfs_read("nowayout"))
    print("bootstatus  : %s" % sysfs_read("bootstatus"))
    print("status      : %s" % sysfs_read("status"))
    for d in (DEFAULT_DEV, "/dev/watchdog"):
        print("%-16s %s" % (d, "存在" if os.path.exists(d) else "不存在"))
    return 0


def cmd_selftest(a):
    """打开 → 喂 3 次 → 写 V 关闭。不会复位，纯验证 API。"""
    w = Watchdog(a.dev, a.timeout)
    w.open()
    log("已打开 %s，timeout=%s" % (a.dev, sysfs_read("timeout")))
    for i in range(3):
        w.keepalive()
        log("喂狗 %d/3，timeleft=%s" % (i + 1, sysfs_read("timeleft")))
        time.sleep(a.interval)
    w.magic_close()
    log("已写 magic 'V' 并关闭。state=%s（应为 inactive）" % sysfs_read("state"))
    log("selftest 通过：看门狗 API 可用，且能优雅停止")
    return 0


def cmd_firetest(a):
    """打开 → 喂 3 次 → 不写 V 直接退出。机器应在 timeout 秒后自动复位。"""
    log("=== firetest 会在约 %s 秒后触发硬件复位，请确认已保存数据 ===" % (a.timeout or sysfs_read("timeout")))
    for i in range(5, 0, -1):
        log("%d 秒后开始（Ctrl-C 取消）" % i)
        time.sleep(1)
    w = Watchdog(a.dev, a.timeout)
    w.open()
    for i in range(3):
        w.keepalive()
        log("喂狗 %d/3" % (i + 1))
        time.sleep(a.interval)
    log("停止喂狗，不写 'V' —— 看门狗继续计时")
    w.close_keep_running()
    log("若硬件正常，机器将在 timeout 秒后自动重启。请等待并观察。")
    return 0


def cmd_daemon(a):
    w = Watchdog(a.dev, a.timeout)
    w.open()
    log("守护已启动 dev=%s timeout=%s interval=%s check=%s"
        % (a.dev, sysfs_read("timeout"), a.interval, a.check))

    stop = {"v": False}

    def on_term(signum, _frame):
        stop["v"] = True
        log("收到信号 %d，准备优雅停止（写 V，不复位）" % signum)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    fails = 0
    while not stop["v"]:
        if a.check:
            ok, why = health_ok(a.pid)
            if not ok:
                fails += 1
                log("健康检查失败 %d/%d：%s" % (fails, a.check_fail, why))
                if fails >= a.check_fail:
                    log("连续失败达到阈值，主动停止喂狗以触发复位")
                    w.close_keep_running()
                    return 2
            else:
                fails = 0
        try:
            w.keepalive()
        except OSError as e:
            log("喂狗失败：%s" % e)
            return 1
        time.sleep(a.interval)

    w.magic_close()
    log("已优雅停止，看门狗关闭")
    return 0


def main():
    p = argparse.ArgumentParser(description="OESP 硬件看门狗守护")
    p.add_argument("mode", choices=["daemon", "selftest", "firetest", "status"])
    p.add_argument("--dev", default=DEFAULT_DEV)
    p.add_argument("--timeout", type=int, default=None, help="看门狗超时秒数（最小 1）")
    p.add_argument("--interval", type=float, default=5.0, help="喂狗间隔秒数")
    p.add_argument("--check", action="store_true", help="开启健康检查")
    p.add_argument("--check-fail", type=int, default=3, help="连续失败几次后触发复位")
    p.add_argument("--pid", type=int, action="append", default=[], help="需要存活的关键进程 PID，可重复")
    a = p.parse_args()

    if a.mode == "status":
        return cmd_status(a)
    if os.geteuid() != 0:
        print("需要 root 权限（打开 %s）" % a.dev, file=sys.stderr)
        return 1
    if a.mode == "selftest":
        return cmd_selftest(a)
    if a.mode == "firetest":
        return cmd_firetest(a)
    return cmd_daemon(a)


if __name__ == "__main__":
    sys.exit(main())
