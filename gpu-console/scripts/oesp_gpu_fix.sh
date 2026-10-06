#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。

# ==============================================================================
#  OESP GPU 一键修补脚本  v2.0
#  ---------------------------------------------------------------------------
#  与 v1 的区别：v1 是"照单全修"，v2 是【先检测再精准修补】——
#  控制台调用 --detect 拿到结构化问题清单，用户点哪个修哪个，
#  已经正常的项不会被动到（v1 每次都重写 udev/blacklist，噪音大）。
#
#  用法：
#    oesp_gpu_fix.sh --detect            # 只读体检，输出 JSON（绝不修改任何东西）
#    oesp_gpu_fix.sh --report            # 只读体检，输出人类可读文本
#    oesp_gpu_fix.sh --fix [--host]      # 修补；默认只做「不需要 root / 不中断服务」的项
#    oesp_gpu_fix.sh --fix --host        # 追加需要 root 的宿主项（modprobe/udev/chmod/cron）
#    oesp_gpu_fix.sh --fix --host --rebuild   # 追加「重建安卓容器」切 GPU 直通（会中断云手机）
#
#  设计原则：
#    · 幂等：反复执行不会弄坏
#    · 默认安全：需要 root 的、会中断服务的，都必须显式开关
#    · 雷区硬隔离：本脚本永不 open /dev/video26、永不读 /sys/class/vdec/*
#    · 每步有 PASS/FAIL/WARN，失败不静默继续
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
CTR="${GPU_FIX_CONTAINER:-androidemu-android}"
COMPOSE="${GPU_FIX_COMPOSE:-/vol1/@appcenter/androidemu/docker/docker-compose.yaml}"
OMX_SRC="${GPU_FIX_OMX_SRC:-/root/vdec/omx/libstagefrighthw32.so}"
OMX_XML="${GPU_FIX_OMX_XML:-/root/vdec/omx/media_codecs.xml}"
VDEC_SRC="${GPU_FIX_VDEC_SRC:-/root/vdec/vdec_test3.c}"

LOGDIR="/var/log/oesp-gpu"; mkdir -p "$LOGDIR" 2>/dev/null
BAKDIR="/var/backups/oesp-gpu"; mkdir -p "$BAKDIR" 2>/dev/null

IS_ROOT=0; [ "$(id -u)" = "0" ] && IS_ROOT=1
HAVE_DOCKER=0; docker ps >/dev/null 2>&1 && HAVE_DOCKER=1
CTR_UP=0
if [ "$HAVE_DOCKER" = "1" ]; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CTR" && CTR_UP=1
fi

# ---- JSON 收集 ---------------------------------------------------------------
_CHECKS=""
add() {  # add <id> <cat> <level> <title> <detail> [fix] [need_root] [rebuild]
    local id="$1" cat="$2" lv="$3" ti="$4" de="$5" fx="${6:-}" nr="${7:-0}" rb="${8:-0}"
    ti=$(printf '%s' "$ti" | tr -d '"\\')
    de=$(printf '%s' "$de" | tr -d '"\\')
    fx=$(printf '%s' "$fx" | tr -d '"\\')
    [ -n "$_CHECKS" ] && _CHECKS="$_CHECKS,"
    _CHECKS="$_CHECKS{\"id\":\"$id\",\"cat\":\"$cat\",\"level\":\"$lv\",\"title\":\"$ti\",\"detail\":\"$de\",\"fix\":\"$fx\",\"need_root\":$nr,\"rebuild\":$rb}"
}

# ---- 小工具 -----------------------------------------------------------------
irq() { awk -v n="$1" '$NF==n{s=$2+$3+$4+$5+$6+$7; f=1; exit} END{print (f? s+0 : 0)}' /proc/interrupts 2>/dev/null; }
perm() { stat -c %a "$1" 2>/dev/null | tr -dc '0-9'; }
have() { command -v "$1" >/dev/null 2>&1; }
# ⚠ 不要用 lsmod：它通常在 /usr/sbin，而本脚本经 sudo 拉起时继承的是【应用用户的 PATH】
#   （不含 /usr/sbin），lsmod 找不到 → 模块明明加载着却判成"未加载"（实测误报过）。
#   /proc/modules 零依赖，永远可用。
mod_loaded() { grep -q "^$1[ ]" /proc/modules 2>/dev/null; }
ctr() { [ "$CTR_UP" = "1" ] && docker exec "$CTR" "$@" 2>/dev/null; }
ctrprop() { ctr getprop "$1" 2>/dev/null | tr -d '\r'; }
cmdexec() {  # cmdexec <timeout> <cmd...>  在容器内执行并取输出首行
    local t="$1"; shift
    [ "$CTR_UP" = "1" ] || return 0
    docker exec "$CTR" timeout "$t" "$@" 2>/dev/null | head -1
}

# ==============================================================================
#  ge2d（Amlogic 2D 加速单元）
# ------------------------------------------------------------------------------
#  ⛔ 两个 G12B 专属陷阱（都是实测踩出来的，别当成"理论上应该能跑"）：
#    ① 主线驱动按 AXG 的方式写 BADDR，G12 必须用 canvas 索引 → 原版【跑完不出图】；
#       现象极具迷惑性：ioctl 全成功、中断照常响，只是目标缓冲一个字节没被写。
#       ⇒ 判断"能用"唯一可信的方法是逐像素比对，所以有了 ge2d_selftest。
#    ② vapb_sel 带 CLK_SET_RATE_NO_REPARENT → clk_set_rate 拿不到 500MHz（会 round 回 250MHz），
#       必须在 probe 里 clk_set_parent 切到 vapb_1。所以模块参数写成 ge2d_clk_rate=500000000。
#  能力边界（源码 Missing features 实锤）：❌ 无缩放  ❌ 无 YUV/NV12 输入  ❌ 无色度转换。
#  ⇒ 不要指望它替掉 OMX ANW 里的 NEON NV12→RGBA，它只能做 RGB↔RGB 的搬运/格式转换。
# ==============================================================================
GE2D_KO="/usr/local/lib/oesp-gpu/ge2d_oesp.ko"
GE2D_BIN="/usr/local/lib/oesp-gpu/ge2d_selftest"
GE2D_SRC="/usr/local/lib/oesp-gpu/ge2d/ge2d_selftest.c"
GE2D_LOADED=0; GE2D_MOD=""; GE2D_PATCHED=0; GE2D_DEV=""; GE2D_CLK=-1; GE2D_IRQ=0

ge2d_probe_dev() {
    GE2D_LOADED=0; GE2D_MOD=""; GE2D_PATCHED=0; GE2D_DEV=""; GE2D_CLK=-1; GE2D_IRQ=0
    if mod_loaded ge2d_oesp; then
        GE2D_LOADED=1; GE2D_MOD="ge2d_oesp"; GE2D_PATCHED=1
    elif mod_loaded ge2d; then
        GE2D_LOADED=1; GE2D_MOD="ge2d"; GE2D_PATCHED=0
    fi
    # ⛔ 设备编号不固定（ge2d 启用后它会抢到 video0，硬解顺延到 video1）→ 一律按 name 定位
    local d n
    for d in /sys/class/video4linux/video*; do
        [ -f "$d/name" ] || continue
        n=$(cat "$d/name" 2>/dev/null)
        case "$n" in *ge2d*) GE2D_DEV="/dev/$(basename "$d")" ;; esac
    done
    # 时钟：优先读模块参数（最可靠），再看 debugfs 的 vapb
    local pr=""
    pr=$(cat /sys/module/ge2d_oesp/parameters/ge2d_clk_rate 2>/dev/null)
    if [ -n "$pr" ]; then
        GE2D_CLK=$(( pr / 1000000 ))
    elif [ -r /sys/kernel/debug/clk/clk_summary ]; then
        local v
        v=$(awk 'NF>5 { for(i=1;i<=NF;i++) if($i ~ /ge2d$/) { print int($5/1000000); exit } }' \
            /sys/kernel/debug/clk/clk_summary 2>/dev/null)
        [ -n "$v" ] && GE2D_CLK=$v
    fi
    # ⚠ 不能用 irq()（它按 $NF 精确匹配，而这里行尾是 ff940000.ge2d 不是 ge2d）
    GE2D_IRQ=$(awk '/ge2d/ {s=0; for(i=2;i<=7;i++) s+=$i; print s+0; exit}' /proc/interrupts 2>/dev/null)
    [ -z "$GE2D_IRQ" ] && GE2D_IRQ=0
}

