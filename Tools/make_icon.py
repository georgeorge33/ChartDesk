#!/usr/bin/env python3
"""Draws Resources/AppIcon.png — the 1024pt master the build script turns into an .icns.

Run this only if you want to change the icon; the generated PNG is checked in, and
build.sh does not need Python.
"""

import math
import os
from PIL import Image, ImageDraw

S = 4  # supersample factor
SIZE = 1024 * S


def px(v):
    return int(round(v * S))


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def vertical_gradient(size, top, bottom):
    base = Image.new("RGB", (1, size[1]))
    draw = ImageDraw.Draw(base)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        draw.point((0, y), fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return base.resize(size, Image.NEAREST)


def main():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # --- App icon body: macOS squircle proportions (824pt body inside a 1024pt canvas).
    inset = px(100)
    body_box = (inset, inset, SIZE - inset, SIZE - inset)
    body_radius = px(185)

    gradient = vertical_gradient((SIZE, SIZE), (32, 42, 62), (13, 18, 29)).convert("RGBA")
    canvas.paste(gradient, (0, 0), rounded_mask((SIZE, SIZE), body_box, body_radius))

    draw = ImageDraw.Draw(canvas, "RGBA")

    # Hairline highlight along the top edge, the way system icons catch light.
    draw.rounded_rectangle(body_box, radius=body_radius, outline=(255, 255, 255, 26), width=px(3))

    # --- Chart plate
    page = (px(268), px(206), px(756), px(818))
    shadow = tuple(v + px(10) if i >= 2 else v + px(6) for i, v in enumerate(page))
    draw.rounded_rectangle(shadow, radius=px(26), fill=(0, 0, 0, 70))
    draw.rounded_rectangle(page, radius=px(24), fill=(244, 242, 236, 255))

    left, top, right, bottom = page
    width = right - left

    # Title block
    draw.rectangle((left, top, right, top + px(74)), fill=(28, 33, 46, 255))
    draw.rounded_rectangle(
        (left, top, right, top + px(96)), radius=px(24), fill=(28, 33, 46, 255)
    )
    draw.rectangle((left, top + px(60), right, top + px(96)), fill=(28, 33, 46, 255))
    draw.rectangle(
        (left + px(34), top + px(30), left + px(190), top + px(50)), fill=(236, 238, 243, 255)
    )
    draw.rectangle(
        (right - px(150), top + px(30), right - px(34), top + px(50)), fill=(120, 130, 150, 255)
    )

    # Faint grid
    for i in range(1, 6):
        y = top + px(96) + (bottom - top - px(96)) * i / 6
        draw.line((left + px(26), y, right - px(26), y), fill=(0, 0, 0, 16), width=px(2))
    for i in range(1, 4):
        x = left + width * i / 4
        draw.line((x, top + px(112), x, bottom - px(26)), fill=(0, 0, 0, 16), width=px(2))

    # --- Procedure layer: runway plus the course that feeds it, drawn in one
    # unrotated space so the track is exactly collinear with the runway, then
    # rotated as a unit and clipped to the plate.
    proc = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    pdraw = ImageDraw.Draw(proc, "RGBA")
    cx, cy = px(512), px(474)

    course_start = cy + px(300)
    course_end = cy + px(150)
    pdraw.line((cx, course_start, cx, course_end), fill=(214, 56, 132, 255), width=px(15))

    head = px(52)
    pdraw.polygon(
        [
            (cx, course_end - px(16)),
            (cx - head * 0.58, course_end + head * 0.55),
            (cx + head * 0.58, course_end + head * 0.55),
        ],
        fill=(214, 56, 132, 255),
    )

    fix = px(24)
    pdraw.ellipse(
        (cx - fix, course_start - fix, cx + fix, course_start + fix),
        outline=(214, 56, 132, 255),
        width=px(11),
    )

    pdraw.rounded_rectangle(
        (cx - px(38), cy - px(118), cx + px(38), cy + px(118)),
        radius=px(7),
        fill=(24, 28, 38, 255),
    )
    for i in range(4):
        y0 = cy - px(88) + i * px(56)
        pdraw.line((cx, y0, cx, y0 + px(30)), fill=(244, 242, 236, 255), width=px(9))

    proc = proc.rotate(28, resample=Image.BICUBIC, center=(cx, cy))
    proc.putalpha(
        Image.composite(
            proc.getchannel("A"),
            Image.new("L", (SIZE, SIZE), 0),
            rounded_mask((SIZE, SIZE), page, px(24)),
        )
    )
    canvas.alpha_composite(proc)

    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "AppIcon.png")
    canvas.resize((1024, 1024), Image.LANCZOS).save(path)
    print("wrote", path)


if __name__ == "__main__":
    main()
