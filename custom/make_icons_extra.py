#!/usr/bin/env python3
"""Generates the drawn-in-code launcher icons (Orb, Note, Vinyl, Borealis).

Everything here is plain vector math written out as Android vector drawables.
There are no image files. The same shapes are drawn by AppIconPainter in
main.dart (the in-app picker and launch animation), so both always match.

Usage: make_icons_extra.py <path to android res folder>
"""
import math
import os
import sys

R = sys.argv[1] if len(sys.argv) > 1 else "res"
HEAD = '<?xml version="1.0" encoding="utf-8"?>\n'
NS = ('xmlns:android="http://schemas.android.com/apk/res/android" '
      'xmlns:aapt="http://schemas.android.com/aapt"')


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def vec(body):
    return (HEAD + '<vector %s android:width="108dp" android:height="108dp" '
            'android:viewportWidth="108" android:viewportHeight="108">%s</vector>\n' % (NS, body))


def items(stops):
    return "".join('<item android:offset="%.3f" android:color="%s"/>' % (o, c) for o, c in stops)


def lin(attr, stops, x1, y1, x2, y2):
    return ('<aapt:attr name="%s"><gradient android:type="linear" android:startX="%s" android:startY="%s" '
            'android:endX="%s" android:endY="%s">%s</gradient></aapt:attr>') % (attr, x1, y1, x2, y2, items(stops))


def rad(attr, stops, cx, cy, r):
    return ('<aapt:attr name="%s"><gradient android:type="radial" android:centerX="%s" android:centerY="%s" '
            'android:gradientRadius="%s">%s</gradient></aapt:attr>') % (attr, cx, cy, r, items(stops))


def sweep(attr, stops, cx, cy):
    return ('<aapt:attr name="%s"><gradient android:type="sweep" android:centerX="%s" android:centerY="%s">'
            '%s</gradient></aapt:attr>') % (attr, cx, cy, items(stops))


def circle(cx, cy, r):
    return "M%.2f,%.2f a%.2f,%.2f 0 1,0 %.2f,0 a%.2f,%.2f 0 1,0 -%.2f,0 Z" % (cx - r, cy, r, r, 2 * r, r, r, 2 * r)


def evenly(cols):
    return [(i / (len(cols) - 1), c) for i, c in enumerate(cols)]


# ───────────────────────── Orb ─────────────────────────
def orb():
    bg = '<path android:pathData="M0,0h108v108h-108z">%s</path>' % lin(
        "android:fillColor", [(0, "#FF03040A"), (1, "#FF090712")], 0, 0, 108, 108)
    ring_grad = [(0, "#B322D3EE"), (0.5, "#B38B5CF6"), (1, "#B3F472B6")]
    fg = '<group android:rotation="-24" android:pivotX="54" android:pivotY="54">'
    fg += '<path android:pathData="M20,54 A34,10 0 0 1 88,54" android:strokeWidth="1.8" android:fillColor="#00000000">%s</path>' % lin(
        "android:strokeColor", ring_grad, 20, 54, 88, 54)
    fg += '</group>'
    # soft halo, sphere, shade, highlight
    fg += '<path android:pathData="%s">%s</path>' % (circle(54, 54, 28), rad(
        "android:fillColor", [(0, "#00A855F7"), (0.78, "#59A855F7"), (1, "#00A855F7")], 54, 54, 28))
    fg += '<path android:pathData="%s">%s</path>' % (circle(54, 54, 22), rad(
        "android:fillColor",
        [(0, "#FFCFEFFF"), (0.2, "#FF38BDF8"), (0.5, "#FF6366F1"), (0.75, "#FFA855F7"), (0.95, "#FFEC4899")],
        45.2, 43, 37.4))
    fg += '<path android:pathData="%s">%s</path>' % (circle(54, 54, 22), rad(
        "android:fillColor", [(0, "#00050514"), (0.55, "#00050514"), (1, "#99050514")], 45.2, 43, 37.4))
    fg += '<path android:pathData="%s">%s</path>' % (circle(44, 42, 7), rad(
        "android:fillColor", [(0, "#CCFFFFFF"), (1, "#00FFFFFF")], 44, 42, 7))
    fg += '<group android:rotation="-24" android:pivotX="54" android:pivotY="54">'
    fg += '<path android:pathData="M20,54 A34,10 0 0 0 88,54" android:strokeWidth="4.6" android:strokeColor="#408B5CF6" android:fillColor="#00000000"/>'
    fg += '<path android:pathData="M20,54 A34,10 0 0 0 88,54" android:strokeWidth="1.9" android:strokeColor="#FFEAF4FF" android:fillColor="#00000000"/>'
    fg += '</group>'
    mono = '<path android:pathData="%s" android:fillColor="#FF000000"/>' % circle(54, 54, 22)
    mono += '<group android:rotation="-24" android:pivotX="54" android:pivotY="54"><path android:pathData="M20,54 A34,10 0 1 0 88,54 A34,10 0 1 0 20,54" android:strokeWidth="2.2" android:strokeColor="#FF000000" android:fillColor="#00000000"/></group>'
    return bg, fg, mono


