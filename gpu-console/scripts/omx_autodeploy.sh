#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。
# ============================================================================
# OMX 插件持久化自愈（幂等，cron 每分钟跑一次）
#
#   1) 把 32 位 libstagefrighthw.so 注入安卓容器 /vendor/lib/
#   2) 保证 /vendor/etc/media_codecs.xml 含 OMX.meson.h264.decoder 条目
#   3) 有变更才重启 media.codec（HAL）
#   4) ★ 关键：mediaserver 会缓存 codec 列表。若它早于插件部署启动，
#      App 侧 MediaCodecList 里就没有 meson 组件（会被软解顶掉），
#      此时必须重启 mediaserver 才能刷新。
#
# 可用环境变量覆盖（不填即用默认值）：
#   OMX_CTR   安卓容器名              默认 androidemu-android
#   OMX_DIR   工作目录（锁/标记/日志） 默认 /root/vdec/omx
#   OMX_SO    插件 .so 路径           按下方顺序自动探测
#   OMX_XML   media_codecs.xml 路径   默认 $OMX_DIR/media_codecs.xml
#   OMX_MCT   验证器 mctest 路径       默认 $OMX_DIR/mctest（不存在则跳过，不报错）
#
# 加固要点（均为防御性，不改变正常行为）：
#   A) 锁文件从 /tmp 挪到持久目录：/tmp 是 1.8G tmpfs，塞满时重定向失败
#      → `|| exit 0` 会让自愈静默消失（最难排查的一类故障）。
#   B) 所有 docker exec/cp 加 timeout：原 `cmd gpu vkjson` 无超时，
#      一旦挂起会占死 flock → 每分钟的自愈【永久停滞】，只能重启恢复。
#   C) modprobe 后由固定 sleep 2 改为轮询等待 /dev/video0 出现（最多 10s）。
#   D) 运行期健康探针只写日志，不做任何修复动作。
#   ⛔ 探针绝不 rmmod / unbind：闭源固件家族，运行时强拆会整机死锁。
#   ⛔ 本脚本永不触碰 /dev/video26 与 /sys/class/vdec/*（访问即内核死锁）。
# ============================================================================
set -u
C="${OMX_CTR:-androidemu-android}"
DIR="${OMX_DIR:-/root/vdec/omx}"
XML="${OMX_XML:-$DIR/media_codecs.xml}"
MCT="${OMX_MCT:-$DIR/mctest}"

mkdir -p "$DIR" 2>/dev/null

# ---- 插件源探测顺序 -------------------------------------------------------
# 1) 环境变量指定  2) 固化目录（修补脚本会放一份在这里）
# 3) 本脚本同目录（随 FPK 分发的那份）  4) 传统位置
SO="${OMX_SO:-}"
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
for cand in "$SO" \
            /usr/local/lib/oesp-gpu/libstagefrighthw32.so \
            "${SELF_DIR:-}/libstagefrighthw32.so" \
            "$DIR/libstagefrighthw32.so"; do
    if [ -n "${cand:-}" ] && [ -s "$cand" ]; then SO="$cand"; break; fi
done

### A) 锁放持久目录
exec 9>"$DIR/.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

### B) 超时包装：所有 docker 子命令限时，避免挂起占死锁
HAVE_T=0; command -v timeout >/dev/null 2>&1 && HAVE_T=1
dex() { if [ "$HAVE_T" = "1" ]; then timeout 20 docker exec "$@"; else docker exec "$@"; fi; }
dcp() { if [ "$HAVE_T" = "1" ]; then timeout 30 docker cp "$@"; else docker cp "$@"; fi; }

if [ "$HAVE_T" = "1" ]; then
    timeout 15 docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${C}$" || exit 0
else
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${C}$" || exit 0
fi

log() { echo "$(date '+%F %T') [omx-autodeploy] $*"; }

NEED_HAL=0

