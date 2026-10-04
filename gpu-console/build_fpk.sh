#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。

# ==============================================================================
#  GPU 控制台 · FPK 打包脚本
#
#  FPK 包格式（实测确认）：
#     .fpk 就是一个 gzip 压缩的 tar 包（tar.gz 改名），内部结构：
#       manifest          ← 应用元信息（key = value 文本）
#       ICON.PNG          256x256 图标
#       ICON_256.PNG      同上
#       LICENSE
#       cmd/              生命周期钩子（install_init/install_callback/uninstall_*/upgrade_*/config_*/main）
#       config/           privilege（权限）resource（资源需求，无 docker 时为 {}）
#       wizard/           install（安装向导 JSON）
#       app.tgz           ← 应用主体（再一层 tar.gz）：server/ ui/ scripts/
#
#  用法： bash build_fpk.sh
#  产物： ../gpuconsole_<version>.fpk
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"

APPNAME=$(sed -n 's/^appname *=[[:space:]]*//p' manifest | head -1)
VERSION=$(sed -n 's/^version *=[[:space:]]*//p' manifest | head -1)
OUT="../${APPNAME}_${VERSION}.fpk"

echo "=== 打包 $APPNAME $VERSION ==="

# ---- 0. 修正权限（从 Windows 传过来会丢可执行位）----
chmod +x cmd/* 2>/dev/null || true
chmod +x scripts/*.sh 2>/dev/null || true
chmod +x server/gateway.py 2>/dev/null || true
chmod +x make_icon.py 2>/dev/null || true

# ---- 0b. 统一行尾为 LF（关键）----
# 在 Windows 上编辑过的 .sh 会带 CRLF，shebang 行变成 "#!/bin/bash\r"，
# 内核按 "/bin/bash\r" 找解释器 → 直接执行时报
#   "sudo: unable to execute xxx.sh: No such file or directory"
# （用 `bash xxx.sh` 显式调用时不暴露，所以很容易漏）。必须转成 LF。
CRLF=0
for f in cmd/* scripts/*.sh; do
    [ -f "$f" ] || continue
    if grep -qU $'\r' "$f" 2>/dev/null; then
        sed -i 's/\r$//' "$f"
        CRLF=$((CRLF + 1))
    fi
done
[ "$CRLF" -gt 0 ] && echo "  [OK] 已将 $CRLF 个脚本从 CRLF 转为 LF" \
                  || echo "  [OK] 脚本行尾均为 LF"

# ---- 1. 图标（缺了自动生成）----
if [ ! -f ICON.PNG ]; then
  echo "--- 生成图标 ---"
  python3 make_icon.py || python make_icon.py
fi

# ---- 2. 语法自检 ----
echo "--- 自检 ---"
if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile server/gateway.py && echo "  [OK] gateway.py 语法正确"
  rm -rf server/__pycache__
fi
for f in manifest; do
  [ -f "$f" ] && echo "  [OK] $f" || { echo "  [FAIL] 缺 $f"; exit 1; }
done
for f in cmd/main cmd/install_callback config/privilege ui/config wizard/install app.tgz; do
  [ -e "$f" ] || echo "  [..] $f 将由脚本生成"
done

# ---- 3. 打 app.tgz（应用主体）----
echo "--- 生成 app.tgz（应用主体）---"
rm -f app.tgz
tar czf app.tgz server ui scripts LICENSE 2>/dev/null || tar czf app.tgz server ui scripts
echo "  app.tgz: $(stat -c%s app.tgz 2>/dev/null || wc -c < app.tgz) bytes"

# ---- 4. 写 checksum ----
# 实测 fnOS 的 checksum 是 32 位十六进制。这里用 app.tgz 的 md5。
if command -v md5sum >/dev/null 2>&1; then
  CK=$(md5sum app.tgz | cut -d' ' -f1)
else
  CK=$(md5 -q app.tgz)
fi
echo "--- 写入 checksum: $CK ---"
sed -i "s/^checksum *=[[:space:]]*.*/checksum                   = $CK/" manifest

# ---- 5. 打最终 fpk（顶层目录结构）----
echo "--- 生成 $OUT ---"
rm -f "$OUT"
tar czf "$OUT" manifest ICON.PNG ICON_256.PNG LICENSE cmd config wizard app.tgz

echo
echo "=== 完成 ==="
ls -l "$OUT" | awk '{print "  文件: "$9"\n  大小: "$5" bytes"}'
echo
echo "--- 包内结构 ---"
tar tzf "$OUT" | sed 's/^/  /'
echo
echo "--- app.tgz 内容 ---"
tar tzf app.tgz | sed 's/^/  /'
