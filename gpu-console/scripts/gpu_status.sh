#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。

# GPU 控制台 —— 命令行状态查询（SSH 直接可用，不依赖 Web）
# 用法：gpu_status.sh [--watch]
# ⛔ 只读安全路径：绝不碰 /sys/class/vdec/* 与 /dev/video26
WATCH=0
[ "${1:-}" = "--watch" ] && WATCH=1

irq() { awk -v n="$1" '$NF==n{s=$2+$3+$4+$5+$6+$7; f=1; exit} END{print (f? s+0 : 0)}' /proc/interrupts; }
D=/sys/class/devfreq/ffe40000.gpu

snap() {
  echo "──────────────────────────────────────────────"
  echo " 时间: $(date '+%F %T')"
  echo " ── 3D GPU (Mali-G52 / panfrost) ──"
  if [ -d "$D" ]; then
    echo "   频率      : $(( $(cat $D/cur_freq 2>/dev/null) / 1000000 )) MHz  (范围 $(( $(cat $D/min_freq 2>/dev/null) / 1000000 ))–$(( $(cat $D/max_freq 2>/dev/null) / 1000000 )) MHz)"
    echo "   调频策略  : $(cat $D/governor 2>/dev/null)"
  else
    echo "   （无 devfreq 节点）"
  fi
  echo "   job 中断  : $(irq panfrost-job)    mmu: $(irq panfrost-mmu)    gpu: $(irq panfrost-gpu)"
  echo " ── 视频硬解 (VDEC / meson-vdec) ──"
  echo "   /dev/video0: $([ -e /dev/video0 ] && cat /sys/class/video4linux/video0/name 2>/dev/null || echo 不存在)"
  echo "   vdec 中断 : $(irq vdec)"
  echo " ── 内存 / 温度 ──"
  grep -E "CmaTotal|CmaFree" /proc/meminfo 2>/dev/null | sed 's/^/   /'
  for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/temp" ] && echo "   $(cat $z/type 2>/dev/null): $(awk '{printf "%.1f", $1/1000}' $z/temp 2>/dev/null) °C"
  done
  echo " ── 驱动模块 ──"
  echo "   panfrost   : $(lsmod | grep -q '^panfrost' && echo 已加载 || { [ -d /sys/bus/platform/drivers/panfrost ] && echo 内核内置 || echo 未加载; })"
  echo "   meson_vdec : $(lsmod | grep -q meson_vdec && echo 已加载 || echo 未加载)"
  echo "   mali_kbase : $(lsmod | grep -q mali_kbase && echo '已加载（与 panfrost 冲突）' || echo 已屏蔽)"
  echo " ── 容器 GPU 占用 ──"
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null | head -10); do
    devs=$(docker inspect "$c" --format '{{json .HostConfig.Devices}}' 2>/dev/null)
    priv=$(docker inspect "$c" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
    mark=""
    echo "$devs" | grep -qE "video0|renderD128|dri" && mark="用 GPU"
    [ "$priv" = "true" ] && mark="$mark ⚠️privileged(可见雷区)"
    [ -n "$mark" ] && echo "   $c : $mark"
  done
}

if [ "$WATCH" = "1" ]; then
  while true; do clear; snap; sleep 2; done
else
  snap
fi