ge2d_run_selftest() {   # ge2d_run_selftest [边长] [次数]
    local side="${1:-512}" rep="${2:-10}"
    if [ ! -x "$GE2D_BIN" ]; then
        if [ ! -f "$GE2D_SRC" ] && [ -f "$SELF_DIR/ge2d_selftest.c" ]; then
            mkdir -p /usr/local/lib/oesp-gpu/ge2d 2>/dev/null
            cp "$SELF_DIR/ge2d_selftest.c" "$GE2D_SRC" 2>/dev/null
        fi
        if [ -f "$GE2D_SRC" ] && have gcc; then
            gcc -O2 -o "$GE2D_BIN" "$GE2D_SRC" 2>/dev/null && chmod 755 "$GE2D_BIN" 2>/dev/null
        fi
    fi
    [ -x "$GE2D_BIN" ] || return 1
    timeout 30 "$GE2D_BIN" "$side" "$rep" 2>/dev/null
}

# ---- VDEC 设备节点定位 ------------------------------------------------------
# ⛔ 绝不能写死 /dev/video0：ge2d 启用后它会【抢走 video0】，硬解顺延成 video1
#    （2026-10-06 就因为这个：体检一直检查 ge2d 的权限，真正的硬解设备没人管，
#     容器内 /dev/video1 是 600 → 硬解静默失效，而控制台还显示"正常"）。
# ⛔ 同时必须排除 video26（aml-vcodec-dec 雷区，open 相关操作会整机内核死锁）。
#    只读 /sys/class/video4linux/*/name 是安全的（白名单操作）。
VDEC_DEV=""
vdec_dev_node() {
    VDEC_DEV=""
    local d n
    for d in /sys/class/video4linux/video*; do
        [ -f "$d/name" ] || continue
        n=$(cat "$d/name" 2>/dev/null)
        case "$n" in
            *ge2d*) continue ;;         # 2D 加速单元，不是解码器
            *aml-vcodec*) continue ;;   # ⛔ 雷区
        esac
        case "$n" in
            *meson-video-decoder*|*meson-vdec*|*vdec*) VDEC_DEV="/dev/$(basename "$d")" ;;
        esac
    done
}

ge2d_status_json() {
    ge2d_probe_dev
    local st=0; [ -x "$GE2D_BIN" ] && st=1
    echo "{"
    echo " \"loaded\":$GE2D_LOADED,\"module\":\"$GE2D_MOD\",\"patched\":$GE2D_PATCHED,"
    echo " \"dev\":\"$GE2D_DEV\",\"clk_mhz\":$GE2D_CLK,\"irq\":$GE2D_IRQ,\"selftest_bin\":$st,"
    echo " \"ko_path\":\"$GE2D_KO\",\"scaling\":false,\"yuv\":false"
    echo "}"
}

ge2d_fix_json() {   # 需要 root
    if [ "$IS_ROOT" != "1" ]; then
        echo "{\"ok\":false,\"msg\":\"需要 root：请用 sudo 执行\"}"; return 1
    fi
    if [ ! -f "$GE2D_KO" ]; then
        echo "{\"ok\":false,\"msg\":\"补丁模块缺失：$GE2D_KO\"}"; return 1
    fi
    # ⚠ 速率检查必须放在"是否已加载"之外：已加载但仍是 250MHz 时也要纠正
    if [ "$(cat /sys/module/ge2d_oesp/parameters/ge2d_clk_rate 2>/dev/null)" != "500000000" ]; then
        rmmod ge2d_oesp 2>/dev/null || true
    fi
    if ! mod_loaded ge2d_oesp; then
        mod_loaded ge2d && rmmod ge2d 2>/dev/null || true
        insmod "$GE2D_KO" ge2d_clk_rate=500000000 >/dev/null 2>&1
    fi
    sleep 1
    ge2d_probe_dev
    # ⚠ 自检结果必须【平铺】成标量再输出：把整段自检 JSON 嵌套进 msg/字段里会带转义引号，
    #   上层用 "取最后一对花括号" 的方式解析时会被嵌套的 { 骗到，直接解析失败（实测踩过）。
    local out=""; out=$(ge2d_run_selftest 128 3 2>/dev/null)
    local st_ok=0 st_mpx=0 st_mm=-1 st_zero=0
    if [ -n "$out" ]; then
        printf '%s' "$out" | grep -q '"ok":true' && st_ok=1
        printf '%s' "$out" | grep -q '"all_zero":true' && st_zero=1
        st_mpx=$(printf '%s' "$out" | sed -n 's/.*"mpx_s":\([0-9.]*\).*/\1/p')
        st_mm=$(printf '%s' "$out" | sed -n 's/.*"mismatch":\([0-9]*\).*/\1/p')
    fi
    [ -z "$st_mpx" ] && st_mpx=0
    [ -z "$st_mm" ] && st_mm=-1
    echo "{\"ok\":$GE2D_LOADED,\"module\":\"$GE2D_MOD\",\"dev\":\"$GE2D_DEV\",\"clk_mhz\":$GE2D_CLK,"
    echo " \"selftest_ok\":$st_ok,\"selftest_zero\":$st_zero,\"mismatch\":$st_mm,\"mpx_s\":$st_mpx}"
}

# ---- GPU（Mali-G52）频率下限 -------------------------------------------------
# 实测：本机 devfreq 只有 simple_ondemand，GPU 长期被钉在最低档 124MHz（max 799MHz），
#       即使 panfrost-job 中断在增长（= GPU 确实在干活）也不升频。
#       抬 min_freq 即可让 cur 立刻跟随；写回 124999998 完全回滚。不改 governor、不碰电压。
gpu_freq_json() {   # gpu_freq_json [status|auto|500|666|800]
    local g=/sys/class/devfreq/ffe40000.gpu
    [ -d "$g" ] || { echo "{\"ok\":false,\"msg\":\"无 devfreq 节点（非 G12 平台？）\"}"; return 1; }
    local arg="${1:-status}" w=0
    case "$arg" in
        auto) echo 124999998 > "$g/min_freq" 2>/dev/null && w=1 ;;
        500)  echo 500000000 > "$g/min_freq" 2>/dev/null && w=1 ;;
        666)  echo 666666656 > "$g/min_freq" 2>/dev/null && w=1 ;;
        800)  echo 799999987 > "$g/min_freq" 2>/dev/null && w=1 ;;
    esac
    [ "$w" = "1" ] && sleep 1
    local cur=$(( $(cat "$g/cur_freq" 2>/dev/null || echo 0) / 1000000 ))
    local min=$(( $(cat "$g/min_freq" 2>/dev/null || echo 0) / 1000000 ))
    local max=$(( $(cat "$g/max_freq" 2>/dev/null || echo 0) / 1000000 ))
    local gov; gov=$(cat "$g/governor" 2>/dev/null)
    local pin=false; [ "$cur" = "$min" ] && [ "$min" != "$max" ] && pin=true
    echo "{\"ok\":true,\"cur_mhz\":$cur,\"min_mhz\":$min,\"max_mhz\":$max,\"governor\":\"$gov\",\"pinned_low\":$pin,\"set\":\"$arg\"}"
}

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
info() { echo "  [ .. ] $*"; }
sec()  { echo; echo "── $* ──"; }