# ───────────────────────── Note ─────────────────────────
def bezier(p0, p1, p2, p3, t):
    u = 1 - t
    return (u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
            u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1])


def note_flag():
    """Tapered curved flag as a polygon. Mirrored in AppIconPainter."""
    p0, p1, p2, p3 = (55.6, 31.0), (57.0, 43.0), (74.0, 43.0), (65.0, 61.0)
    n = 40
    left, right = [], []
    for i in range(n + 1):
        t = i / n
        x, y = bezier(p0, p1, p2, p3, t)
        x2, y2 = bezier(p0, p1, p2, p3, min(1.0, t + 0.001))
        x1, y1 = bezier(p0, p1, p2, p3, max(0.0, t - 0.001))
        dx, dy = x2 - x1, y2 - y1
        ln = math.hypot(dx, dy) or 1
        nx, ny = -dy / ln, dx / ln
        w = (5.6 * (1 - t) + 1.2) / 2
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    pts = left + right[::-1]
    return "M" + " L".join("%.2f,%.2f" % p for p in pts) + " Z"


def note():
    bg = '<path android:pathData="M0,0h108v108h-108z">%s</path>' % lin(
        "android:fillColor", [(0, "#FF2A0E5C"), (0.5, "#FFC026D3"), (1, "#FFFB7185")], 0, 0, 108, 108)
    shapes = ('<group android:rotation="-20" android:pivotX="41" android:pivotY="69">'
              '<path android:pathData="%s" android:fillColor="#FFFFFFFF"/></group>'
              '<path android:pathData="M51,31 h4.6 v40 h-4.6 z" android:fillColor="#FFFFFFFF"/>'
              '<path android:pathData="%s" android:fillColor="#FFFFFFFF"/>') % (
        "M29.5,69 a11.5,8 0 1,0 23,0 a11.5,8 0 1,0 -23,0 Z", note_flag())
    fg = '<group android:translateX="4">%s</group>' % shapes
    mono = '<group android:translateX="4">%s</group>' % shapes.replace("#FFFFFFFF", "#FF000000")
    return bg, fg, mono


# ───────────────────────── Vinyl ─────────────────────────
VINYL_SWEEP = ["#22D3EE", "#6366F1", "#A855F7", "#EC4899", "#A855F7", "#6366F1", "#22D3EE"]


def wedge(center_angle, half=0.28, r=33.0):
    a0, a1 = center_angle - half, center_angle + half
    x0, y0 = 54 + r * math.cos(a0), 54 + r * math.sin(a0)
    x1, y1 = 54 + r * math.cos(a1), 54 + r * math.sin(a1)
    return "M54,54 L%.2f,%.2f A%.1f,%.1f 0 0 1 %.2f,%.2f Z" % (x0, y0, r, r, x1, y1)


