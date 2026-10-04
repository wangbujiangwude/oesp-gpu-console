#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。
# ============================================================================
# 自愈脚本完整性守卫（配合 omx_autodeploy.sh，cron 每分钟跑一次）
#
# 事故背景：整机断电重启后主自愈脚本被截断成 0 字节
#           （ext4 元数据已落盘、数据块未落盘），cron 每分钟跑空脚本，
#            插件注入 / 权限硬化 / CMA 守卫全部静默失效，且毫无报错。
#
# 本守卫做三件事，全部只写日志、绝不改业务状态：
#   1) 主脚本为空或语法损坏 -> 从最新备份自动恢复
#   2) 还没有任何基准备份   -> 立即创建一份（否则真出事时无从恢复）
#   3) 备份总数超过 5 份     -> 清理最旧的，避免长期占用
#
# 可用环境变量覆盖：
#   OMX_DIR  工作目录      默认 /root/vdec/omx
#   OMX_SELF 主脚本路径    默认 $OMX_DIR/omx_autodeploy.sh
# ============================================================================
set -u
DIR="${OMX_DIR:-/root/vdec/omx}"
F="${OMX_SELF:-$DIR/omx_autodeploy.sh}"
LOG=$DIR/autodeploy.log
mkdir -p "$DIR" 2>/dev/null

B=$(ls -t "$DIR"/omx_autodeploy.sh.bak.* 2>/dev/null | head -1)

# ---- 1) 还没有基准备份 -> 立刻建一份（前提：当前主脚本是健康的）----
if [ -z "${B:-}" ] && [ -s "$F" ] && bash -n "$F" 2>/dev/null; then
    cp -a "$F" "$F.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    echo "$(date '+%F %T') [guard] 已建立基准备份" >> "$LOG"
    B=$(ls -t "$DIR"/omx_autodeploy.sh.bak.* 2>/dev/null | head -1)
fi

# ---- 2) 主脚本损坏 -> 恢复 ----
if [ ! -s "$F" ]; then
    if [ -n "${B:-}" ]; then
        cp -a "$B" "$F"; chmod 755 "$F"
        echo "$(date '+%F %T') [guard] 主脚本为空（断电截断？）-> 已从 $B 恢复" >> "$LOG"
    else
        echo "$(date '+%F %T') [guard] 主脚本为空且找不到备份！" >> "$LOG"
    fi
elif ! bash -n "$F" 2>/dev/null; then
    if [ -n "${B:-}" ]; then
        cp -a "$B" "$F"; chmod 755 "$F"
        echo "$(date '+%F %T') [guard] 主脚本语法损坏 -> 已从 $B 恢复" >> "$LOG"
    else
        echo "$(date '+%F %T') [guard] 主脚本语法损坏且找不到备份！" >> "$LOG"
    fi
fi

# ---- 3) 备份轮转：只留最近 5 份 ----
CNT=$(ls -1 "$DIR"/omx_autodeploy.sh.bak.* 2>/dev/null | wc -l | tr -dc '0-9')
if [ "${CNT:-0}" -gt 5 ]; then
    ls -t "$DIR"/omx_autodeploy.sh.bak.* 2>/dev/null | tail -n +6 | while read -r old; do
        rm -f "$old" 2>/dev/null
    done
fi
exit 0