# ==============================================================================
#  检测
# ==============================================================================
detect() {
    local MODE="$1"   # json | text

    # ---------- 宿主：3D GPU ----------
    local dri=0 pf=0 mali=0
    [ -e /dev/dri/renderD128 ] && dri=1
    { mod_loaded panfrost || [ -d /sys/bus/platform/drivers/panfrost ]; } && pf=1
    mod_loaded mali_kbase && mali=1

    if [ "$dri" = "1" ]; then
        add H5 host ok "3D GPU 渲染节点" "/dev/dri/renderD128 存在"
        [ "$MODE" = text ] && ok "3D 渲染节点 /dev/dri/renderD128"
    else
        add H5 host fail "3D GPU 渲染节点" "缺少 /dev/dri/renderD128" "启用 panfrost 驱动" 1
        [ "$MODE" = text ] && bad "缺少 /dev/dri/renderD128 —— panfrost 未加载或 DT 未启用"
    fi
    if [ "$pf" = "1" ]; then
        add H6 host ok "panfrost 驱动" "已就位（模块或内核内置）"
    else
        add H6 host warn "panfrost 驱动" "未加载" "modprobe panfrost" 1
    fi
    if [ "$mali" = "1" ]; then
        add H4 host warn "闭源 mali_kbase" "已加载，与 panfrost 冲突" "写入 blacklist 并重启" 1
    else
        local bl=0
        ls /etc/modprobe.d/ 2>/dev/null | grep -qi mali && bl=1
        if [ "$bl" = "1" ]; then
            add H4 host ok "闭源 mali_kbase" "已屏蔽"
        else
            add H4 host warn "闭源 mali_kbase" "未显式屏蔽" "写入 /etc/modprobe.d/blacklist-mali-kbase.conf" 1
        fi
    fi

    local to=""
    if have dmesg || [ -x /bin/dmesg ] || [ -x /usr/bin/dmesg ]; then
        to=$(dmesg 2>/dev/null | grep -c "gpu sched timeout")
    fi
    if [ -z "$to" ]; then
        add H9 host warn "GPU 调度超时" "无法读取 dmesg（当前环境不可用），未能确认" "用 root 在 SSH 里 dmesg 复核" 0
    elif [ "$to" -eq 0 ] 2>/dev/null; then
        add H9 host ok "GPU 调度超时" "0 次"
    else
        add H9 host fail "GPU 调度超时" "dmesg 累计 $to 次 gpu sched timeout" "检查中断线（需 DTB 修复）" 1
    fi

    # ---------- 宿主：VDEC ----------
    local vmod=0 vnode=0 vperm=""
    mod_loaded meson_vdec && vmod=1
    vdec_dev_node
    if [ -n "$VDEC_DEV" ]; then
        vnode=1; vperm=$(perm "$VDEC_DEV")
    fi

    if [ "$vmod" = "1" ]; then
        add H1 host ok "meson-vdec 模块" "已加载（vdec 中断 $(irq vdec)）"
        [ "$MODE" = text ] && ok "meson-vdec 已加载"
    else
        add H1 host fail "meson-vdec 模块" "未加载，硬解不可用" "modprobe meson-vdec" 1
        [ "$MODE" = text ] && bad "meson-vdec 未加载"
    fi
    if [ "$vnode" = "1" ]; then
        local vn=$(cat "/sys/class/video4linux/$(basename "$VDEC_DEV")/name" 2>/dev/null)
        if [ "$vperm" = "666" ]; then
            add H3 host ok "硬解设备权限（宿主）" "$VDEC_DEV = $vn（$vperm）"
        else
            add H3 host warn "硬解设备权限（宿主）" "$VDEC_DEV = $vn 当前 $vperm，容器 media.codec(uid 1046) 可能无权打开" "chmod 666 $VDEC_DEV" 1
        fi
    else
        add H3 host fail "硬解设备" "未找到 meson-video-decoder 节点" "modprobe meson-vdec" 1
    fi

    local al=0
    [ -f /etc/modules-load.d/meson-vdec.conf ] && al=1
    if [ "$al" = "1" ]; then
        add H2 host ok "meson-vdec 开机自启" "已配置 /etc/modules-load.d/meson-vdec.conf"
    else
        add H2 host warn "meson-vdec 开机自启" "未配置，重启后硬解失效" "写入 modules-load.d" 1
    fi

    local vd=0
    [ -x /usr/local/bin/vdec-dec ] && vd=1
    if [ "$vd" = "1" ]; then
        add H7 host ok "解码工具 vdec-dec" "/usr/local/bin/vdec-dec 就位"
    else
        add H7 host warn "解码工具 vdec-dec" "未安装" "gcc 编译 vdec_test3.c 并安装" 1
    fi

    local cf=$(awk '/^CmaFree:/{print $2}' /proc/meminfo 2>/dev/null)
    cf=${cf:-0}
    local cfmb=$((cf / 1024))
    # 分档说明：本机实测 CmaFree 常年只剩个位数 MB（闭源驱动预占），
    # 但单路 1080p 硬解仍能跑通 —— 所以这里只报"风险"不报"故障"，
    # 只有真的接近 0 才判 fail。
    if [ "$cfmb" -ge 32 ]; then
        add H8 host ok "CMA 连续内存" "${cfmb} MB 空闲"
    elif [ "$cfmb" -ge 2 ]; then
        add H8 host warn "CMA 连续内存" "仅 ${cfmb} MB 空闲（单路可解，多路并发易失败）" "扩容 CMA 或减少并发" 1
    else
        add H8 host fail "CMA 连续内存" "仅 ${cfmb} MB，几乎无可用连续内存" "扩容 CMA（内核参数 cma=）" 1
    fi

    local ud=0
    [ -f /etc/udev/rules.d/99-oesp-gpu.rules ] && ud=1
    if [ "$ud" = "1" ]; then
        add H10 host ok "GPU 设备 udev 规则" "已配置"
    else
        add H10 host warn "GPU 设备 udev 规则" "未配置，容器权限依赖手动 chmod" "写入 99-oesp-gpu.rules" 1
    fi

    # ---- H11 厂商解码栈（amvdec_*）----
    # ⚠⚠ 结论已翻转（2026-10-06）：厂商栈是【雷区】，不是"待补的功能"，别再引导用户去加载。
    #   实测：/dev/video26（aml-vcodec-dec）S_FMT/REQBUFS/STREAMON 必死锁（整机停摆）；
    #         /sys/class/vdec/* 只读 cat 也死锁。
    #   而社区 meson-vdec 已覆盖 H.264 + VP9（VP9 与 ffmpeg 软解逐字节一致），够用。
    #   ⇒ 格式模块"未加载"才是正确状态，加载了反而要提醒。
    # ⚠ 用 /proc/modules 而不是 lsmod（lsmod 在 /usr/sbin，应用用户 PATH 里没有）
    local fm_ok=0 fm_list=""
    for m in amvdec_mmpeg12 amvdec_h265 amvdec_av1 amvdec_vp9 amvdec_avs2 amvdec_vc1 amvdec_mmjpeg amvdec_mmpeg4; do
        if grep -q "^${m} " /proc/modules 2>/dev/null; then
            fm_ok=$((fm_ok + 1)); fm_list="$fm_list $m"
        fi
    done
    if [ "$fm_ok" -gt 0 ]; then
        add H11 host warn "厂商解码栈（雷区）" \
            "$fm_ok/8 个格式模块【已加载】：$fm_list —— /dev/video26 一旦被访问即整机死锁，建议保持卸载" \
            "卸载 amvdec_* 格式模块（勿在硬解运行时操作）" 1
    else
        add H11 host ok "厂商解码栈（雷区）" \
            "格式模块未加载（正确：社区 meson-vdec 已覆盖 H.264/VP9，厂商栈 S_FMT 即死锁）"
    fi

    # ---- H12/H13/H14 ge2d 2D 图形加速 ----
    # ⚠ 两条必须记住的事实：
    #   ① 主线 ge2d 驱动在 G12A/G12B 上【不出图】——它按 AXG 写 BADDR，而 G12 必须用 canvas 索引
    #      寻址。后果极具迷惑性：命令照常完成、中断照常响、但目标缓冲一个字节都没被写。
    #      → 所以体检不能只看"模块加载着"，必须真的跑一次像素比对（H14）。
    #   ② 驱动不认 clk_set_rate（vapb_sel 带 CLK_SET_RATE_NO_REPARENT），500MHz 只能在 probe 时
    #      用参数 ge2d_clk_rate=500000000 配合 clk_set_parent 切到 vapb_1 才拿得到。
    ge2d_probe_dev
    if [ "$GE2D_LOADED" != "1" ]; then
        add H12 host warn "2D 加速 ge2d" "模块未加载，2D 加速不可用（不影响 3D 与硬解）" "加载 canvas 补丁版 ge2d_oesp（500MHz）" 1
        [ "$MODE" = text ] && warn "ge2d 2D 加速：模块未加载"
    else
        if [ "$GE2D_PATCHED" = "1" ]; then
            add H12 host ok "2D 加速 ge2d" "已加载 ${GE2D_MOD}（canvas 补丁版），设备 ${GE2D_DEV:-未就绪}"
            [ "$MODE" = text ] && ok "ge2d 2D 加速：${GE2D_MOD} 已加载（canvas 补丁版）"
        else
            add H12 host fail "2D 加速 ge2d" "加载的是原版 ${GE2D_MOD}（无 canvas 支持）—— 在 G12B 上跑完不出图" "换成 /usr/local/lib/oesp-gpu/ge2d_oesp.ko" 1
            [ "$MODE" = text ] && bad "ge2d：原版模块无 canvas 支持，在 G12B 上不出图"
        fi
        # H13 时钟
        if [ "$GE2D_CLK" = "500" ]; then
            add H13 host ok "ge2d 时钟" "vapb 500MHz（vapb_1 分支，已切父时钟）"
            [ "$MODE" = text ] && ok "ge2d 时钟 = 500MHz"
        elif [ "$GE2D_CLK" = "-1" ]; then
            add H13 host warn "ge2d 时钟" "读不到（debugfs 未挂载），无法确认" "" 0
        else
            add H13 host warn "ge2d 时钟" "当前 ${GE2D_CLK}MHz，低于 500MHz（vapb_sel 默认挂在 250MHz 的 vapb_0）" "用 ge2d_clk_rate=500000000 重载 ge2d_oesp" 1
            [ "$MODE" = text ] && warn "ge2d 时钟 = ${GE2D_CLK}MHz（建议 500MHz）"
        fi
        # H14 真跑一次像素比对（128x128 x3，约 1~2ms，足够便宜且能抓到"跑通却全零"）
        if [ "$MODE" = json ]; then
            local st=""
            st=$(ge2d_run_selftest 128 3 2>/dev/null)
            if printf '%s' "$st" | grep -q '"ok":true'; then
                add H14 host ok "ge2d 自检" "硬件转换与 CPU 参考逐像素一致"
            elif printf '%s' "$st" | grep -q 'all_zero":true'; then
                add H14 host fail "ge2d 自检" "输出全为零 —— canvas 寻址失效，补丁没生效" "重载 /usr/local/lib/oesp-gpu/ge2d_oesp.ko" 1
            elif [ -n "$st" ]; then
                add H14 host fail "ge2d 自检" "像素比对不一致：$(printf '%s' "$st" | sed 's/.*"msg":"//; s/".*//')" "重载 ge2d_oesp 后重试" 1
            else
                add H14 host warn "ge2d 自检" "自检程序不可用（二进制缺失且无法现场编译）" "在 SSH 里 gcc 编译 ge2d_selftest.c" 1
            fi
        fi
    fi

    # ---------- 容器 ----------
    if [ "$CTR_UP" != "1" ]; then
        add C1 container warn "安卓容器" "$CTR 未运行（后续容器项无法检测）" "启动安卓容器" 0
        [ "$MODE" = text ] && warn "安卓容器 $CTR 未运行"
    else
        add C1 container ok "安卓容器" "$CTR 运行中"
        [ "$MODE" = text ] && ok "安卓容器 $CTR 运行中"

        # GPU 渲染模式
        local gm=$(ctrprop ro.boot.redroid_gpu_mode)
        local gn=$(ctrprop ro.boot.redroid_gpu_node)
        local rend=""
        # ⚠ 必须取整行再截断：早期用 'GLES: [^,]+, [^,]+' 只匹配到 "ANGLE (Google"，
        #    把后面的 SwiftShader 截掉了，导致软件渲染被误判成硬件（假阴性）。
        rend=$(docker exec "$CTR" timeout 8 dumpsys SurfaceFlinger 2>/dev/null | grep -m1 "GLES:")
        [ -n "$rend" ] && rend=$(printf '%s' "$rend" | sed 's/^[[:space:]]*//' | cut -c1-140)

        if [ "$gm" = "host" ]; then
            add C2 container ok "容器 GPU 渲染模式" "host（直通${gn:+ $gn}）"
            [ "$MODE" = text ] && ok "容器 GPU 模式 = host（硬件直通）"
        else
            add C2 container fail "容器 GPU 渲染模式" "当前 ${gm:-未设置}（软件渲染）" "compose 改为 redroid_gpu_mode=host 并重建容器" 1 1
            [ "$MODE" = text ] && bad "容器 GPU 模式 = ${gm:-未设置} —— SwiftShader 软件渲染"
        fi

        if [ -n "$rend" ]; then
            if printf '%s' "$rend" | grep -qiE 'swiftshader|llvmpipe|softpipe'; then
                add C3 container fail "容器实际渲染器" "$(printf '%s' "$rend" | cut -c1-110)" "启用 GPU 直通后重建容器" 1 1
            else
                add C3 container ok "容器实际渲染器" "$(printf '%s' "$rend" | cut -c1-110)"
            fi
            [ "$MODE" = text ] && info "渲染器: $(printf '%s' "$rend" | cut -c1-110)"
        fi

        # compose 直通项
        if [ -f "$COMPOSE" ]; then
            local dri_in=0 heap_in=0 drivol_in=0
            # ⚠ 必须锚定列表项（^-）：compose 里大量中文注释含 "/dev/dri" 字样，
            #    只 grep '/dev/dri' 会命中注释造成假阳性（明明没直通却判为已直通）。
            grep -qE '^[[:space:]]*-[[:space:]]*/dev/dri' "$COMPOSE" 2>/dev/null && dri_in=1
            grep -qE '^[[:space:]]*-[[:space:]]*/dev/dma_heap' "$COMPOSE" 2>/dev/null && heap_in=1
            grep -qE '^[[:space:]]*-[[:space:]]*[^#]*dri:ro' "$COMPOSE" 2>/dev/null && drivol_in=1
            if [ "$dri_in" = "1" ] && [ "$heap_in" = "1" ] && [ "$drivol_in" = "1" ]; then
                add C4 container ok "compose GPU 直通项" "/dev/dri + dma_heap + DRI 驱动目录均已声明"
            elif docker exec "$CTR" ls /dev/dri/renderD128 >/dev/null 2>&1; then
                # privileged 容器能看到宿主全部设备节点，即使 compose 没声明也能直通。
                # 这种情况下渲染器确实是硬件（C3 会给出证明），所以只提示没写死，不算故障。
                local miss=""
                [ "$dri_in" = 0 ] && miss="$miss /dev/dri"
                [ "$heap_in" = 0 ] && miss="$miss dma_heap"
                [ "$drivol_in" = 0 ] && miss="$miss DRI驱动目录"
                add C4 container warn "compose GPU 直通项" "compose 未声明:$miss，但 privileged 使容器内可见 /dev/dri（当前生效）" "在 compose 里显式声明以免去掉 privileged 后失效" 1 1
            else
                local miss=""
                [ "$dri_in" = 0 ] && miss="$miss /dev/dri"
                [ "$heap_in" = 0 ] && miss="$miss dma_heap"
                [ "$drivol_in" = 0 ] && miss="$miss DRI驱动目录"
                add C4 container fail "compose GPU 直通项" "缺少:$miss" "运行 tune_compose.sh 补齐并重建容器" 1 1
            fi
        fi

        # OMX 硬解插件
        # ★ 软解模式下插件本就该缺席，这是【用户主动选择】，不是故障 —— 按 pass 计
        if [ "$(decoder_mode)" = "soft" ]; then
            if docker exec "$CTR" test -f "$CTR_SO" 2>/dev/null; then
                add C5 container warn "OMX 硬解插件" "已切软解，但插件仍在容器内（下轮自愈会移出）" "无需操作" 0
            else
                add C5 container ok "OMX 硬解插件" "已切软解（插件已移出，框架走 OMX.google.* 软件解码）"
            fi
            [ "$MODE" = text ] && ok "解码器模式 = 软解（用户选择）"
        else
        local curmd5="" srcmd5=""
        curmd5=$(docker exec "$CTR" md5sum /vendor/lib/libstagefrighthw.so 2>/dev/null | awk '{print $1}')
        if [ -f "$OMX_SRC" ]; then
            srcmd5=$(md5sum "$OMX_SRC" 2>/dev/null | awk '{print $1}')
        elif [ -f "$SELF_DIR/libstagefrighthw32.so" ]; then
            OMX_SRC="$SELF_DIR/libstagefrighthw32.so"; srcmd5=$(md5sum "$OMX_SRC" | awk '{print $1}')
        fi
        if [ -n "$srcmd5" ] && [ "$curmd5" = "$srcmd5" ]; then
            add C5 container ok "OMX 硬解插件" "已注入且为最新版（${curmd5:0:8}）"
            [ "$MODE" = text ] && ok "OMX 插件已是最新版"
        else
            add C5 container fail "OMX 硬解插件" "容器内 ${curmd5:0:8:-未注入} ≠ 源 ${srcmd5:0:8:-无源}" "docker cp 注入插件并重启 media.codec" 0
            [ "$MODE" = text ] && bad "OMX 插件不一致（容器 ${curmd5:0:8} / 源 ${srcmd5:0:8}）"
        fi
        fi   # <- 软解模式分支结束

        local xc=$(docker exec "$CTR" grep -c "OMX.meson" /vendor/etc/media_codecs.xml 2>/dev/null | tr -dc '0-9')
        [ -z "$xc" ] && xc=0
        if [ "$xc" -gt 0 ] 2>/dev/null; then
            add C6 container ok "media_codecs 注册" "已含 OMX.meson（$xc 处）"
        else
            add C6 container fail "media_codecs 注册" "缺少 OMX.meson 条目，App 只能选软解" "补写 media_codecs.xml" 0
        fi

        # 容器内设备权限（⛔ 按宿主实际 VDEC 节点检查，不写死 video0）
        local cvp=""
        [ -n "$VDEC_DEV" ] && cvp=$(docker exec "$CTR" stat -c %a "$VDEC_DEV" 2>/dev/null | tr -dc '0-9')
        if [ -n "$VDEC_DEV" ] && [ "$cvp" = "666" ]; then
            add C7 container ok "容器内 $VDEC_DEV" "权限 666（media.codec 可打开）"
        elif [ -z "$VDEC_DEV" ]; then
            add C7 container warn "容器内硬解设备" "宿主未找到 meson-video-decoder 节点" "modprobe meson-vdec" 1
        else
            add C7 container fail "容器内 $VDEC_DEV" "权限 ${cvp:-未知}，硬解会静默失效" "docker exec chmod 666 $VDEC_DEV" 0
        fi

        local ctp=$(docker exec "$CTR" stat -c %a /data/local/tmp 2>/dev/null | tr -dc '0-9')
        if [ "$ctp" = "777" ]; then
            add C8 container ok "容器内 /data/local/tmp" "权限 777（诊断工具可写）"
        else
            add C8 container warn "容器内 /data/local/tmp" "权限 ${ctp:-未知}" "chmod 777" 0
        fi

        # 预热参数
        # ⚠ 结论已变（2026-10-06）：自愈脚本刻意【不再】写 debug.meson.prelude/drop/tail。
        #   这是全局属性，会覆盖插件【按格式】的默认值 —— H.264 与 VP9 需要不同的 prelude，
        #   写一个全局 2 反而会让另一个格式退化。所以"未设置"才是正确状态，别再提示用户 setprop。
        local pl=$(ctrprop debug.meson.prelude)
        if [ "$(decoder_mode)" = "soft" ]; then
            add C10 container ok "硬解预热参数" "软解模式，无需预热参数"
        elif [ -n "$pl" ] && [ "$pl" != "0" ] && [ "$pl" != "" ]; then
            add C10 container warn "硬解预热参数" "debug.meson.prelude=$pl（遗留值，会覆盖插件按格式的默认值）" "重建容器或 setprop debug.meson.prelude 0" 0
        else
            add C10 container ok "硬解预热参数" "未设置（正确：由插件按格式自行决定）"
        fi
    fi

    # ---------- 自愈 cron ----------
    local sh=0
    # ⚠ 不能只靠 crontab -l：sudo 下 PATH 可能不含 crontab，且它是 per-user 的。
    #    这里同时直接读 crontab 的落盘文件（本机实测 cron 就是装在这里的）。
    if { command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q omx_autodeploy; } \
       || grep -rq omx_autodeploy /var/spool/cron/crontabs/ /etc/cron.d/ /etc/crontab 2>/dev/null; then
        sh=1
    fi
    if [ "$sh" = "1" ]; then
        add S1 selfheal ok "自愈定时任务" "已安装（每分钟检查插件与权限）"
    else
        add S1 selfheal warn "自愈定时任务" "未安装，容器重建后硬解不会自动恢复" "写入 root crontab" 1
    fi

    # ---------- 自愈完整性守卫 ----------
    # 事故原型：整机断电后主自愈脚本被截成 0 字节，cron 每分钟跑空脚本，
    # 插件注入 / 权限硬化 / CMA 守卫全部静默失效且毫无报错。
    local gd=0
    if { command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q guard_autodeploy; } \
       || grep -rq guard_autodeploy /var/spool/cron/crontabs/ /etc/cron.d/ /etc/crontab 2>/dev/null; then
        gd=1
    fi
    if [ "$gd" = "1" ]; then
        add S2 selfheal ok "自愈完整性守卫" "已安装（主脚本被截断/损坏时自动从备份恢复）"
    else
        add S2 selfheal warn "自愈完整性守卫" "未安装，断电可能把自愈脚本截成 0 字节而无声失效" "写入 root crontab" 1
    fi

    # ---------- 雷区暴露 ----------
    if [ "$CTR_UP" = "1" ]; then
        local priv=$(docker inspect "$CTR" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
        if [ "$priv" = "true" ]; then
            add R1 risk warn "特权容器暴露雷区" "$CTR 为 privileged，容器内可见 /dev/video26；一旦访问即整机内核死锁" "改用 --device=${VDEC_DEV:-/dev/videoN} --device=/dev/dri/renderD128 最小权限（实测去 privileged 后 redroid 起不来，故仅提示）" 0
        fi
    fi
}

emit_json() {
    # 统计各级别
    local n_ok n_warn n_fail
    n_ok=$(printf '%s' "$_CHECKS" | grep -o '"level":"ok"' | wc -l | tr -d ' ')
    n_warn=$(printf '%s' "$_CHECKS" | grep -o '"level":"warn"' | wc -l | tr -d ' ')
    n_fail=$(printf '%s' "$_CHECKS" | grep -o '"level":"fail"' | wc -l | tr -d ' ')
    local total=$((n_ok + n_warn + n_fail))
    local score=0
    [ "$total" -gt 0 ] && score=$(( (n_ok * 100 + n_warn * 50) / total ))
    printf '{"generated":"%s","root":%s,"docker":%s,"container":"%s","container_up":%s,"score":%d,"ok":%s,"warn":%s,"fail":%s,"checks":[%s]}\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$IS_ROOT" "$HAVE_DOCKER" "$CTR" "$CTR_UP" \
        "$score" "$n_ok" "$n_warn" "$n_fail" "$_CHECKS"
}

# ==============================================================================
#  修补
# ==============================================================================
need_root() { [ "$IS_ROOT" = "1" ] || { warn "需要 root，跳过：$*"; return 1; }; }

fix_container() {
    sec "容器层修补（无需 root，有 docker 权限即可）"
    [ "$CTR_UP" = "1" ] || { warn "容器 $CTR 未运行，跳过"; return 0; }

    # 设备与目录权限（⛔ 按 name 定位 VDEC 节点：ge2d 启用后编号会顺延）
    vdec_dev_node
    if [ -n "$VDEC_DEV" ]; then
        docker exec "$CTR" chmod 666 "$VDEC_DEV" 2>/dev/null \
            && ok "容器内 $VDEC_DEV → 666" || warn "chmod $VDEC_DEV 失败"
    else
        warn "宿主未找到 meson-video-decoder 节点，跳过设备权限修补"
    fi
    docker exec "$CTR" chmod 777 /data/local/tmp 2>/dev/null && ok "容器内 /data/local/tmp → 777"

    # 预热参数：⚠ 刻意不写。全局属性会覆盖插件按格式的默认值（H.264 与 VP9 需要不同的
    #   prelude），写了反而让某个格式退化。插件内部已有正确默认值。
    info "预热参数：不写（交给插件按格式决定）"

    # OMX 插件
    # ★ 自愈必须尊重"用户已切软解"：否则每分钟把插件装回去，切换会被悄悄撤销
    if [ "$(decoder_mode)" = "soft" ]; then
        if docker exec "$CTR" test -f "$CTR_SO" 2>/dev/null; then
            docker exec "$CTR" mv "$CTR_SO" "$CTR_SO_OFF" 2>/dev/null
            NEED_HAL=1
            ok "解码器=软解：OMX 插件已移出"
        else
            ok "解码器=软解：插件不在位（符合预期）"
        fi
    else
    local src=""
    [ -f "$OMX_SRC" ] && src="$OMX_SRC"
    [ -z "$src" ] && [ -f "$SELF_DIR/libstagefrighthw32.so" ] && src="$SELF_DIR/libstagefrighthw32.so"
    if [ -n "$src" ]; then
        if docker exec "$CTR" test -f "$CTR_SO_OFF" 2>/dev/null; then
            docker exec "$CTR" mv "$CTR_SO_OFF" "$CTR_SO" 2>/dev/null
            docker exec "$CTR" chmod 644 "$CTR_SO" 2>/dev/null
            ok "由软解切回硬解：OMX 插件已归位"
            NEED_HAL=1
        fi
        local cur=$(docker exec "$CTR" md5sum /vendor/lib/libstagefrighthw.so 2>/dev/null | awk '{print $1}')
        local new=$(md5sum "$src" 2>/dev/null | awk '{print $1}')
        if [ "$cur" != "$new" ]; then
            docker cp "$src" "$CTR":/vendor/lib/libstagefrighthw.so && \
            docker exec "$CTR" chmod 644 /vendor/lib/libstagefrighthw.so && \
            ok "OMX 插件已注入（${new:0:8}）" || bad "插件注入失败"
            NEED_HAL=1
        else
            ok "OMX 插件已是最新（${new:0:8}）"
        fi
    else
        warn "未找到 OMX 插件源（$OMX_SRC），跳过"
    fi
    fi   # <- 软解模式分支结束

    # media_codecs.xml
    if ! docker exec "$CTR" grep -q "OMX.meson" /vendor/etc/media_codecs.xml 2>/dev/null; then
        local xml=""
        [ -f "$OMX_XML" ] && xml="$OMX_XML"
        [ -z "$xml" ] && [ -f "$SELF_DIR/media_codecs.xml" ] && xml="$SELF_DIR/media_codecs.xml"
        # 兜底：直接从容器自身的系统表里生成一份带 meson 的（完全自包含，不依赖外部文件）
        if [ -z "$xml" ]; then
            local tmp_xml="${TMPDIR:-/tmp}/_mc_$$.xml"
            docker exec "$CTR" cat /vendor/etc/media_codecs.xml > "$tmp_xml" 2>/dev/null
            [ -s "$tmp_xml" ] || docker exec "$CTR" cat /system/etc/media_codecs.xml > "$tmp_xml" 2>/dev/null
            if [ -s "$tmp_xml" ]; then
                if ! grep -q "OMX.meson" "$tmp_xml"; then
                    # 在 </Decoders> 前插入 meson 解码器条目
                    awk '
                      /<\/Decoders>/ && !done {
                        print "        <MediaCodec name=\"OMX.meson.h264.decoder\" type=\"video/avc\" >"
                        print "            <Limit name=\"size\" min=\"16x16\" max=\"1920x1088\" />"
                        print "            <Limit name=\"alignment\" value=\"2x2\" />"
                        print "            <Limit name=\"block-size\" value=\"16x16\" />"
                        print "            <Limit name=\"blocks-per-second\" range=\"1-244800\" />"
                        print "            <Limit name=\"bitrate\" range=\"1-20000000\" />"
                        print "            <Feature name=\"adaptive-playback\" />"
                        print "        </MediaCodec>"
                        done=1
                      }
                      { print }
                    ' "$tmp_xml" > "$tmp_xml.new" && mv "$tmp_xml.new" "$tmp_xml"
                fi
                xml="$tmp_xml"
            fi
        fi
        if [ -n "$xml" ]; then
            docker cp "$xml" "$CTR":/vendor/etc/media_codecs.xml && \
            docker exec "$CTR" chmod 644 /vendor/etc/media_codecs.xml && \
            ok "media_codecs.xml 已补写 OMX.meson" || bad "xml 写入失败"
            NEED_HAL=1
        else
            warn "无法取得 media_codecs.xml 源，跳过"
        fi
    else
        ok "media_codecs.xml 已含 OMX.meson"
    fi

    # 重启 HAL + 刷新 mediaserver 缓存
    if [ "${NEED_HAL:-0}" = "1" ]; then
        local opid=$(docker exec "$CTR" ps -A 2>/dev/null | grep media.codec | awk '{print $2}' | head -1)
        [ -n "$opid" ] && docker exec "$CTR" kill -9 "$opid" 2>/dev/null
        ok "已重启 media.codec（旧 PID=$opid）"
        sleep 4
    fi
    local mpid=$(ctrprop init.svc_debug_pid.media | tr -dc '0-9')
    local mstart=0 somtime=0
    [ -n "$mpid" ] && mstart=$(docker exec "$CTR" stat -c %Y /proc/$mpid 2>/dev/null | tr -dc '0-9')
    [ -n "$src" ] && somtime=$(stat -c %Y "$src" 2>/dev/null | tr -dc '0-9')
    [ -z "$mstart" ] && mstart=0
    [ -z "$somtime" ] && somtime=0
    if [ -n "$mpid" ] && [ "$mstart" -lt "$somtime" ]; then
        docker exec "$CTR" kill -9 "$mpid" 2>/dev/null
        sleep 3
        ok "已重启 mediaserver 以刷新 codec 列表缓存（旧 PID=$mpid）"
    fi
}

fix_host() {
    sec "宿主层修补（需要 root）"
    need_root "宿主层修补" || return 0

    # 1. 屏蔽闭源 mali
    local bl=/etc/modprobe.d/blacklist-mali-kbase.conf
    if [ -f "$bl" ]; then ok "mali blacklist 已存在"
    else
        printf 'blacklist mali_kbase\nblacklist mali\n' > "$bl" && ok "已写入 $bl" || bad "写入 $bl 失败"
    fi

    # 2. 加载 meson-vdec + 开机自启
    if mod_loaded meson_vdec; then
        ok "meson-vdec 已加载"
    else
        modprobe meson-vdec 2>/dev/null && sleep 2 && ok "modprobe meson-vdec 成功" \
            || warn "modprobe 失败（内核可能未编译该模块）"
    fi
    vdec_dev_node
    if [ -n "$VDEC_DEV" ] && [ ! -f /etc/modules-load.d/meson-vdec.conf ]; then
        echo "meson-vdec" > /etc/modules-load.d/meson-vdec.conf && ok "已设置开机加载" || warn "写入失败"
    fi

    # 3. 设备权限（⛔ 按 name 定位，别 chmod video0 —— 那可能是 ge2d）
    if [ -n "$VDEC_DEV" ]; then
        chmod 666 "$VDEC_DEV" 2>/dev/null && ok "宿主 $VDEC_DEV → 666"
    fi

    # 4. udev 规则
    # ⛔⛔ 绝对不能写 KERNEL=="video*" 通配：那会把 video26（aml-vcodec-dec，雷区）
    #     也设成 666 —— 容器一旦打开它整机内核死锁。必须按 name 白名单放行。
    local ud=/etc/udev/rules.d/99-oesp-gpu.rules
    cat > "$ud" <<'EOF'
# ⛔ 只放行这两个：meson-video-decoder（社区硬解）与 meson-ge2d（2D 加速）
# ⛔ 绝不写 KERNEL=="video*" —— video26(aml-vcodec-dec) 是雷区，给权限 = 引狼入室
KERNEL=="video*", ATTR{name}=="meson-video-decoder", MODE="0666"
KERNEL=="video*", ATTR{name}=="meson-ge2d", MODE="0666"
KERNEL=="renderD128", MODE="0666"
KERNEL=="card0", MODE="0666"
EOF
    [ -f "$ud" ] && ok "已写入 $ud"
    have udevadm && { udevadm control --reload-rules >/dev/null 2>&1; udevadm trigger >/dev/null 2>&1; ok "已重载 udev"; }

    # 5. vdec-dec 工具
    if [ ! -x /usr/local/bin/vdec-dec ]; then
        local s=""
        [ -f "$VDEC_SRC" ] && s="$VDEC_SRC"
        [ -z "$s" ] && [ -f "$SELF_DIR/vdec_test3.c" ] && s="$SELF_DIR/vdec_test3.c"
        if [ -n "$s" ] && have gcc; then
            gcc -O2 -o /usr/local/bin/vdec-dec "$s" 2>>"$LOGDIR/build.log" \
                && ok "已编译安装 vdec-dec" || bad "编译失败（见 $LOGDIR/build.log）"
        else
            warn "缺少 vdec_test3.c 或 gcc，跳过 vdec-dec"
        fi
    else
        ok "vdec-dec 已就位"
    fi

    # 6. 自愈 cron（主脚本 + 完整性守卫）
    #
    # 为什么先固化再挂 cron：应用目录权限是 777，直接把 root 每分钟要跑的脚本
    # 放在那里等于开放提权。必须先复制进 root 拥有的 /usr/local/lib/oesp-gpu/。
    # 源优先取包内 scripts/（随 FPK 分发），其次沿用设备上已有的老位置。
    local sdir="${DECODER_STATE_DIR:-/usr/local/lib/oesp-gpu}"
    mkdir -p "$sdir" 2>/dev/null
    local src=""
    for c in "$SELF_DIR/omx_autodeploy.sh" "$sdir/omx_autodeploy.sh" /root/vdec/omx/omx_autodeploy.sh; do
        [ -s "$c" ] && { src="$c"; break; }
    done
    if [ -z "$src" ]; then
        warn "未找到 omx_autodeploy.sh（应有于 $SELF_DIR/），跳过自愈任务"
    else
        cp -f "$src" "$sdir/omx_autodeploy.sh" 2>/dev/null && chmod 755 "$sdir/omx_autodeploy.sh"
        # 守卫本体 + 插件 .so 一并固化：前者防断电截断，后者保证自愈有源可注
        [ -s "$SELF_DIR/guard_autodeploy.sh" ] && { \
            cp -f "$SELF_DIR/guard_autodeploy.sh" "$sdir/guard_autodeploy.sh" 2>/dev/null; \
            chmod 755 "$sdir/guard_autodeploy.sh"; }
        [ -s "$SELF_DIR/libstagefrighthw32.so" ] && \
            cp -f "$SELF_DIR/libstagefrighthw32.so" "$sdir/libstagefrighthw32.so" 2>/dev/null

        mkdir -p /root/vdec/omx 2>/dev/null
        local need=0
        crontab -l 2>/dev/null | grep -q omx_autodeploy  || need=1
        crontab -l 2>/dev/null | grep -q guard_autodeploy || need=1
        if [ "$need" = "1" ]; then
            ( crontab -l 2>/dev/null | grep -v -e omx_autodeploy -e guard_autodeploy; \
              echo "* * * * * /bin/bash $sdir/guard_autodeploy.sh >> /root/vdec/omx/autodeploy.log 2>&1"; \
              echo "* * * * * /bin/bash $sdir/omx_autodeploy.sh >> /root/vdec/omx/autodeploy.log 2>&1" ) | crontab -
            ok "已安装 OMX 自愈定时任务（含完整性守卫，源 $src）"
        else
            ok "OMX 自愈定时任务已存在"
        fi
    fi

    # 6.5 厂商解码格式模块（amvdec_*）：飞牛默认不加载，HEVC/AV1/VP9 等硬件空置
    #     脚本自带「防启动循环」保护：加载前写标记、成功后清除，
    #     若加载触发死锁被看门狗复位，重启后会检测到残留标记并跳过。
    if [ -s "$SELF_DIR/amvdec_formats.sh" ]; then
        cp -f "$SELF_DIR/amvdec_formats.sh" "$sdir/amvdec_formats.sh" 2>/dev/null \
            && chmod 755 "$sdir/amvdec_formats.sh"
        crontab -l 2>/dev/null | grep -q amvdec_formats || \
            ( crontab -l 2>/dev/null; \
              echo "* * * * * /bin/bash $sdir/amvdec_formats.sh >> /var/log/amvdec_formats.log 2>&1" ) | crontab -
        ok "已固化厂商格式模块加载脚本（含防启动循环保护）"
    else
        warn "未找到 amvdec_formats.sh（应有于 $SELF_DIR/），HEVC/AV1 等格式模块不会自动加载"
    fi
}

fix_gpu_passthrough() {
    sec "启用容器 GPU 直通（会重建安卓容器，云手机将短暂中断）"
    need_root "GPU 直通修补" || return 0
    [ -f "$COMPOSE" ] || { bad "compose 不存在：$COMPOSE"; return 0; }

    # 备份
    local bak="$BAKDIR/docker-compose.yaml.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$COMPOSE" "$bak" && ok "已备份 compose → $bak"

    # 优先用官方 tune_compose.sh（它已正确处理节点选择/驱动目录/gpu_node/画面档位）
    # ⚠ 用 -f 而不是 -x 判定：本机该文件是 644（没执行位），用 -x 会静默走手写兜底，
    #    结果漏配 gpu_node 与 devices 直通。bash 显式调用不要求执行位。
    local tc=/vol1/@appcenter/androidemu/scripts/tune_compose.sh
    if [ -f "$tc" ]; then
        info "调用官方 $tc"
        bash "$tc" "$COMPOSE" 2>&1 | sed 's/^/       /'
        ok "tune_compose 执行完毕"
    else
        # 手写兜底
        local node=/dev/dri/renderD128
        [ -e /dev/dri/card0 ] && [ ! -e "$node" ] && node=/dev/dri/card0
        local dridir=""
        for d in /usr/lib/aarch64-linux-gnu/dri /usr/lib/x86_64-linux-gnu/dri /usr/lib/arm-linux-gnueabihf/dri; do
            [ -d "$d" ] && ls "$d"/*_dri.so >/dev/null 2>&1 && dridir="$d" && break
        done
        # ⚠ 同样要锚定列表项：compose 的中文注释里就有 "/dev/dri" 字样，
        #    只 grep '/dev/dri' 会命中注释 → 误判"已直通"而跳过，devices 段始终写不进去。
        grep -qE '^[[:space:]]*-[[:space:]]*/dev/dri' "$COMPOSE" \
            || sed -i '0,/^[[:space:]]*devices:[[:space:]]*$/s//&\n      - \/dev\/dri:\/dev\/dri\n      - \/dev\/dma_heap:\/dev\/dma_heap/' "$COMPOSE"
        [ -n "$dridir" ] && ! grep -q 'dri:ro' "$COMPOSE" && \
            sed -i "0,\#^[[:space:]]*volumes:[[:space:]]*\$#s##&\n      - $dridir:$dridir:ro#" "$COMPOSE"
        if grep -qE 'androidboot\.redroid_gpu_mode=' "$COMPOSE"; then
            sed -i 's/androidboot\.redroid_gpu_mode=[a-z]*/androidboot.redroid_gpu_mode=host/' "$COMPOSE"
        else
            sed -i '0,/^[[:space:]]*-[[:space:]]*androidboot\.redroid_fps=.*$/s//&\n      - androidboot.redroid_gpu_mode=host/' "$COMPOSE"
        fi
        ok "已手写补齐直通参数（节点 $node，DRI ${dridir:-未找到}）"
    fi

    grep -q "redroid_gpu_mode=host" "$COMPOSE" && ok "compose 已为 host 模式" || bad "compose 仍未切到 host"

    if [ "$DO_REBUILD" = "1" ]; then
        info "重建容器（androidemu）..."
        ( cd "$(dirname "$COMPOSE")" && docker compose up -d ) 2>&1 | tail -5 | sed 's/^/       /'
        ok "容器已重建，请等待安卓开机后复查渲染器"
    else
        info "未带 --rebuild，仅修改 compose。执行此命令生效："
        info "  cd $(dirname "$COMPOSE") && docker compose up -d"
    fi
}

# ==============================================================================
#  安卓解码器软/硬解切换（2026-10-04 新增）
#  ---------------------------------------------------------------------------
#  背景（实测结论，别再走弯路）：
#    真实播放器里组件被迫走 ByteBuffer + SoftwareRenderer（容器 gralloc 的
#    AHardwareBuffer_lock 恒 -38，Surface 零拷贝走不通），实测同一 720p 素材：
#       meson 硬解 media.codec 1.40~1.50 核
#       google 软解 media.codec 0.86~0.88 核
#    → **硬解是负收益**。优化尝试（整块 memcpy / 零拷贝 / 空闲等待）均无效
#      （空闲等待还会把解码线程卡死）。所以把选择权交给用户。
#  实现方式：把 /vendor/lib/libstagefrighthw.so 移出/移回。
#    ⚠ 改 media_codecs.xml 无效（实测仍会选中 meson 组件），必须让组件不存在。
# ==============================================================================
# ⚠ 必须是【固定绝对路径】，不能是 $SELF_DIR：脚本同时被 root cron 和
#   sudo（应用侧）调用，两份副本位于不同目录，只有固定路径才能保证
#   两边读到的模式一致。这里选 /usr/local/lib/oesp-gpu/（root 拥有、可写）。
DECODER_STATE_DIR="/usr/local/lib/oesp-gpu"
mkdir -p "$DECODER_STATE_DIR" 2>/dev/null
DECODER_MODE_FILE="$DECODER_STATE_DIR/decoder_mode"
CTR_SO=/vendor/lib/libstagefrighthw.so
CTR_SO_OFF=/data/local/tmp/_hw_disabled.so

decoder_mode() {
    local m
    m=$(cat "$DECODER_MODE_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -z "$m" ] && m="hard"
    echo "$m"
}

decoder_switch() {
    local want="$1" m=""
    echo "$want" > "$DECODER_MODE_FILE" 2>/dev/null
    if [ "$CTR_UP" != "1" ]; then
        echo "{\"mode\":\"$want\",\"ok\":false,\"msg\":\"安卓容器未运行，已记录模式，容器起来后自动生效\"}"
        return 1
    fi
    if [ "$want" = "soft" ]; then
        if docker exec "$CTR" test -f "$CTR_SO" 2>/dev/null; then
            docker exec "$CTR" mv "$CTR_SO" "$CTR_SO_OFF" 2>/dev/null
            m="插件已移出"
        else
            m="插件本就不在位"
        fi
    else
        if docker exec "$CTR" test -f "$CTR_SO_OFF" 2>/dev/null; then
            docker exec "$CTR" mv "$CTR_SO_OFF" "$CTR_SO" 2>/dev/null
            docker exec "$CTR" chmod 644 "$CTR_SO" 2>/dev/null
            m="插件已恢复"
        else
            local src=""
            [ -f "$OMX_SRC" ] && src="$OMX_SRC"
            [ -z "$src" ] && [ -f "$SELF_DIR/libstagefrighthw32.so" ] && src="$SELF_DIR/libstagefrighthw32.so"
            if [ -n "$src" ]; then
                docker cp "$src" "$CTR":"$CTR_SO" 2>/dev/null && \
                docker exec "$CTR" chmod 644 "$CTR_SO" 2>/dev/null && m="插件已从源注入"
            else
                m="未找到插件源，无法恢复"
            fi
        fi
    fi
    # ⚠ mediaserver 缓存 MediaCodecList，只重启 HAL 不够，两个都要杀
    docker exec "$CTR" sh -c 'kill $(pidof media.codec) $(pidof mediaserver) 2>/dev/null' >/dev/null 2>&1
    sleep 6
    local has=0
    docker exec "$CTR" test -f "$CTR_SO" 2>/dev/null && has=1
    echo "{\"mode\":\"$want\",\"ok\":true,\"msg\":\"$m\",\"plugin_in_place\":$has}"
}

decoder_status() {
    local m; m=$(decoder_mode)
    local has=0 incont=0
    if [ "$CTR_UP" = "1" ]; then
        docker exec "$CTR" test -f "$CTR_SO" 2>/dev/null && has=1
        [ "$has" = "1" ] && incont=1
    fi
    echo "{\"mode\":\"$m\",\"plugin_in_place\":$incont,\"container_up\":$CTR_UP}"
}

# ==============================================================================
#  主流程
# ==============================================================================
MODE="--report"
DO_HOST=0
DO_REBUILD=0
DECODER_ARG=""
ARG=""
for a in "$@"; do
    case "$a" in
        --detect) MODE="--detect" ;;
        --report) MODE="--report" ;;
        --fix)    MODE="--fix" ;;
        --host)   DO_HOST=1 ;;
        --rebuild) DO_REBUILD=1 ;;
        --decoder) MODE="--decoder" ;;
        --gpu-clients) MODE="--gpu-clients" ;;
        --ge2d) MODE="--ge2d" ;;
        --gpu-freq) MODE="--gpu-freq" ;;
        soft|hard) DECODER_ARG="$a" ;;
        status|selftest|fix|auto|500|666|800) ARG="$a" ;;
        --yes)    ;;
    esac
