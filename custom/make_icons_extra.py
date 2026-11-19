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


# ───────────────────────── Liquid Glass (default) ─────────────────────────
GLASS_BARS = [(40, 50, 58), (48, 42, 66), (56, 34, 74), (64, 48, 60), (72, 52, 56)]


def rrect(x, y, w, h, r):
    return ("M%.2f,%.2f h%.2f a%.2f,%.2f 0 0 1 %.2f,%.2f v%.2f a%.2f,%.2f 0 0 1 -%.2f,%.2f "
            "h-%.2f a%.2f,%.2f 0 0 1 -%.2f,-%.2f v-%.2f a%.2f,%.2f 0 0 1 %.2f,-%.2f Z") % (
        x + r, y, w - 2 * r, r, r, r, r, h - 2 * r, r, r, r, r, w - 2 * r, r, r, r, r, h - 2 * r, r, r, r, r)


def glass_pills():
    out = []
    for x, a, b in GLASS_BARS:
        x2 = 54 + (x - 54) * 1.25
        a2 = 54 + (a - 54) * 1.25
        b2 = 54 + (b - 54) * 1.25
        w = 8.6
        out.append((x2 - w / 2, a2 - w / 2, w, b2 - a2 + w))
    return out


def glass():
    bg = '<path android:pathData="M0,0h108v108h-108z">%s</path>' % lin(
        "android:fillColor", [(0, "#FFFF5E7E"), (0.5, "#FFA770EF"), (1, "#FF5B86E5")], 0, 0, 108, 108)
    bg += '<path android:pathData="M0,0h108v108h-108z">%s</path>' % rad(
        "android:fillColor", [(0, "#4DFFFFFF"), (1, "#00FFFFFF")], 30, 22, 70)
    fg = ""
    mono = ""
    for x, y, w, h in glass_pills():
        d = rrect(x, y, w, h, w / 2)
        fg += '<path android:pathData="%s" android:strokeWidth="0.9">%s%s</path>' % (
            d,
            lin("android:fillColor", [(0, "#8CFFFFFF"), (1, "#38FFFFFF")], 0, 30, 0, 80),
            lin("android:strokeColor", [(0, "#FFFFFFFF"), (1, "#59FFFFFF")], 0, 28, 0, 82))
        fg += '<path android:pathData="%s" android:fillColor="#8CFFFFFF"/>' % rrect(x + 1.6, y + 1.4, 2.2, h * 0.55, 1.1)
        mono += '<path android:pathData="%s" android:fillColor="#FF000000"/>' % d
    return bg, fg, mono


ICONS = {"orb": orb, "note": note, "vinyl": vinyl, "borealis": borealis, "glass": glass}

for key, fn in ICONS.items():
    bg, fg, mono = fn()
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

# Liquid Glass is the main launcher icon too.
for name in ("ic_launcher", "ic_launcher_round"):
    write("%s/mipmap-anydpi-v26/%s.xml" % (R, name), HEAD +
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">'
          '<background android:drawable="@drawable/ic_alt_glass_bg"/>'
          '<foreground android:drawable="@drawable/ic_alt_glass_fg"/>'
          '<monochrome android:drawable="@drawable/ic_alt_glass_mono"/></adaptive-icon>\n')

print("Extra app icons generated:", ", ".join(ICONS))