def vinyl():
    bg = '<path android:pathData="M0,0h108v108h-108z">%s</path>' % lin(
        "android:fillColor", [(0, "#FF04050C"), (1, "#FF0A0C1C")], 0, 0, 108, 108)
    fg = '<path android:pathData="%s" android:fillColor="#FF0C0D1A"/>' % circle(54, 54, 33)
    fg += '<group android:rotation="34.4" android:pivotX="54" android:pivotY="54">'
    for r in (30, 26.5, 23, 19.5):
        fg += '<path android:pathData="%s" android:strokeWidth="0.9" android:fillColor="#00000000">%s</path>' % (
            circle(54, 54, r), sweep("android:strokeColor", evenly(["#FF" + c[1:] for c in VINYL_SWEEP]), 54, 54))
    fg += '</group>'
    for a in (-0.9, 2.24):
        fg += '<path android:pathData="%s" android:fillColor="#1FFFFFFF"/>' % wedge(a)
    fg += '<path android:pathData="%s">%s</path>' % (circle(54, 54, 11), lin(
        "android:fillColor", [(0, "#FF22D3EE"), (0.5, "#FF8B5CF6"), (1, "#FFEC4899")], 43, 43, 65, 65))
    fg += '<path android:pathData="%s" android:fillColor="#FF060710"/>' % circle(54, 54, 2.7)
    mono = '<path android:pathData="%s" android:fillColor="#FF000000"/>' % circle(54, 54, 11)
    for r in (30, 25, 20):
        mono += '<path android:pathData="%s" android:strokeWidth="1.6" android:strokeColor="#FF000000" android:fillColor="#00000000"/>' % circle(54, 54, r)
    return bg, fg, mono


# ───────────────────────── Borealis ─────────────────────────
RIBBONS = [("#22D3EE", "#6366F1", 0.0, 0.90), ("#8B5CF6", "#EC4899", 1.1, 0.80), ("#34D399", "#22D3EE", 2.2, 0.60)]
STARS = [(36, 34), (48, 30), (62, 32), (74, 36), (30, 42), (80, 44), (54, 38), (68, 28)]


def ribbon_points(ph):
    top, bot = [], []
    for i in range(81):
        u = i / 80
        x = 22 + 64 * u
        env = math.sin(math.pi * u) ** 0.9
        y = 56 + 9 * math.sin(u * math.pi * 2.2 + ph) * env
        th = 3.5 + 6 * env
        top.append((x, y - th))
        bot.append((x, y + th))
    return top + bot[::-1]


def alpha(hexc, a):
    return "#%02X%s" % (int(round(a * 255)), hexc[1:])


def borealis():
    bg = '<path android:pathData="M0,0h108v108h-108z">%s</path>' % lin(
        "android:fillColor", [(0, "#FF04060E"), (1, "#FF080A1C")], 0, 0, 108, 108)
    fg = ""
    for x, y in STARS:
        fg += '<path android:pathData="%s" android:fillColor="#B3FFFFFF"/>' % circle(x, y, 0.8)
    mono = ""
    for c1, c2, ph, op in RIBBONS:
        pts = ribbon_points(ph)
        d = "M" + " L".join("%.2f,%.2f" % p for p in pts) + " Z"
        fg += '<path android:pathData="%s">%s</path>' % (d, lin(
            "android:fillColor",
            [(0, alpha(c1, 0)), (0.22, alpha(c1, op)), (0.78, alpha(c2, op)), (1, alpha(c2, 0))], 22, 0, 86, 0))
        mono += '<path android:pathData="%s" android:fillColor="#99000000"/>' % d
    return bg, fg, mono



