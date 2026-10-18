#!/usr/bin/env python3
"""Draws the abstract Mindseerr mark (an eye ringed by curling tentacles) as a transparent PNG.

    python3 make-abstract-mark.py <output.png> [size]      (default size 1024)

Pillow is the only dependency. The mark is drawn at 3x and scaled down for smooth edges.
"""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1]
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
S = 3
N = SIZE * S
C = N / 2
U = N / 1024  # one design unit

def hexc(h, a=255):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))

def vertical_gradient(top, bottom):
    img = Image.new("RGBA", (N, N))
    px = ImageDraw.Draw(img)
    for y in range(N):
        px.line([(0, y), (N, y)], fill=lerp(top, bottom, y / (N - 1)))
    return img

def radial_gradient(inner, outer, radius):
    img = Image.new("RGBA", (N, N), outer)
    steps = 160
    d = ImageDraw.Draw(img)
    for i in range(steps, 0, -1):
        r = radius * i / steps
        d.ellipse([C - r, C - r, C + r, C + r], fill=lerp(inner, outer, i / steps))
    return img

def disc_mask(radius):
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).ellipse([C - radius, C - radius, C + radius, C + radius], fill=255)
    return m

canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

# Outer ring: cyan at the top to violet at the bottom.
ring_outer, ring_inner = 500 * U, 462 * U
ring = vertical_gradient(hexc("#3fd6ff"), hexc("#9b6bff"))
ring_mask = disc_mask(ring_outer)
ring_mask.paste(0, mask=disc_mask(ring_inner))
canvas.paste(ring, mask=ring_mask)

# Night-sky disc inside the ring.
sky = radial_gradient(hexc("#17206b"), hexc("#070a2a"), 462 * U)
canvas.paste(sky, mask=disc_mask(462 * U))

# Eight tentacles: thick at the root, wavy, tapering to a curled tip with a few suckers. Clipped to the disc.
arms = Image.new("RGBA", (N, N), (0, 0, 0, 0))
arm_draw = ImageDraw.Draw(arms)
colors = [hexc("#3d63ff"), hexc("#9a63ff")]
sucker_colors = [hexc("#9fb2ff"), hexc("#e0c9ff")]
count = 8

CURL_START = 0.74   # where the straight-ish body ends and the tip's curl begins

def tentacle_body(base, t):
    """The body's centerline: out from the eye with a gentle S-wave."""
    radius = (140 + 300 * t) * U
    angle = base + 0.5 * t + 0.16 * math.sin(t * math.pi * 2.2)
    return C + radius * math.cos(angle), C + radius * math.sin(angle)

def tentacle_path(base, body_steps=380, curl_steps=90, direction=-1):
    """Body points followed by a tight curl at the tip, each paired with its progress t (0 root to 1 tip)."""
    path = [(tentacle_body(base, CURL_START * i / body_steps), CURL_START * i / body_steps) for i in range(body_steps + 1)]
    (x, y), _ = path[-1]
    (px, py), _ = path[-2]
    heading = math.atan2(y - py, x - px)
    for j in range(1, curl_steps + 1):
        u = j / curl_steps
        heading += direction * (0.02 + 0.075 * u)
        x += 2.3 * U * math.cos(heading)
        y += 2.3 * U * math.sin(heading)
        path.append(((x, y), CURL_START + (1 - CURL_START) * u))
    return path

def tentacle_width(t):
    return (74 * (1 - t) ** 0.85 + 13) * U

def unit_normal(points, i):
    nxt, prev = points[min(i + 1, len(points) - 1)], points[max(i - 1, 0)]
    dx, dy = nxt[0] - prev[0], nxt[1] - prev[1]
    length = math.hypot(dx, dy) or 1
    return -dy / length, dx / length

for k in range(count):
    base = 2 * math.pi * k / count - math.pi / 2
    path = tentacle_path(base)
    points = [pt for pt, _ in path]
    # Stamp overlapping discs along the centerline: a smooth, tapering body with a rounded tip, even where it curls.
    for (x, y), t in path:
        r = tentacle_width(t) / 2
        arm_draw.ellipse([x - r, y - r, x + r, y + r], fill=colors[k % 2])
    # Suckers along the inner edge of the body.
    for t in (0.18, 0.3, 0.42, 0.54, 0.66):
        i = int(t / CURL_START * 380)
        x, y = points[i]
        nx, ny = unit_normal(points, i)
        offset = tentacle_width(t) * 0.18
        r = tentacle_width(t) * 0.17
        sx, sy = x - nx * offset, y - ny * offset
        arm_draw.ellipse([sx - r, sy - r, sx + r, sy + r], fill=sucker_colors[k % 2])
clip = disc_mask(458 * U)
canvas.paste(arms, mask=Image.composite(arms.split()[3], Image.new("L", (N, N), 0), clip))

# The eye: dark socket, glowing iris, pupil and a highlight.
def disc(radius, fill, dx=0, dy=0):
    ImageDraw.Draw(canvas).ellipse([C + dx - radius, C + dy - radius, C + dx + radius, C + dy + radius], fill=fill)

disc(176 * U, hexc("#0a0f45"))
iris = radial_gradient(hexc("#8d6bff"), hexc("#55d6ff"), 128 * U)
canvas.paste(iris, mask=disc_mask(128 * U))
disc(52 * U, hexc("#070a2a"))
disc(24 * U, hexc("#ffffff"), dx=-44 * U, dy=-48 * U)
disc(11 * U, hexc("#ffffff", 220), dx=38 * U, dy=34 * U)

canvas.resize((SIZE, SIZE), Image.LANCZOS).save(OUT)