done

# ---- GPU 客户端（按进程归因）----------------------------------------------
# 内核 6.x 的 DRM fdinfo 会为每个 GPU client 报告驱动名、当前频率与显存占用，
# 读法：/proc/<pid>/fd 里指向 /dev/dri/* 的 fd，再看 /proc/<pid>/fdinfo/<fd>。
# 控制台应用以普通用户运行时读不到别的用户的 /proc/<pid>/fd（Permission denied），
# 所以把这段采集放进已放行的 root 脚本，由应用经 sudo -n 调用。
# ⛔ 全程只读 /proc，绝不碰 /sys/class/vdec 与 /dev/video26
gpu_clients_json() {
    python3 - <<'PYEOF'
import os, json

def rf(p):
    try:
        with open(p, "r") as f:
            return f.read()
    except Exception:
        return ""

def cgroup_of(pid):
    for ln in rf("/proc/%s/cgroup" % pid).splitlines():
        tail = ln.split("::")[-1] if "::" in ln else ln
        for key in ("docker-", "libpod-", "crio-", "lxc/"):
            i = tail.find(key)
            if i >= 0:
                return tail[i + len(key):].rstrip("/").replace(".scope", "")[:12]
    return ""

def num(info, key):
    try:
        return int(info.get(key, "0").split()[0])
    except Exception:
        return 0

def mhz(info, key):
    try:
        return int(round(num(info, key) / 1000000.0))
    except Exception:
        return 0

seen = {}
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
        for ln in rf("/proc/%s/fdinfo/%s" % (pid, fd)).splitlines():
            if ln.startswith("drm-"):
                k, _, v = ln.partition(":")
                info[k.strip()] = v.strip()
        if not info.get("drm-driver"):
            continue
        cid = info.get("drm-client-id", fd)
        if (pid, cid) in seen:
            continue
        # ⚠ 显存不能简单求和：同一进程常持有多个 drm client（如 surfaceflinger 2 个），
        #   且 drm-total/resident 含【跨 client 共享】的部分，直接相加会重复计数。
        #   因此同时输出 shared，由上层做「独占 + 共享峰值」的去重估算。
        cf = mhz(info, "drm-curfreq-fragment")
        mf = mhz(info, "drm-maxfreq-fragment")
        cv = mhz(info, "drm-curfreq-vertex-tiler")
        mv = mhz(info, "drm-maxfreq-vertex-tiler")
        seen[(pid, cid)] = {
            "pid": int(pid),
            "comm": rf("/proc/%s/comm" % pid).strip() or "?",
            "dev": link.rsplit("/", 1)[-1],
            "driver": info.get("drm-driver", "?"),
            "cid": cid,
            "res_mb": num(info, "drm-resident-memory") // 1024,
            "shared_mb": num(info, "drm-shared-memory") // 1024,
            "total_mb": num(info, "drm-total-memory") // 1024,
            # 频率分两个电源域：片元(fragment) 与 顶点/tiler(vertex-tiler)
            "cur_frag_mhz": cf, "max_frag_mhz": mf,
            "cur_vert_mhz": cv, "max_vert_mhz": mv,
            "cur_mhz": cf or cv,
            "max_mhz": mf or mv,
            "cgroup": cgroup_of(pid),
        }

print(json.dumps(sorted(seen.values(), key=lambda x: -x["res_mb"])[:12], ensure_ascii=False))
PYEOF
}

