#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。

# ==============================================================================
#  OESP / Amlogic G12 系列 GPU 一键修复脚本
#  适用：OneThing Cloud OES Plus (S922X)、同类 Amlogic G12A/G12B/S905X3/S922X 盒子
#  功能：屏蔽闭源 Mali → 修复 DTB 中断线 → 启用 meson-vdec 硬解 → 部署工具 → 验收
#
#  用法：
#    bash oesp_gpu_fix.sh            # 检测 + 安全修复（不碰 DTB）
#    bash oesp_gpu_fix.sh --dtb      # 追加执行 DTB 中断线修复（会改 /boot，需重启）
#    bash oesp_gpu_fix.sh --verify   # 只跑验收
#    bash oesp_gpu_fix.sh --report   # 只出体检报告，不改任何东西
#
#  设计原则：
#    · 幂等 —— 反复执行不会弄坏
#    · 破坏性操作前必备份，且默认不做（DTB 需显式 --dtb）
#    · 每步都有 PASS/FAIL/WARN 输出，失败不静默继续
# ==============================================================================
set -uo pipefail

MODE="${1:-fix}"
LOGDIR="/var/log/oesp-gpu"; mkdir -p "$LOGDIR"
LOGF="$LOGDIR/fix-$(date +%Y%m%d-%H%M%S).log"
BAKDIR="/var/backups/oesp-gpu"; mkdir -p "$BAKDIR"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
info() { echo "  [..] $*"; }
sec()  { echo; echo "=== $* ==="; }
log()  { echo "$*" >> "$LOGF"; }

irq() { awk -v n="$1" '$NF==n{s=$2+$3+$4+$5+$6+$7; f=1; exit} END{print (f? s+0 : 0)}' /proc/interrupts; }

[ "$(id -u)" = "0" ] || { echo "请用 root 运行（sudo bash $0）"; exit 1; }

echo "=============================================="
echo " OESP GPU 一键修复  模式: $MODE"
echo " 主机: $(hostname)  内核: $(uname -r)  架构: $(uname -m)"
echo " 日志: $LOGF"
echo "=============================================="

# ==============================================================================
# 阶段 0：体检（只读，绝不修改）
# ==============================================================================
sec "0. 硬件与驱动体检"

ARCH=$(uname -m); [ "$ARCH" = "aarch64" ] && ok "架构 $ARCH" || warn "架构 $ARCH（本脚本面向 aarch64）"

DTB_SOC=$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | tr '\n' ' ')
echo "$DTB_SOC" | grep -qi amlogic && ok "SoC: $DTB_SOC" || warn "SoC 不是 Amlogic: $DTB_SOC"

# 3D GPU
if [ -d /sys/class/devfreq/ffe40000.gpu ] || ls /dev/dri/renderD128 >/dev/null 2>&1; then
  ok "3D GPU 节点存在（/dev/dri/renderD128）"
  echo "      频率: $(cat /sys/class/devfreq/ffe40000.gpu/cur_freq 2>/dev/null) Hz"
else
  bad "未发现 /dev/dri/renderD128 —— panfrost 未加载或 DT 未启用 GPU"
fi

# 注意：panfrost 可能是内核内置(builtin)而非模块，lsmod 里查不到属正常
if lsmod | grep -q "^panfrost" || [ -d /sys/bus/platform/drivers/panfrost ]; then
  ok "panfrost 驱动已就位（模块或内核内置）"
else
  warn "panfrost 未加载"
fi
lsmod | grep -q "mali_kbase" && warn "闭源 mali_kbase 已加载（应与 panfrost 二选一）" || ok "无闭源 mali_kbase 冲突"

# VDEC
if [ -e /dev/video0 ]; then
  ok "VDEC 节点 /dev/video0 存在：$(cat /sys/class/video4linux/video0/name 2>/dev/null)"
else
  warn "无 /dev/video0 —— meson-vdec 模块未加载或内核未编译"
fi
lsmod | grep -q meson_vdec && ok "meson-vdec 模块已加载" || warn "meson-vdec 未加载"

# 中断线健康度
JOB_IRQ=$(irq panfrost-job); GPU_IRQ=$(irq panfrost-gpu)
echo "      panfrost-job=$JOB_IRQ  panfrost-gpu=$GPU_IRQ  vdec=$(irq vdec)"
if [ "$JOB_IRQ" -gt 0 ] 2>/dev/null; then ok "job 中断已触发（$JOB_IRQ）"
else bad "job 中断为 0 —— 中断线大概率接错（需 --dtb 修复）"; fi
if [ "$GPU_IRQ" -gt 1000 ] 2>/dev/null; then warn "panfrost-gpu 中断 $GPU_IRQ（异常，正常应为 0）"; fi