# ---- 0) VDEC 驱动兜底：meson-vdec（开源 staging）不会开机自启，
#      机器重启后 /dev/video0 根本不存在，硬解会静默不可用。
#      只读 /proc/modules 判断（应用内 PATH 无 /usr/sbin，不能用 lsmod）。
if ! grep -q "^meson_vdec" /proc/modules 2>/dev/null; then
    echo "[$(date +%H:%M:%S)] meson-vdec 未加载 -> modprobe"
    modprobe meson-vdec 2>&1 | head -2
    ### C) 轮询等待节点出现（替代固定 sleep 2）
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        [ -e /dev/video0 ] && break
        sleep 1
    done
fi

# 容器重建后 /dev/video0 会回到 660 root:video，media.codec(uid=1046) 打不开 -> 硬解静默失效。
# /dev/video0 在安全白名单内（标准 V4L2 ioctl），chmod 无风险。
if [ -e /dev/video0 ]; then
    PERM=$(stat -c %a /dev/video0 2>/dev/null | tr -dc '0-9')
    if [ "${PERM:-000}" != "666" ]; then
        log "/dev/video0 权限 $PERM -> 666"
        chmod 666 /dev/video0 2>/dev/null
    fi
fi
dex $C chmod 666 /dev/video0 2>/dev/null
dex $C chmod 777 /data/local/tmp 2>/dev/null

# ---- 0b) 预热/收尾参数：容器重建后属性会丢，这里写成编译期默认值 ----
dex $C setprop debug.meson.prelude 2
dex $C setprop debug.meson.drop   1
dex $C setprop debug.meson.tail   1

# ---- 1) 插件本体 ----
# ⚠ 用 md5 而不是文件大小比对：两次编译可能恰好同大小但内容不同
# （曾经就因为按大小判定"一致"而一直跑着旧插件）。
if [ -n "${SO:-}" ] && [ -s "$SO" ]; then
    CUR=$(dex $C md5sum /vendor/lib/libstagefrighthw.so 2>/dev/null | awk '{print $1}')
    NEW=$(md5sum "$SO" 2>/dev/null | awk '{print $1}')
    [ -z "${CUR:-}" ] && CUR=none
    [ -z "${NEW:-}" ] && NEW=none
    if [ "$CUR" != "$NEW" ]; then
        log "插件不一致（容器 ${CUR:0:8} / 源 ${NEW:0:8}），注入"
        dcp "$SO" $C:/vendor/lib/libstagefrighthw.so
        dex $C chmod 644 /vendor/lib/libstagefrighthw.so
        NEED_HAL=1
    fi
else
    log "未找到插件 .so（已探测 /usr/local/lib/oesp-gpu、脚本同目录、$DIR），跳过注入"
fi

# ---- 2) media_codecs.xml 条目 ----
if ! dex $C grep -q "OMX.meson.h264.decoder" /vendor/etc/media_codecs.xml 2>/dev/null; then
    log "xml 缺 meson 条目，补写"
    if [ -f "$XML" ]; then
        dcp "$XML" $C:/vendor/etc/media_codecs.xml
    else
        dcp $DIR/media_codecs.xml.bak $C:/vendor/etc/media_codecs.xml 2>/dev/null || true
    fi
    dex $C chmod 644 /vendor/etc/media_codecs.xml
    NEED_HAL=1
fi

# ---- 3) 验证器常驻（可选，缺了不影响自愈）----
if [ -s "$MCT" ] && ! dex $C test -x /data/local/tmp/mctest 2>/dev/null; then
    dcp "$MCT" $C:/data/local/tmp/mctest
    dex $C chmod 755 /data/local/tmp/mctest 2>/dev/null
fi

# ---- 4) 重启 HAL ----
if [ "$NEED_HAL" = "1" ]; then
    OPID=$(dex $C ps -A 2>/dev/null | grep media.codec | awk '{print $2}' | head -1)
    [ -n "${OPID:-}" ] && dex $C kill -9 "$OPID" 2>/dev/null
    log "已重启 media.codec（旧 PID=$OPID）"
    sleep 4
fi