# ───────────── Pixel (default bitLMP icon): BIT / LMP with a cursor ─────────────
PIXEL_RECTS = [
    (31.05, 32.40, 2.70, 2.70, 0),
    (33.75, 32.40, 2.70, 2.70, 0),
    (36.45, 32.40, 2.70, 2.70, 0),
    (39.15, 32.40, 2.70, 2.70, 0),
    (31.05, 35.10, 2.70, 2.70, 0),
    (41.85, 35.10, 2.70, 2.70, 0),
    (31.05, 37.80, 2.70, 2.70, 0),
    (41.85, 37.80, 2.70, 2.70, 0),
    (31.05, 40.50, 2.70, 2.70, 0),
    (33.75, 40.50, 2.70, 2.70, 0),
    (36.45, 40.50, 2.70, 2.70, 0),
    (39.15, 40.50, 2.70, 2.70, 0),
    (31.05, 43.20, 2.70, 2.70, 0),
    (41.85, 43.20, 2.70, 2.70, 0),
    (31.05, 45.90, 2.70, 2.70, 0),
    (41.85, 45.90, 2.70, 2.70, 0),
    (31.05, 48.60, 2.70, 2.70, 0),
    (33.75, 48.60, 2.70, 2.70, 0),
    (36.45, 48.60, 2.70, 2.70, 0),
    (39.15, 48.60, 2.70, 2.70, 0),
    (47.25, 32.40, 2.70, 2.70, 0),
    (49.95, 32.40, 2.70, 2.70, 0),
    (52.65, 32.40, 2.70, 2.70, 0),
    (55.35, 32.40, 2.70, 2.70, 0),
    (58.05, 32.40, 2.70, 2.70, 0),
    (52.65, 35.10, 2.70, 2.70, 0),
    (52.65, 37.80, 2.70, 2.70, 0),
    (52.65, 40.50, 2.70, 2.70, 0),
    (52.65, 43.20, 2.70, 2.70, 0),
    (52.65, 45.90, 2.70, 2.70, 0),
    (47.25, 48.60, 2.70, 2.70, 0),
    (49.95, 48.60, 2.70, 2.70, 0),
    (52.65, 48.60, 2.70, 2.70, 0),
    (55.35, 48.60, 2.70, 2.70, 0),
    (58.05, 48.60, 2.70, 2.70, 0),
    (63.45, 32.40, 2.70, 2.70, 0),
    (66.15, 32.40, 2.70, 2.70, 0),
    (68.85, 32.40, 2.70, 2.70, 0),
    (71.55, 32.40, 2.70, 2.70, 0),
    (74.25, 32.40, 2.70, 2.70, 0),
    (68.85, 35.10, 2.70, 2.70, 0),
    (68.85, 37.80, 2.70, 2.70, 0),
    (68.85, 40.50, 2.70, 2.70, 0),
    (68.85, 43.20, 2.70, 2.70, 0),
    (68.85, 45.90, 2.70, 2.70, 0),
    (68.85, 48.60, 2.70, 2.70, 0),
    (31.05, 56.70, 2.70, 2.70, 1),
    (31.05, 59.40, 2.70, 2.70, 1),
    (31.05, 62.10, 2.70, 2.70, 1),
    (31.05, 64.80, 2.70, 2.70, 1),
    (31.05, 67.50, 2.70, 2.70, 1),
    (31.05, 70.20, 2.70, 2.70, 1),
    (31.05, 72.90, 2.70, 2.70, 1),
    (33.75, 72.90, 2.70, 2.70, 1),
    (36.45, 72.90, 2.70, 2.70, 1),
    (39.15, 72.90, 2.70, 2.70, 1),
    (41.85, 72.90, 2.70, 2.70, 1),
    (47.25, 56.70, 2.70, 2.70, 1),
    (58.05, 56.70, 2.70, 2.70, 1),
    (47.25, 59.40, 2.70, 2.70, 1),
    (49.95, 59.40, 2.70, 2.70, 1),
    (55.35, 59.40, 2.70, 2.70, 1),
    (58.05, 59.40, 2.70, 2.70, 1),
    (47.25, 62.10, 2.70, 2.70, 1),
    (52.65, 62.10, 2.70, 2.70, 1),
    (58.05, 62.10, 2.70, 2.70, 1),
    (47.25, 64.80, 2.70, 2.70, 1),
    (52.65, 64.80, 2.70, 2.70, 1),
    (58.05, 64.80, 2.70, 2.70, 1),
    (47.25, 67.50, 2.70, 2.70, 1),
    (58.05, 67.50, 2.70, 2.70, 1),
    (47.25, 70.20, 2.70, 2.70, 1),
    (58.05, 70.20, 2.70, 2.70, 1),
    (47.25, 72.90, 2.70, 2.70, 1),
    (58.05, 72.90, 2.70, 2.70, 1),
    (63.45, 56.70, 2.70, 2.70, 1),
    (66.15, 56.70, 2.70, 2.70, 1),
    (68.85, 56.70, 2.70, 2.70, 1),
    (71.55, 56.70, 2.70, 2.70, 1),
    (63.45, 59.40, 2.70, 2.70, 1),
    (74.25, 59.40, 2.70, 2.70, 1),
    (63.45, 62.10, 2.70, 2.70, 1),
    (74.25, 62.10, 2.70, 2.70, 1),
    (63.45, 64.80, 2.70, 2.70, 1),
    (66.15, 64.80, 2.70, 2.70, 1),
    (68.85, 64.80, 2.70, 2.70, 1),
    (71.55, 64.80, 2.70, 2.70, 1),
    (63.45, 67.50, 2.70, 2.70, 1),
    (63.45, 70.20, 2.70, 2.70, 1),
    (63.45, 72.90, 2.70, 2.70, 1),
    (57.30, 54.00, 1.20, 3.00, 2),
    (60.50, 51.90, 1.20, 3.00, 2),
    (54.70, 57.50, 3.00, 1.20, 2),
    (61.50, 58.50, 1.22, 1.22, 3),
    (61.50, 59.70, 1.22, 1.22, 3),
    (62.70, 59.70, 1.22, 1.22, 3),
    (61.50, 60.90, 1.22, 1.22, 3),
    (62.70, 60.90, 1.22, 1.22, 4),
    (63.90, 60.90, 1.22, 1.22, 3),
    (61.50, 62.10, 1.22, 1.22, 3),
    (62.70, 62.10, 1.22, 1.22, 4),
    (63.90, 62.10, 1.22, 1.22, 4),
    (65.10, 62.10, 1.22, 1.22, 3),
    (61.50, 63.30, 1.22, 1.22, 3),
    (62.70, 63.30, 1.22, 1.22, 4),
    (63.90, 63.30, 1.22, 1.22, 4),
    (65.10, 63.30, 1.22, 1.22, 4),
    (66.30, 63.30, 1.22, 1.22, 3),
    (61.50, 64.50, 1.22, 1.22, 3),
    (62.70, 64.50, 1.22, 1.22, 4),
    (63.90, 64.50, 1.22, 1.22, 4),
    (65.10, 64.50, 1.22, 1.22, 4),
    (66.30, 64.50, 1.22, 1.22, 4),
    (67.50, 64.50, 1.22, 1.22, 3),
    (61.50, 65.70, 1.22, 1.22, 3),
    (62.70, 65.70, 1.22, 1.22, 4),
    (63.90, 65.70, 1.22, 1.22, 4),
    (65.10, 65.70, 1.22, 1.22, 4),
    (66.30, 65.70, 1.22, 1.22, 4),
    (67.50, 65.70, 1.22, 1.22, 4),
    (68.70, 65.70, 1.22, 1.22, 3),
    (61.50, 66.90, 1.22, 1.22, 3),
    (62.70, 66.90, 1.22, 1.22, 4),
    (63.90, 66.90, 1.22, 1.22, 4),
    (65.10, 66.90, 1.22, 1.22, 4),
    (66.30, 66.90, 1.22, 1.22, 4),
    (67.50, 66.90, 1.22, 1.22, 4),
    (68.70, 66.90, 1.22, 1.22, 4),
    (69.90, 66.90, 1.22, 1.22, 3),
    (61.50, 68.10, 1.22, 1.22, 3),
    (62.70, 68.10, 1.22, 1.22, 4),
    (63.90, 68.10, 1.22, 1.22, 4),
    (65.10, 68.10, 1.22, 1.22, 4),
    (66.30, 68.10, 1.22, 1.22, 4),
    (67.50, 68.10, 1.22, 1.22, 4),
    (68.70, 68.10, 1.22, 1.22, 4),
    (69.90, 68.10, 1.22, 1.22, 4),
    (71.10, 68.10, 1.22, 1.22, 3),
    (61.50, 69.30, 1.22, 1.22, 3),
    (62.70, 69.30, 1.22, 1.22, 4),
    (63.90, 69.30, 1.22, 1.22, 4),
    (65.10, 69.30, 1.22, 1.22, 4),
    (66.30, 69.30, 1.22, 1.22, 4),
    (67.50, 69.30, 1.22, 1.22, 4),
    (68.70, 69.30, 1.22, 1.22, 3),
    (69.90, 69.30, 1.22, 1.22, 3),
    (71.10, 69.30, 1.22, 1.22, 3),
    (72.30, 69.30, 1.22, 1.22, 3),
    (61.50, 70.50, 1.22, 1.22, 3),
    (62.70, 70.50, 1.22, 1.22, 4),
    (63.90, 70.50, 1.22, 1.22, 4),
    (65.10, 70.50, 1.22, 1.22, 3),
    (66.30, 70.50, 1.22, 1.22, 4),
    (67.50, 70.50, 1.22, 1.22, 4),
    (68.70, 70.50, 1.22, 1.22, 3),
    (61.50, 71.70, 1.22, 1.22, 3),
    (62.70, 71.70, 1.22, 1.22, 4),
    (63.90, 71.70, 1.22, 1.22, 3),
    (66.30, 71.70, 1.22, 1.22, 3),
    (67.50, 71.70, 1.22, 1.22, 4),
    (68.70, 71.70, 1.22, 1.22, 4),
    (69.90, 71.70, 1.22, 1.22, 3),
    (61.50, 72.90, 1.22, 1.22, 3),
    (62.70, 72.90, 1.22, 1.22, 3),
    (66.30, 72.90, 1.22, 1.22, 3),
    (67.50, 72.90, 1.22, 1.22, 4),
    (68.70, 72.90, 1.22, 1.22, 4),
    (69.90, 72.90, 1.22, 1.22, 3),
    (61.50, 74.10, 1.22, 1.22, 3),
    (67.50, 74.10, 1.22, 1.22, 3),
    (68.70, 74.10, 1.22, 1.22, 4),
    (69.90, 74.10, 1.22, 1.22, 4),
    (71.10, 74.10, 1.22, 1.22, 3),
    (67.50, 75.30, 1.22, 1.22, 3),
    (68.70, 75.30, 1.22, 1.22, 4),
    (69.90, 75.30, 1.22, 1.22, 4),
    (71.10, 75.30, 1.22, 1.22, 3),
    (68.70, 76.50, 1.22, 1.22, 3),
    (69.90, 76.50, 1.22, 1.22, 3),
]
PIXEL_GEAR = "M77.52,56.77 L76.14,61.27 L69.53,62.46 L67.19,65.29 L67.26,72.00 L63.10,74.21 L57.59,70.37 L53.93,70.72 L49.23,75.52 L44.73,74.14 L43.54,67.53 L40.71,65.19 L34.00,65.26 L31.79,61.10 L35.63,55.59 L35.28,51.93 L30.48,47.23 L31.86,42.73 L38.47,41.54 L40.81,38.71 L40.74,32.00 L44.90,29.79 L50.41,33.63 L54.07,33.28 L58.77,28.48 L63.27,29.86 L64.46,36.47 L67.29,38.81 L74.00,38.74 L76.21,42.90 L72.37,48.41 L72.72,52.07 Z M44.88,52.00 a9.12,9.12 0 1 0 18.24,0 a9.12,9.12 0 1 0 -18.24,0 Z"
PIXEL_COLS = ["#FFE4E4E4", "#FF5BDDE3", "#FF262426", "#FF111111", "#FFFFFFFF"]