if [ "$MODE" = "--gpu-clients" ]; then
    gpu_clients_json
    exit 0
fi

if [ "$MODE" = "--decoder" ]; then
    if [ -z "$DECODER_ARG" ] || [ "$DECODER_ARG" = "status" ] || [ "$ARG" = "status" ]; then
        decoder_status
    else
        decoder_switch "$DECODER_ARG"
    fi
    exit 0
fi

# ---- ge2d 2D 加速：status（只读）/ selftest（跑一次像素比对）/ fix（重载补丁模块，需 root）
if [ "$MODE" = "--ge2d" ]; then
    case "${ARG:-status}" in
        selftest) ge2d_run_selftest 512 10 || echo '{"ok":false,"msg":"自检程序不可用（二进制缺失且无法现场编译）"}' ;;
        fix)      ge2d_fix_json ;;
        *)        ge2d_status_json ;;
    esac
    exit 0
fi

# ---- GPU 频率下限：status / auto / 500 / 666 / 800
if [ "$MODE" = "--gpu-freq" ]; then
    gpu_freq_json "${ARG:-status}"
    exit 0
fi

if [ "$MODE" = "--detect" ]; then
    detect json
    emit_json
    exit 0
fi

if [ "$MODE" = "--report" ]; then
    echo "════════════════════════════════════════════════"
    echo " OESP GPU 体检报告   $(date '+%F %T')"
    echo " root=$IS_ROOT  docker=$HAVE_DOCKER  容器=$CTR($CTR_UP)"
    echo "════════════════════════════════════════════════"
    sec "宿主硬件与驱动"; detect text
    echo
    echo " 通过 $PASS / 警告 $WARN / 失败 $FAIL"
    echo
    echo "⛔ 雷区（本脚本已规避，你也别碰）："
    echo "   1. /dev/video26      2. /sys/class/vdec/*"
    echo "   3. ffmpeg h264_v4l2m2m   4. 运行时 rmmod mali"
    exit 0
fi

# ---- --fix ----
echo "════════════════════════════════════════════════"
echo " OESP GPU 一键修补  $(date '+%F %T')  root=$IS_ROOT  host层=$DO_HOST  重建=$DO_REBUILD"
echo "════════════════════════════════════════════════"
NEED_HAL=0
fix_container
[ "$DO_HOST" = "1" ] && fix_host
[ "$DO_HOST" = "1" ] && [ "$DO_REBUILD" = "1" ] && fix_gpu_passthrough
if [ "$DO_HOST" = "1" ] && [ "$DO_REBUILD" != "1" ]; then
    # 直通参数缺失时提示（不自动重建）
    if [ "$CTR_UP" = "1" ] && [ "$(ctrprop ro.boot.redroid_gpu_mode)" != "host" ]; then
        sec "可选：启用 GPU 直通"
        info "容器当前为软件渲染。加 --rebuild 参数可切换为硬件直通（会重建容器）："
        info "  sudo bash $SELF_DIR/$(basename "$0") --fix --host --rebuild"
    fi
fi
echo
echo "════════════════════════════════════════════════"
echo " 修补完成：PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "════════════════════════════════════════════════"
exit 0