TO=$(dmesg 2>/dev/null | grep -c "gpu sched timeout")
[ "$TO" -eq 0 ] && ok "无 gpu sched timeout" || bad "gpu sched timeout 累计 $TO 次"
dmesg 2>/dev/null | grep -q "Disabling IRQ" && bad "dmesg 有 'Disabling IRQ'（中断被内核禁用）" || ok "中断未被内核禁用"

[ "$MODE" = "--report" ] && { echo; echo "体检完成（未做任何修改）"; exit 0; }

# ==============================================================================
# 阶段 1：屏蔽闭源 Mali（安全，可回退）
# ==============================================================================
if [ "$MODE" = "--verify" ]; then sec "跳过修复阶段（--verify）"; else
sec "1. 屏蔽闭源 mali_kbase（避免与 panfrost 抢 GPU）"
BL=/etc/modprobe.d/blacklist-mali-kbase.conf
if [ -f "$BL" ]; then ok "已存在 $BL"
else
  cat > "$BL" <<'EOF'
# OESP GPU 修复：闭源 mali_kbase 与开源 panfrost 互斥，屏蔽闭源
blacklist mali_kbase
blacklist mali
EOF
  [ -f "$BL" ] && ok "已写入 $BL" || bad "写入失败"
fi
if lsmod | grep -q mali_kbase; then
  warn "mali_kbase 当前已加载；⚠️ 不要在运行时 rmmod（会整机死锁），请重启"
else
  ok "mali_kbase 未加载（或已屏蔽）"
fi
fi

# ==============================================================================
# 阶段 2：DTB 中断线修复（破坏性，需显式 --dtb）
# ==============================================================================
if [ "$MODE" = "--dtb" ]; then
sec "2. DTB 中断线修复（交换 gpu 节点 interrupts 第 1、3 项）"