def _pix_paths(colour_of):
    by = {}
    for x, y, w, h, c in PIXEL_RECTS:
        by.setdefault(colour_of(c), []).append("M%.2f,%.2f h%.2f v%.2f h-%.2f Z" % (x, y, w, h, w))
    return "".join('<path android:pathData="%s" android:fillColor="%s"/>' % ("".join(d), col) for col, d in by.items())


def pixel():
    bg = '<path android:pathData="M0,0h108v108h-108z" android:fillColor="#FF262426"/>'
    bg += '<path android:pathData="%s" android:fillType="evenOdd" android:fillColor="#FF2F2D30"/>' % PIXEL_GEAR
    fg = _pix_paths(lambda c: PIXEL_COLS[c])
    # Themed icon: the letters and cursor only.
    mono = "".join('<path android:pathData="M%.2f,%.2f h%.2f v%.2f h-%.2f Z" android:fillColor="#FF000000"/>' % (x, y, w, h, w)
                   for x, y, w, h, c in PIXEL_RECTS if c != 2)
    return bg, fg, mono

ICONS = {"orb": orb, "note": note, "vinyl": vinyl, "borealis": borealis, "pixel": pixel}

def _rr(x, y, w, h, r):
    return ("M%.2f,%.2f h%.2f a%.2f,%.2f 0 0 1 %.2f,%.2f v%.2f a%.2f,%.2f 0 0 1 -%.2f,%.2f "
            "h-%.2f a%.2f,%.2f 0 0 1 -%.2f,-%.2f v-%.2f a%.2f,%.2f 0 0 1 %.2f,-%.2f Z") % (
        x + r, y, w - 2 * r, r, r, r, r, h - 2 * r, r, r, r, r, w - 2 * r, r, r, r, r, h - 2 * r, r, r, r, r)


