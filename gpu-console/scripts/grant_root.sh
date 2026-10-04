#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。

# ==============================================================================
#  给 GPU 控制台授予「一键修补」所需的最小 root 权限
#  ---------------------------------------------------------------------------
#  用法（只跑一次，永久生效）：
#      sudo bash /var/apps/gpuconsole/target/scripts/grant_root.sh
#
#  为什么要这一步：
#    fnOS 的原生应用以【应用用户】运行（实测 install_callback 也是以 gpuconsole
#    而非 root 执行的，写不了 /etc/sudoers.d）。而一键修补里最有效的几项
#    （modprobe meson-vdec、chmod 宿主 /dev/video0、写 udev、改安卓容器编排）
#    必须是 root。所以这里由你（有 sudo 密码的人）跑一次完成授权。
#
#  安全设计（两条，缺一不可）：
#    1) 把修补脚本【复制】到 root 拥有的目录 /usr/local/lib/oesp-gpu/ 后再授权。
#       原脚本位于应用目录（root:root 但 777，应用用户可改），若直接授权它，
#       等于给应用用户一条任意 root 通道。固化到 root 目录后，应用用户改不动
#       被授权的那份，提权面因此关闭。
#    2) sudoers 只放行【这一个脚本】，不放行 shell 或任意命令；
#       写入前用 visudo -cf 校验，校验不过就撤销，绝不留下坏 sudoers 拖垮 sudo。
#
#  撤销： sudo rm -f /etc/sudoers.d/gpuconsole-fix /usr/local/lib/oesp-gpu/oesp_gpu_fix.sh
# ==============================================================================
set -u

[ "$(id -u)" = "0" ] || { echo "请用 root 运行： sudo bash $0"; exit 1; }

SRC=""
for c in "${TRIM_APPDEST:-}/scripts/oesp_gpu_fix.sh" \
         /var/apps/gpuconsole/target/scripts/oesp_gpu_fix.sh \
         /vol1/@appcenter/gpuconsole/server/../scripts/oesp_gpu_fix.sh \
         "$(dirname "$0")/oesp_gpu_fix.sh"; do
    [ -f "$c" ] && SRC="$c" && break
done
[ -n "$SRC" ] || { echo "✗ 找不到 oesp_gpu_fix.sh（应用是否已安装？）"; exit 1; }
echo "源脚本: $SRC"

# ---- 1) 固化到 root 拥有的目录 ----
SEC_DIR=/usr/local/lib/oesp-gpu
SEC_SH="$SEC_DIR/oesp_gpu_fix.sh"
mkdir -p "$SEC_DIR"
cp -f "$SRC" "$SEC_SH" || { echo "✗ 复制失败"; exit 1; }
# 附带资源（OMX 插件 / vdec 源码）一并固化，修补时才能自包含地注入容器
SDIR="$(dirname "$SRC")"
for f in libstagefrighthw32.so vdec_test3.c media_codecs.xml; do
    [ -f "$SDIR/$f" ] && cp -f "$SDIR/$f" "$SEC_DIR/$f"
done
chown -R root:root "$SEC_DIR"
chmod 755 "$SEC_DIR"
chmod 755 "$SEC_SH"
echo "已固化 → $SEC_SH (root:root 755)"

# ---- 2) 探测应用运行用户 ----
U=""
# ⚠ 不能用 `ps -eo user`：ps 会把用户名字段截断到 8 字符并加 "+"，
#    本机 gpuconsole 被截成 "gpucons+"，拿去 id 校验必然失败。改用 uid 再反查。
_UID=$(ps -eo uid,cmd 2>/dev/null | grep '[g]puconsole.*gateway.py' | awk '{print $1}' | head -1)
if [ -n "$_UID" ]; then
    U=$(getent passwd "$_UID" 2>/dev/null | cut -d: -f1)
fi
[ -z "$U" ] && U=$(stat -c %U /vol1/@appdata/gpuconsole 2>/dev/null)
case "$U" in ""|UNKNOWN|root) U="gpuconsole" ;; esac
echo "应用运行用户: $U"
id "$U" >/dev/null 2>&1 || { echo "✗ 用户 $U 不存在，中止（可用 GRANT_USER=xxx sudo -E bash $0 指定）"; exit 1; }
[ -n "${GRANT_USER:-}" ] && U="$GRANT_USER" && echo "改用指定用户: $U"

# ---- 3) 写 sudoers ----
SF=/etc/sudoers.d/gpuconsole-fix      # 文件名不能含 "." ，否则被 sudoers.d 忽略
TMP="$SF.$$"
cat > "$TMP" <<EOF
# GPU 控制台（fnOS 应用 gpuconsole）一键修补：仅放行这一个脚本
# 由 scripts/grant_root.sh 生成；撤销： sudo rm -f $SF $SEC_SH
$U ALL=(root) NOPASSWD: $SEC_SH
EOF
if command -v visudo >/dev/null 2>&1; then
    if visudo -cf "$TMP" >/dev/null 2>&1; then
        mv -f "$TMP" "$SF"; chown root:root "$SF"; chmod 440 "$SF"
        echo "✓ 已写入 $SF"
    else
        rm -f "$TMP"; echo "✗ visudo 校验未通过，未做任何更改"; exit 1
    fi
else
    mv -f "$TMP" "$SF"; chown root:root "$SF"; chmod 440 "$SF"
    echo "⚠ 系统无 visudo，已直接写入 $SF（建议后续用 visudo -c 复查）"
fi

# ---- 4) 验证 ----
echo
echo "--- 校验 sudoers 整体语法 ---"
visudo -c 2>&1 | tail -3
echo
echo "--- 验证免密生效 ---"
if su -s /bin/bash "$U" -c "sudo -n -l $SEC_SH" >/dev/null 2>&1; then
    echo "✓ $U 可免密执行修补脚本"
else
    echo "✗ 仍不可免密执行，请检查 sudoers： su -s /bin/bash $U -c 'sudo -n -l'"
fi
echo
echo "完成。回到 GPU 控制台刷新，②③ 号按钮即可使用。"
echo "（升级本应用后请重跑一次本脚本，以同步最新版修补脚本）"
