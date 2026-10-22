#!/usr/bin/env python3
"""Deterministic UserInfo brand icon (offline, stdlib-only PNG encoder).

Generates one Flutter image asset and native Android launcher icons.
No network, font download, external Python package, or SVG runtime needed.
"""
from __future__ import annotations

import math
import os
import struct
import zlib
from pathlib import Path


def circle(x, y, cx, cy, r):
    return math.hypot(x - cx, y - cy) - r


def box(x, y, cx, cy, w, h, r):
    dx = abs(x - cx) - (w / 2 - r)
    dy = abs(y - cy) - (h / 2 - r)
    return math.hypot(max(dx, 0.0), max(dy, 0.0)) + min(max(dx, dy), 0) - r


def line_segment(x, y, x1, y1, x2, y2):
    vx, vy = x2-x1, y2-y1
    t = max(0.0, min(1.0, ((x-x1)*vx + (y-y1)*vy)/(vx*vx+vy*vy)))
    return math.hypot(x - (x1+t*vx), y - (y1+t*vy))


def lerp(a, b, t):
    return a * (1-t) + b*t


def mix(base, ink, weight):
    a = max(0.0, min(1.0, weight))
    return tuple(round(lerp(base[i], ink[i], a)) for i in range(3))


def blend_shape(rgb, dist, color, feather=0.0020):
    return mix(rgb, color, max(0.0, min(1.0, 0.5-dist/feather)))


def build_icon(size):
    image = bytearray()
    for py in range(size):
        y = (py + 0.5) / size
        row = bytearray([0])
        for px in range(size):
            x = (px + 0.5) / size
            # Cyan to royal blue with a violet lower-right accent.
            t = 0.55*x + 0.65*y
            bg = mix((42, 179, 248), (63, 50, 222), t)
            edge = box(x, y, 0.5, 0.5, 0.97, 0.97, 0.22)
            alpha = max(0, min(255, round((0.5-edge*size)*255)))
            if alpha == 0:
                row.extend((0, 0, 0, 0))
                continue

            rgb = bg
            # Soft navy medallion and a trio of anonymous people.
            rgb = blend_shape(rgb, circle(x, y, 0.49, 0.44, 0.332),
                              (14, 29, 88), 0.004)
            rgb = blend_shape(rgb, circle(x, y, 0.49, 0.44, 0.304),
                              (22, 38, 107), 0.003)
            skin = (236, 245, 255)
            for cx, cy, r in [(0.36,0.39,0.064),(0.52,0.33,0.086),(0.68,0.41,0.061)]:
                rgb = blend_shape(rgb, circle(x,y,cx,cy,r),skin)
            rgb = blend_shape(rgb, box(x,y,0.52,0.59,0.25,0.21,0.105), skin)
            rgb = blend_shape(rgb, box(x,y,0.335,0.572,0.16,0.155,0.08),(213,232,255))
            rgb = blend_shape(rgb, box(x,y,0.702,0.578,0.142,0.145,0.07),(211,231,255))
            # Magnifier on top with deep blue shadow and bright border.
            shadow = line_segment(x,y,0.715,0.74,0.854,0.867) - 0.054
            rgb = blend_shape(rgb, shadow, (19,34,93), 0.005)
            magnifier = abs(circle(x,y,0.667,0.688,0.117)) - 0.035
            rgb = blend_shape(rgb, magnifier,(235,246,255),0.004)
            glass = circle(x,y,0.667,0.688,0.073)
            rgb = blend_shape(rgb,glass,(49,117,217),0.004)
            handle = line_segment(x,y,0.735,0.766,0.845,0.870) - 0.026
            rgb = blend_shape(rgb,handle,(239,248,255),0.005)
            row.extend((*rgb,alpha))
        image.extend(row)
    return bytes(image)


def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack(
        '>I', zlib.crc32(tag + data) & 0xFFFFFFFF)


def png(width, height):
    pixels = build_icon(width)
    header = b'\x89PNG\r\n\x1a\n'
    return (header +
            chunk(b'IHDR', struct.pack('>IIBBBBB',width,height,8,6,0,0,0)) +
            chunk(b'IDAT', zlib.compress(pixels, 7)) +
            chunk(b'IEND', b''))


def main():
    path = Path('assets/brand/userinfo_logo.png')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png(512))
    for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),
                          ('xxhdpi',144),('xxxhdpi',192)]:
        destination = Path('android/app/src/main/res') / (
            'mipmap-' + density) / 'ic_launcher.png'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(png(size))
    print('UserInfo logo and Android icons generated.')


if __name__ == '__main__':
    main()
