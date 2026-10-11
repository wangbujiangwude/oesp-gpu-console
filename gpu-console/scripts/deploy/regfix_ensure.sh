#!/bin/bash
# regfix_ensure.sh — registers.ko codec-io 死驱动开机自愈（root cron 每分钟，幂等）
# 背景: registers.ko 的 __this_module.init == NULL（module_init 注册被剥）⇒ codec-io
#       平台驱动从未 probe ⇒ 总线 base/codec bus 表全 NULL ⇒ AVE 硬编必总线级硬挂。
#       oesp_regfix.ko mode=1 在运行时补齐（复刻 probe + G12B ops 注册），详见 51 批。
# 幂等: 本 boot 已修复（dmesg 含 "OESP_REGFIX: FIX OK"）直接静默退出；FORCE=1 强制重跑。
# 退出码: 0=已修/等待重试/成功；1=失败（下分钟自动重试）
export PATH=$PATH:/usr/sbin:/sbin
D=/root/vdec/ave/regfix
LOG=$D/ensure.log
L(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# flock 仲裁（防 cron 重入 + 手动并发）
mkdir -p "$D" 2>/dev/null
exec 9>"$D/.lock"
flock -n 9 || exit 0

# ---- 0) 幂等守卫 ----
if [ -z "$FORCE" ] && dmesg 2>/dev/null | grep -q "OESP_REGFIX: FIX OK"; then
    exit 0
fi

# ---- 1) 依赖模块（registers 由 encoder 依赖链拉起；cpuinfo 必须在）----
if ! grep -qw registers /proc/modules; then L "wait: registers.ko not loaded yet"; exit 0; fi
grep -qw amlogic_cpuinfo /proc/modules || modprobe amlogic_cpuinfo >/dev/null 2>&1
if ! grep -qw amlogic_cpuinfo /proc/modules; then L "wait: amlogic_cpuinfo not loaded"; exit 0; fi

# ---- 2) 锚点解析（kptr_restrict 临时置 0，读完立即恢复）----
KP=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null
A_CBUS=$(grep -w codecio_read_cbus       /proc/kallsyms | awk '{print $1}')
A_RST=$( grep -w codecio_reg_start        /proc/kallsyms | awk '{print $1}')
A_SET=$( grep -w set_cpu_type_from_media  /proc/kallsyms | awk '{print $1}')
A_GET=$( grep -w get_cpu_type_from_media  /proc/kallsyms | awk '{print $1}')
[ -n "$KP" ] && echo "$KP" > /proc/sys/kernel/kptr_restrict
if [ -z "$A_CBUS" ] || [ "$A_CBUS" = "0000000000000000" ] || \
   [ -z "$A_RST" ] || [ "$A_RST" = "0000000000000000" ]; then
    L "ERR anchors zero (cbus=$A_CBUS reg_start=$A_RST)"; exit 1
fi
[ -n "$A_SET" ] && [ "$A_SET" != "0000000000000000" ] || { L "ERR a_setcpu missing"; exit 1; }

# ---- 3) ko（缺才构建；正常路径用预构建产物，不依赖编译器）----
cd "$D" || exit 1
if [ ! -f oesp_regfix.ko ]; then
    L "ko missing, building..."
    make >>"$LOG" 2>&1 || { L "ERR build failed"; exit 1; }
fi
[ -f oesp_regfix.ko ] || { L "ERR no ko after build"; exit 1; }

# ---- 4) 应用修复（insmod → 校验输出 → rmmod；模块退出有意不清理）----
rmmod oesp_regfix >/dev/null 2>&1
# 时间戳水位（比行号切片抗 ring-buffer 轮转：日志风暴时旧行被丢弃会让行号切片抓空 → 误报 ERR）
MARK_TS=$(dmesg 2>/dev/null | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p' | tail -1)
[ -n "$MARK_TS" ] || MARK_TS=0
insmod "$D/oesp_regfix.ko" mbase=0x$A_CBUS bss=0x$A_RST \
       a_setcpu=0x$A_SET a_getcpu=0x${A_GET:-0} mode=1
RC=$?
rmmod oesp_regfix >/dev/null 2>&1
if [ "$RC" -ne 0 ]; then L "ERR insmod rc=$RC"; exit 1; fi
# 只取水位之后的 OESP_REGFIX 行（mawk 安全，不用捕获数组）
OUT=$(dmesg 2>/dev/null | awk -v t="$MARK_TS" '
    /^\[/ { s=substr($0,2); sub(/\].*/,"",s); gsub(/[^0-9.]/,"",s);
            if (s+0 > t) print }' | grep "OESP_REGFIX")
[ -n "$OUT" ] || { L "ERR no OESP_REGFIX output captured (ring rotation?) dump last 20:"; \
                   dmesg 2>/dev/null | grep "OESP_REGFIX" | tail -20 >> "$LOG"; }
echo "$OUT" >> "$LOG"
NM=$(echo "$OUT" | grep -c "MATCH")
if echo "$OUT" | grep -q "FIX OK"; then
    L "OK regfix applied (matches=$NM boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id))"
    sync
    exit 0
else
    L "ERR regfix did not report FIX OK (matches=$NM)"; exit 1
fi