# ---- 5) mediaserver 缓存刷新（决定 App 能不能看到 meson） ----
#
# ⚠ 不能按「mediaserver 启动时间 < 插件源文件的 mtime」判断：
#   源 .so 的 mtime 是【编译时间】（几小时前），而 mediaserver 是【容器重建后才启动】的，
#   于是条件永远不成立 → 不重启 → mediaserver 缓存里仍是重建那一刻的空壳插件列表，
#   App 侧 MediaCodecList 拿不到 meson，静默回退软解（2026-10-03 重建容器后实测踩到）。
#   正确判据是【本轮有没有重新注入】，有就必须重启 mediaserver。
MPID=$(dex $C getprop init.svc_debug_pid.media 2>/dev/null | tr -dc '0-9')
MSTART=$(dex $C stat -c %Y /proc/$MPID 2>/dev/null | tr -dc '0-9')
[ -z "${MSTART:-}" ] && MSTART=0

# 「最近一次把插件真正写进容器」的时间戳标记文件。
# 标记文件不存在时也写入当前时间 —— 首次运行因此会保守地重启一次，代价可忽略。
MARK=$DIR/.last_inject
if [ "$NEED_HAL" = "1" ] || [ ! -f "$MARK" ]; then
    date +%s > "$MARK"
fi
MARK_TS=$(cat "$MARK" 2>/dev/null | tr -dc '0-9')
[ -z "${MARK_TS:-}" ] && MARK_TS=0

if [ -n "${MPID:-}" ] && [ "$MSTART" -lt "$MARK_TS" ]; then
    log "mediaserver($MPID, 启动于 $MSTART) 早于最近一次插件注入($MARK_TS) -> 重启刷新 codec 列表"
    dex $C kill -9 "$MPID" 2>/dev/null
    sleep 4
    log "mediaserver 新 PID=$(dex $C getprop init.svc_debug_pid.media 2>/dev/null)"
fi

# ---- Vulkan：mesa 的 panvk 在 Mali-G52(Bifrost v7) 上有自保护，默认拒绝加载，
#      结果 cmd gpu vkjson 枚举不到设备、依赖 Vulkan 的 App 直接失败。
#      带 PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1 重启 gpuservice 即可启用
#      （实验性实现，non-conformant，仅供测试）。
# ⚠ 这一段是原脚本最容易挂起的地方：cmd gpu 走 binder 调用 gpuservice，
#   gpuservice 卡住时永不返回 → 占死 flock → 自愈永久停滞。必须单独限时（15s）。
if [ "$HAVE_T" = "1" ]; then
    VKJSON=$(timeout 15 docker exec $C cmd gpu vkjson 2>/dev/null)
else
    VKJSON=$(docker exec $C cmd gpu vkjson 2>/dev/null)
fi
if [ -n "$VKJSON" ] && ! echo "$VKJSON" | grep -q 'Mali-G52'; then
    log "Vulkan 未启用(panvk 自保护) -> 带开关重启 gpuservice"
    # -d 是分离启动，不套 timeout（套了只会杀本机 docker 客户端，无害但无意义）
    docker exec -d $C sh -c 'stop gpu; sleep 1; PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1 /system/bin/gpuservice' >/dev/null 2>&1
fi

# ---- 6) 运行期健康探针（只记录，不做任何修复动作）----
#   vdec_irq —— 播放时应稳定增长（~20~25/s）。长时间为 0 说明硬解没被调用。
#   vdec_ref —— meson_vdec 模块引用计数。正常空闲 0~1。
#   cma_free —— CMA 连续内存空闲量。
# ⛔ 这里【绝不做】rmmod / unbind / 重启驱动：闭源固件家族，运行时强拆会整机死锁。
if [ -e /dev/video0 ]; then
    VDEC_IRQ=$(awk '$NF=="vdec"{s=$2+$3+$4+$5+$6+$7} END{printf "%d", s+0}' /proc/interrupts 2>/dev/null)
    VDEC_REF=$(awk '$1=="meson_vdec"{print $3}' /proc/modules 2>/dev/null)
    CMA_FREE=$(awk '/CmaFree/{print $2}' /proc/meminfo 2>/dev/null | head -1)
    log "health: vdec_irq=${VDEC_IRQ:-na} vdec_ref=${VDEC_REF:-na} cma_free=${CMA_FREE:-na}kB"
