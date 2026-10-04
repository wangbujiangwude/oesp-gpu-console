#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 laowang
#
# 本项目原创部分以 MIT 许可发布，详见仓库根目录 LICENSE 文件。
# 第三方代码保留其原始许可，详见 NOTICE 文件。

# -*- coding: utf-8 -*-
"""生成应用图标（纯标准库写 PNG，不依赖 PIL）
设计：fnOS 深色风格 —— 深底 + 圆角 + 绿色 GPU 芯片 + 引脚 + 三条信号线
"""
import zlib
import struct
import os

BG = (23, 29, 36)        # #171d24 面板底色
EDGE = (42, 51, 61)      # #2a333d
GREEN = (63, 185, 80)    # #3fb950
GREEN_D = (30, 110, 48)
BLUE = (88, 166, 255)    # #58a6ff
PURPLE = (188, 140, 255) # #bc8cff


def write_png(path, w, h, px):
    """px: h 行，每行 w 个 (r,g,b)"""
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            raw += bytes(px[y][x])
    comp = zlib.compress(bytes(raw), 9)

    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)

    hdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8bit RGB
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", hdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


def rounded(canvas, x0, y0, x1, y1, r, color):
    """画圆角矩形（用在背景上）"""
    h = len(canvas)
    w = len(canvas[0])
    for y in range(max(0, y0), min(h, y1)):
        for x in range(max(0, x0), min(w, x1)):
            # 四角判断
            cx = cy = None
            if x < x0 + r and y < y0 + r:
                cx, cy = x0 + r, y0 + r
            elif x >= x1 - r and y < y0 + r:
                cx, cy = x1 - r - 1, y0 + r
            elif x < x0 + r and y >= y1 - r:
                cx, cy = x0 + r, y1 - r - 1
            elif x >= x1 - r and y >= y1 - r:
                cx, cy = x1 - r - 1, y1 - r - 1
            if cx is not None:
                if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                    continue
            canvas[y][x] = color


def rect(canvas, x0, y0, x1, y1, color):
    h = len(canvas)
    w = len(canvas[0])
    for y in range(max(0, y0), min(h, y1)):
        for x in range(max(0, x0), min(w, x1)):
            canvas[y][x] = color


def build(size):
    px = [[BG for _ in range(size)] for _ in range(size)]
    rounded(px, 0, 0, size, size, size // 5, (18, 23, 29))

    u = size / 256.0

    def S(v):
        return int(v * u)

    # 芯片主体
    rect(px, S(84), S(78), S(172), S(166), GREEN)
    rect(px, S(84), S(78), S(172), S(88), GREEN_D)      # 顶部暗边
    # 内核
    rect(px, S(104), S(98), S(152), S(146), (18, 23, 29))
    rect(px, S(114), S(108), S(142), S(136), GREEN)
    # 引脚（左右）
    for i in range(5):
        y = S(90 + i * 16)
        rect(px, S(70), y, S(84), y + S(8), EDGE)
        rect(px, S(172), y, S(186), y + S(8), EDGE)
    # 引脚（上下）
    for i in range(5):
        x = S(90 + i * 16)
        rect(px, x, S(64), x + S(8), S(78), EDGE)
        rect(px, x, S(166), x + S(8), S(180), EDGE)
    # 三条信号线（象征 job / vdec / freq 趋势）
    rect(px, S(52), S(198), S(204), S(204), BLUE)
    rect(px, S(52), S(210), S(150), S(216), GREEN)
    rect(px, S(52), S(222), S(180), S(228), PURPLE)
    return px


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p256 = build(256)
    p64 = build(64)
    write_png(os.path.join(here, "ICON.PNG"), 256, 256, p256)
    write_png(os.path.join(here, "ICON_256.PNG"), 256, 256, p256)
    os.makedirs(os.path.join(here, "ui", "images"), exist_ok=True)
    write_png(os.path.join(here, "ui", "images", "icon_256.png"), 256, 256, p256)
    write_png(os.path.join(here, "ui", "images", "icon_64.png"), 64, 64, p64)
    for p in ("ICON.PNG", "ICON_256.PNG", "ui/images/icon_256.png", "ui/images/icon_64.png"):
        print("生成 %s (%d bytes)" % (p, os.path.getsize(os.path.join(here, p))))


if __name__ == "__main__":
    main()
