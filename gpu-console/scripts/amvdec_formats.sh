#!/bin/bash
# ==============================================================================
# 加载 Amlogic 厂商解码栈的格式模块（amvdec_*）
#
# 背景：飞牛官方只加载了框架模块 amvdec_ports，45 个具体格式模块从未加载，
#       导致 HEVC / AV1 / VP9 / AVS2 等硬件解码器空置。这些模块经实测可安全
#       加载（2026-10-05 在 S922X / 内核 6.18.18.c997-trim 上验证，无死锁）。
#
# 安全设计 —— 防启动循环：
#   加载前先写「待办标记」，全部加载成功后才清除。
#   若加载过程中触发内核死锁，硬件看门狗会复位整机；重启后本脚本发现
#   上次标记还在（说明上次没走完），就**跳过本次加载**，避免无限重启循环。
#   标记文件必须落在持久存储（不能用 /run，它是 tmpfs，重启即清空）。
#
# 用法：
#   amvdec_formats.sh            # 加载缺失的模块（幂等）
#   amvdec_formats.sh status     # 只报告状态，不加载
#   amvdec_formats.sh reset      # 清除防循环标记（人工确认安全后重试用）
# ==============================================================================

# ⛔ cron 的 PATH 只有 /usr/bin:/bin，而 modprobe 在 /usr/sbin ——
#    不加这行，脚本手动跑正常、挂 cron 却全部 rc=127（2026-10-05 实测踩到）。
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

STATE_DIR="${AMVDEC_STATE_DIR:-/usr/local/lib/oesp-gpu}"
PENDING="$STATE_DIR/.amvdec_load_pending"

# 解析一次绝对路径，避免 PATH 再次被环境覆盖
MODPROBE="$(command -v modprobe 2>/dev/null || echo /usr/sbin/modprobe)"

# 已实测可安全加载的格式模块（顺序：先保守后激进）
# 注意拼写：MPEG1/2 与 MPEG4 是双 m（mmpeg），写成单 m 会 not found
MODULES="amvdec_mmpeg12 amvdec_h265 amvdec_av1 amvdec_vp9 amvdec_avs2 amvdec_vc1 amvdec_mmjpeg amvdec_mmpeg4"

status() {
    local loaded=0 missing=""
    for m in $MODULES; do
        if lsmod | grep -q "^${m} "; then
            loaded=$((loaded + 1))
        else
            missing="$missing $m"
        fi
    done
    echo "已加载 $loaded / $(echo $MODULES | wc -w)"
    [ -n "$missing" ] && echo "缺失:$missing"
    if [ -f "$PENDING" ]; then
        echo "⚠ 存在未完成的加载标记（上次加载疑似失败）：$(cat "$PENDING")"
    fi
    return 0
}

case "${1:-}" in
    status) status; exit 0 ;;
    reset)  rm -f "$PENDING"; echo "已清除防循环标记"; exit 0 ;;
esac

# ---- 防启动循环检查 ----
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
if [ -f "$PENDING" ]; then
    OLD=$(cat "$PENDING" 2>/dev/null)
    if [ "$OLD" != "$BOOT" ]; then
        echo "跳过：上次加载（boot=$OLD）未完成即重启，怀疑是它触发的。"
        echo "确认安全后可执行：$0 reset  再重试。"
        exit 0
    fi
fi

# ---- 记录要加载哪些（全部已加载则直接退出）----
TODO=""
for m in $MODULES; do
    lsmod | grep -q "^${m} " || TODO="$TODO $m"
done
if [ -z "$TODO" ]; then
    rm -f "$PENDING"
    echo "全部格式模块已就位，无需操作"
    exit 0
fi

# ---- 写标记后逐个加载 ----
mkdir -p "$STATE_DIR" 2>/dev/null
echo "$BOOT" > "$PENDING" 2>/dev/null

for m in $TODO; do
    timeout 20 "$MODPROBE" "$m" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "  $m 加载失败 rc=$rc（后续模块继续尝试）"
    else
        echo "  $m 加载成功"
    fi
    sleep 2
done

# ---- 全部走完，清除标记 ----
rm -f "$PENDING" 2>/dev/null
echo "标记已清除；当前状态：$(status)"
