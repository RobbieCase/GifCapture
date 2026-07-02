#!/usr/bin/env python3
"""Generates GifCapture's app icon: a rounded-square gradient with a bold 'GC' mark."""
import math
import os

from PIL import Image, ImageDraw, ImageFont

CANVAS = 1024
CORNER_RADIUS = 224  # ~macOS "squircle" proportions at 1024px
FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"

TOP_COLOR = (108, 99, 255)     # indigo
BOTTOM_COLOR = (43, 130, 255)  # blue
DOT_COLOR = (255, 69, 58)      # recording red

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ICONSET_DIR = os.path.join(SCRIPT_DIR, "..", "Resources", "AppIcon.iconset")
ICNS_PATH = os.path.join(SCRIPT_DIR, "..", "Resources", "AppIcon.icns")


def make_base_icon() -> Image.Image:
    base = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    gradient = Image.new("RGB", (1, CANVAS), color=0)
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        r = round(TOP_COLOR[0] + (BOTTOM_COLOR[0] - TOP_COLOR[0]) * t)
        g = round(TOP_COLOR[1] + (BOTTOM_COLOR[1] - TOP_COLOR[1]) * t)
        b = round(TOP_COLOR[2] + (BOTTOM_COLOR[2] - TOP_COLOR[2]) * t)
        gradient.putpixel((0, y), (r, g, b))
    gradient = gradient.resize((CANVAS, CANVAS))

    mask = Image.new("L", (CANVAS, CANVAS), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        [(0, 0), (CANVAS - 1, CANVAS - 1)], radius=CORNER_RADIUS, fill=255
    )

    base.paste(gradient, (0, 0), mask)

    draw = ImageDraw.Draw(base)

    # Bold "GC" centered, sized to comfortably fill the rounded square.
    font_size = 460
    font = ImageFont.truetype(FONT_PATH, font_size)
    text = "GC"
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    text_x = (CANVAS - text_w) / 2 - bbox[0]
    text_y = (CANVAS - text_h) / 2 - bbox[1]

    # Soft drop shadow for depth, then the letters.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.text((text_x, text_y + 10), text, font=font, fill=(0, 0, 0, 90))
    shadow = shadow.filter(__import__("PIL.ImageFilter", fromlist=["GaussianBlur"]).GaussianBlur(14))
    base.alpha_composite(shadow)

    draw.text((text_x, text_y), text, font=font, fill=(255, 255, 255, 255))

    # Small recording-red dot accent, bottom-right of the wordmark.
    dot_r = 46
    dot_cx = CANVAS - 176
    dot_cy = CANVAS - 176
    draw.ellipse(
        [(dot_cx - dot_r, dot_cy - dot_r), (dot_cx + dot_r, dot_cy + dot_r)],
        fill=DOT_COLOR,
        outline=(255, 255, 255, 230),
        width=10,
    )

    return base


def export_iconset(icon: Image.Image) -> None:
    os.makedirs(ICONSET_DIR, exist_ok=True)
    sizes = [16, 32, 128, 256, 512]
    for size in sizes:
        icon.resize((size, size), Image.LANCZOS).save(
            os.path.join(ICONSET_DIR, f"icon_{size}x{size}.png")
        )
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(
            os.path.join(ICONSET_DIR, f"icon_{size}x{size}@2x.png")
        )


if __name__ == "__main__":
    icon = make_base_icon()
    export_iconset(icon)
    icon.save(os.path.join(SCRIPT_DIR, "..", "Resources", "icon_preview.png"))
    print(f"Wrote iconset to {ICONSET_DIR}")