command -v dtc >/dev/null 2>&1 || { bad "缺少 dtc，请先安装：apt install device-tree-compiler"; }
DTB=$(ls /boot/dtb/amlogic/*.dtb 2>/dev/null | grep -iE "s922x|g12b|oes" | head -1)
if [ -z "$DTB" ]; then
  bad "未找到匹配的 DTB（/boot/dtb/amlogic/*.dtb）"
else
  info "目标 DTB: $DTB"
  BAK="$BAKDIR/$(basename "$DTB").bak.$(date +%Y%m%d-%H%M%S)"
  cp "$DTB" "$BAK" && ok "已备份 → $BAK" || { bad "备份失败，终止"; exit 1; }

  TMP=$(mktemp -d)
  dtc -I dtb -O dts -o "$TMP/a.dts" "$DTB" 2>/dev/null && ok "反编译成功" || { bad "反编译失败"; exit 1; }

  python3 - "$TMP/a.dts" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p,encoding='utf-8',errors='replace').read()
m=re.search(r'gpu@ffe40000\s*\{', s)
if not m:
    print("NOTFOUND"); sys.exit(1)
start=m.end()
# 取该节点块（简单大括号配对）
depth=1; i=start
while i<len(s) and depth>0:
    if s[i]=='{': depth+=1
    elif s[i]=='}': depth-=1
    i+=1
block=s[start:i]
mi=re.search(r'interrupts\s*=\s*<([^>]*)>', block)
if not mi:
    print("NOIRQ"); sys.exit(1)
nums=mi.group(1).split()
print("OLD:"+" ".join(nums))
if len(nums)>=9:
    nums[0],nums[2],nums[6],nums[8]=nums[6],nums[8],nums[0],nums[2]
    nb=block[:mi.start(1)]+" ".join(nums)+block[mi.end(1):]
    open(p,'w',encoding='utf-8').write(s[:start]+nb+s[i:])
    print("NEW:"+" ".join(nums)); print("PATCHED")
else:
    print("SHORT"); sys.exit(1)
PY
  R=$?
  if [ $R -eq 0 ]; then
    dtc -I dts -O dtb -o "$TMP/a.dtb" "$TMP/a.dts" 2>/dev/null && ok "重新编译 DTB 成功" || bad "编译失败"
    if [ -s "$TMP/a.dtb" ]; then
      cp "$TMP/a.dtb" "$DTB" && ok "已安装新 DTB" || bad "安装失败"
      ok "⚠️ 需重启生效：systemctl reboot"
    fi
  else
    bad "DTB 补丁未应用（未找到 gpu@ffe40000 或 interrupts 格式不符），保持原样"
  fi
  rm -rf "$TMP"
fi
fi

# ==============================================================================
# 阶段 3：启用 VDEC 硬解模块
# ==============================================================================
if [ "$MODE" != "--verify" ]; then
sec "3. 启用 meson-vdec 硬解模块"
if lsmod | grep -q meson_vdec; then
  ok "已加载"
else
  if modprobe meson-vdec 2>/dev/null; then
    sleep 2
    [ -e /dev/video0 ] && ok "modprobe 成功，/dev/video0 已出现" || warn "已 modprobe 但无 /dev/video0"
  else
    warn "modprobe meson-vdec 失败 —— 当前内核可能未编译该模块"
    info "  ophub 主线内核默认 CONFIG_VIDEO_MESON_VDEC 未开；可选：①换主线内核 ②自行编译模块"
  fi
fi
# 开机自启
MF=/etc/modules-load.d/meson-vdec.conf
if [ -e /dev/video0 ] && [ ! -f "$MF" ]; then
  echo "meson-vdec" > "$MF" && ok "已设置开机加载 $MF" || warn "写入 $MF 失败"
fi
fi

# ==============================================================================
# 阶段 4：部署解码器与验收器
# ==============================================================================
if [ "$MODE" != "--verify" ]; then
sec "4. 部署解码器 vdec-dec / 验收器 hwdec-verify"
SRC=""
for c in /tmp/vdec_test3.c ./vdec_test3.c /root/vdec/vdec_test3.c; do [ -f "$c" ] && SRC="$c" && break; done
if [ -n "$SRC" ]; then
  command -v gcc >/dev/null 2>&1 || warn "无 gcc，跳过编译"
  if command -v gcc >/dev/null 2>&1; then
    rm -f /usr/local/bin/vdec-dec
    if gcc -O2 -o /usr/local/bin/vdec-dec "$SRC" 2>>"$LOGF"; then ok "编译 vdec-dec 成功"
    else bad "编译失败（详见 $LOGF）"; fi
  fi
else
  warn "未找到 vdec_test3.c，跳过（把它放到 /tmp 或脚本同目录再跑）"
fi
[ -f /usr/local/bin/hwdec-verify ] && ok "hwdec-verify 已存在" || warn "hwdec-verify 未安装（可选：cp hwdec_verify.py /usr/local/bin/hwdec-verify && chmod +x）"
fi

# ==============================================================================
# 阶段 5：容器 GPU 权限（udev）
# ==============================================================================
if [ "$MODE" != "--verify" ]; then
sec "5. 容器 GPU 设备权限"
UDEV=/etc/udev/rules.d/99-oesp-gpu.rules
cat > "$UDEV" <<'EOF'
# 让容器可用 GPU 节点（最小权限方案：docker --device + group_add 44,105）
KERNEL=="video0", MODE="0660", GROUP="video"
KERNEL=="renderD128", MODE="0660", GROUP="render"
KERNEL=="card0", MODE="0660", GROUP="video"
EOF
[ -f "$UDEV" ] && ok "已写入 $UDEV" || bad "写入失败"
command -v udevadm >/dev/null 2>&1 && { udevadm control --reload-rules >/dev/null 2>&1; udevadm trigger >/dev/null 2>&1; ok "已重载 udev 规则"; }
fi

# ==============================================================================
# 阶段 6：验收
# ==============================================================================
sec "6. 验收"
[ -e /dev/video0 ] && ok "/dev/video0 可用" || bad "/dev/video0 不可用"
[ -e /dev/dri/renderD128 ] && ok "/dev/dri/renderD128 可用" || bad "renderD128 不可用"

if [ -x /usr/local/bin/vdec-dec ] && [ -e /dev/video0 ]; then
  T=$(mktemp -d)
  # 生成 120 帧测试码流
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=25:duration=5 \
      -pix_fmt nv12 -c:v libx264 -preset ultrafast -qp 28 -f h264 "$T/in.h264" 2>>"$LOGF"
    if [ -s "$T/in.h264" ]; then
      info "硬解测试（约 125 帧）..."
      OUT=$(PRELUDE_AU=2 TAIL_AU=1 COMPACT=1 timeout 60 /usr/local/bin/vdec-dec /dev/video0 "$T/in.h264" 0 /dev/null 2>&1)
      FRAMES=$(echo "$OUT" | grep -oE '取出帧数: [0-9]+' | grep -oE '[0-9]+' | head -1)
      if [ -n "$FRAMES" ] && [ "$FRAMES" -gt 0 ] 2>/dev/null; then
        ok "硬解成功：取出 $FRAMES 帧"
        echo "$OUT" | grep -E "用时" | sed 's/^/      /'
      else
        bad "硬解无输出"; echo "$OUT" | tail -3 | sed 's/^/      /'
      fi
    else
      warn "ffmpeg 生成测试码流失败，跳过硬解实测"
    fi
  fi
  rm -rf "$T"
fi

# ==============================================================================
echo
echo "=============================================="
echo " 完成：PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
echo "=============================================="
[ "$MODE" = "--dtb" ] && echo " ⚠️ DTB 已修改，请重启：systemctl reboot"
echo " 完整日志：$LOGF"
echo
echo "⛔ 雷区提醒（本脚本已规避，你也别碰）："
echo "   1. /dev/video26      2. /sys/class/vdec/*"
echo "   3. ffmpeg h264_v4l2m2m   4. 运行时 rmmod mali"
exit 0
