#!/usr/bin/env python3
"""Makes the Android adaptive-icon layers from assets/Icon-square-full-size.png.

Android draws an adaptive icon from a 108dp layer and shows only the middle
of it, cut to whatever shape the launcher uses (circle, squircle, rounded
square...). Only the middle 66dp circle is sure to be seen on every device.
The artwork is therefore scaled so the tile grid and its sparkles sit inside
that circle, its edges fade out, and the background colour (taken from the
artwork's own border) carries on to the layer's edge behind it.

Run from the repository root after changing the artwork (needs Pillow):

    python3 tool/gen-android-icon.py
"""
from pathlib import Path
from statistics import median

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "Icon-square-full-size.png"
RES = ROOT / "android" / "app" / "src" / "main" / "res"

# Share of the 108dp layer the artwork covers. At 0.68 the farthest sparkle
# tip lands just inside the 66dp safe circle.
SCALE = 0.68
# Width of the fade at the artwork's edge, as a share of the artwork.
FADE = 0.08
# Pixels per 108dp layer for each density.
SIZES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def border_colour(image):
    """The median colour of the artwork's outermost pixels."""
    w, h = image.size
    px = image.load()
    edge = [px[x, y] for x in range(w) for y in (0, h - 1)]
    edge += [px[x, y] for y in range(h) for x in (0, w - 1)]
    return tuple(int(median(c[i] for c in edge)) for i in range(3))


def foreground(image, size):
    art = round(size * SCALE)
    scaled = image.resize((art, art), Image.LANCZOS)
    fade = max(1, round(art * FADE))
    alpha = Image.new("L", (art, art), 0)
    ImageDraw.Draw(alpha).rectangle((fade, fade, art - fade - 1, art - fade - 1), fill=255)
    alpha = alpha.filter(ImageFilter.GaussianBlur(fade / 2.5))
    # The blur must reach zero by the edge so no seam shows.
    edge = Image.new("L", (art, art), 0)
    ImageDraw.Draw(edge).rectangle((1, 1, art - 2, art - 2), fill=255)
    scaled.putalpha(Image.composite(alpha, edge, edge))
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset = (size - art) // 2
    layer.paste(scaled, (offset, offset))
    return layer


def main():
    image = Image.open(SOURCE).convert("RGB")
    colour = "#%02X%02X%02X" % border_colour(image)
    for density, size in SIZES.items():
        out = RES / f"mipmap-{density}" / "ic_launcher_foreground.png"
        foreground(image, size).save(out, optimize=True)
        print(out.relative_to(ROOT))
    colours = RES / "values" / "ic_launcher_background.xml"
    colours.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Written by tool/gen-android-icon.py: the launcher icon's background,\n"
        "     matched to the edge of the artwork. -->\n"
        "<resources>\n"
        f'    <color name="ic_launcher_background">{colour}</color>\n'
        "</resources>\n"
    )
    print(colours.relative_to(ROOT), colour)


if __name__ == "__main__":
    main()