# bitLMP mark: a white disc with three sound bars cut out of it.
MARK = "M54,27 a27,27 0 1 1 0,54 a27,27 0 1 1 0,-54 Z" + "".join(
    _rr(x - 2.8, 54 - hh - 2.8, 5.6, 2 * hh + 5.6, 2.8) for x, hh in [(45, 7), (54, 12), (63, 9)])

for key, fn in ICONS.items():
    bg, fg, mono = fn()
    if key != "pixel":
        fg = '<path android:pathData="%s" android:fillType="evenOdd" android:fillColor="#FFFFFFFF"/>' % MARK
        mono = '<path android:pathData="%s" android:fillType="evenOdd" android:fillColor="#FF000000"/>' % MARK
    write("%s/drawable/ic_alt_%s_bg.xml" % (R, key), vec(bg))
    write("%s/drawable/ic_alt_%s_fg.xml" % (R, key), vec(fg))
    write("%s/drawable/ic_alt_%s_mono.xml" % (R, key), vec(mono))
    write("%s/mipmap-anydpi-v26/ic_alt_%s.xml" % (R, key), HEAD +
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">'
          '<background android:drawable="@drawable/ic_alt_%s_bg"/>'
          '<foreground android:drawable="@drawable/ic_alt_%s_fg"/>'
          '<monochrome android:drawable="@drawable/ic_alt_%s_mono"/></adaptive-icon>\n' % (key, key, key))
    write("%s/mipmap-anydpi/ic_alt_%s.xml" % (R, key), HEAD +
          '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">'
          '<item android:drawable="@drawable/ic_alt_%s_bg"/>'
          '<item android:drawable="@drawable/ic_alt_%s_fg"/></layer-list>\n' % (key, key))

# Bloom is the main launcher icon.
for name in ("ic_launcher", "ic_launcher_round"):
    write("%s/mipmap-anydpi-v26/%s.xml" % (R, name), HEAD +
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">'
          '<background android:drawable="@drawable/ic_alt_bloom_bg"/>'
          '<foreground android:drawable="@drawable/ic_alt_bloom_fg"/>'
          '<monochrome android:drawable="@drawable/ic_alt_mono"/></adaptive-icon>\n')

print("Extra app icons generated:", ", ".join(ICONS))