fi

# ---- 7) CMA 守卫 + 会话资源泄漏兜底 ----
#
# 【判据】CmaFree 低 ≠ 泄漏：
#   · CMA 共约 1204MB（DT: linux,cma 896MB + linux,codec-mm-cma 308MB）
#   · 硬件侧真实占用极小：panfrost GEM/dma-buf 仅 35.5MB；meson-vdec 会话缓冲用完即还
#   · CmaFree 长期只有 13~130MB，是因为【内核把 CMA 区当 movable 后备池借用】——
#     CMA 位于 zone 末尾，movable 分配从高地址开始，自然优先落进 CMA 区，这是内核设计行为
#   · 决定性证据：echo 3 > /proc/sys/vm/drop_caches 后 CmaFree 13MB -> 134MB
#   · 且 1080p 200 帧硬解在 CmaFree=65MB 时仍 100% 成功 —— cma_alloc 会自动迁移腾空间
# 因此泄漏的唯一可靠指标是【模块引用计数 ref 单调增长】。
#
# 【两级处置】
#   7a) CmaFree < 80MB  -> drop_caches（温和、零副作用，实测可回收 ~120MB）
#   7b) ref >= 6 或 (CmaFree < 40MB 且 ref >= 2) -> 重启 media.codec（init 1~2 秒自动拉起）
# ⛔ 绝不 rmmod / unbind：闭源固件家族，运行时强拆会整机死锁。

gCma() { awk '/CmaFree/{print $2}' /proc/meminfo 2>/dev/null | head -1 | tr -dc '0-9'; }
gRef() { awk '$1=="meson_vdec"{print $3}' /proc/modules 2>/dev/null | tr -dc '0-9'; }

# ---- 7a) CMA 守卫：回收页缓存 ----
if [ -e /dev/video0 ]; then
    F=$(gCma); [ -z "${F:-}" ] && F=999999999
    if [ "$F" -lt 80000 ]; then
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        sleep 2
        F2=$(gCma)
        log "CMA 守卫: cma=${F}kB -> ${F2}kB（drop_caches 回收被 movable 借用的 CMA）"
    fi
fi

# ---- 7b) 泄漏兜底（仅以 ref 为主判据）----
THRESH_REF=6          # 引用计数阈值（约 6 个残留会话）
THRESH_CMA_HARD=40000 # CMA 硬下限（kB，约 40MB）—— 配合 ref>=2 才触发
COOLDOWN=300          # 两次兜底最小间隔（秒）
STAMP=$DIR/.last_hal_restart
if [ -e /dev/video0 ]; then
    R=$(gRef); [ -z "${R:-}" ] && R=0
    F=$(gCma); [ -z "${F:-}" ] && F=999999999
    NOW=$(date +%s)
    LAST=0
    [ -f "$STAMP" ] && LAST=$(cat "$STAMP" 2>/dev/null | tr -dc '0-9')
    [ -z "${LAST:-}" ] && LAST=0
    if { [ "$R" -ge "$THRESH_REF" ] || { [ "$F" -lt "$THRESH_CMA_HARD" ] && [ "$R" -ge 2 ]; }; } \
       && [ $((NOW - LAST)) -gt "$COOLDOWN" ]; then
        HPID=$(dex $C ps -A 2>/dev/null | grep media.codec | awk '{print $2}' | head -1)
        if [ -n "${HPID:-}" ]; then
            log "泄漏兜底: ref=$R cma=${F}kB 触发阈值 -> 重启 media.codec($HPID) 以回收会话资源"
            dex $C kill -9 "$HPID" 2>/dev/null
            date +%s > "$STAMP"
            sleep 4
            log "兜底后: ref=$(gRef) cma=$(gCma)kB"
        fi
    fi
fi
exit 0
