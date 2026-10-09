#!/usr/bin/env python3
"""Compose the DSH Remote app icon from the harness's own whale.

The whale is **lifted from the installed harness's icon** rather than redrawn, so the app
carries the same mark rather than an approximation of it. On top of it this draws what the
app actually is: a phone, and a conversation happening on it.

    python3 Tools/make-app-icon.py                 # writes the asset catalog
    python3 Tools/make-app-icon.py --source <png>  # a different whale source
    python3 Tools/make-app-icon.py --preview out.png

Two iOS rules shape the output, and both are easy to get wrong:

* **Opaque, 1024×1024, square.** iOS applies its own mask, so a pre-rounded icon shows as a
  rounded icon inside a rounded icon, and an alpha channel is rejected outright.
* **Legible at 60 pt.** Everything is drawn at 4× and downsampled, because Pillow draws hard
  edges; the phone's on-screen bubbles are deliberately blocky for the same reason.

Requires Pillow (the harness's bundled Python has it).
"""

from __future__ import annotations

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

# The harness ships the mark at 1024 with the plate behind it.
DEFAULT_SOURCE = "/Applications/DeepSeek Harness.app/Contents/Resources/icon.png"
DEFAULT_OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Apps", "DSHRemote", "Resources", "Assets.xcassets", "AppIcon.appiconset",
)

SUPERSAMPLE = 4096
NAVY = (22, 32, 74)
BLUE = (77, 107, 254)          # the DeepSeek blue the harness itself uses
SCREEN = (236, 241, 255)


def over(size: int = SUPERSAMPLE) -> Image.Image:
    return Image.new("RGBA", (size, size), (0, 0, 0, 0))


def drop(image: Image.Image, blur: int = 40, alpha: int = 72, offset=(0, 20)) -> Image.Image:
    """A soft shadow under a layer, so the phone and bubble sit *above* the whale."""
    faded = image.split()[3].point(lambda v: min(255, int(v * alpha / 255)))
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow.putalpha(faded)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.paste(shadow, offset, shadow)
    return out


def whale_mask(source: str) -> Image.Image:
    """The whale as a silhouette, with its belly and eye left as holes.

    The source is the mark on a near-white plate. Keying on darkness keeps the body and
    drops the plate, which leaves the white belly and eye as openings — the shape the mark
    actually is. A median pass then removes the single-pixel specks the threshold leaves
    behind, which read as dirt once the art is scaled up.
    """
    plate = Image.open(source).convert("RGBA")
    width, height = plate.size
    pixels = plate.load()
    mask = Image.new("L", (width, height), 0)
    target = mask.load()
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a < 40:
                continue
            luminance = (r * 299 + g * 587 + b * 114) // 1000
            if luminance < 150:
                target[x, y] = 255
    bbox = mask.getbbox()
    if bbox is None:
        raise SystemExit(f"no dark art found in {source}")
    return mask.crop(bbox).filter(ImageFilter.MedianFilter(size=5))


def compose(source: str, size: int = 1024) -> Image.Image:
    scale = SUPERSAMPLE

    # A soft sky: light enough that a navy whale reads against it, and not flat.
    background = Image.new("RGB", (scale, scale))
    draw = ImageDraw.Draw(background)
    top, bottom = (223, 234, 255), (255, 255, 255)
    for y in range(scale):
        t = y / scale
        draw.line(
            [(0, y), (scale, y)],
            fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )
    canvas = background.convert("RGBA")

    # The whale, whole and clear of the phone: it is the mark, so nothing covers its face.
    whale = whale_mask(source)
    target_width = int(scale * 0.598)
    whale = whale.resize(
        (target_width, int(target_width * whale.size[1] / whale.size[0])), Image.LANCZOS
    )
    whale = whale.rotate(-6, resample=Image.BICUBIC, expand=True)
    whale_layer = Image.new("RGBA", whale.size, NAVY + (0,))
    whale_layer.putalpha(whale)
    canvas.alpha_composite(whale_layer, (int(scale * 0.029), int(scale * 0.381)))

    # The phone, to its right, tilted — held, not levitating.
    phone = over()
    pw, ph = int(scale * 0.176), int(scale * 0.325)
    px, py = (scale - pw) // 2, (scale - ph) // 2
    pen = ImageDraw.Draw(phone)
    pen.rounded_rectangle([px, py, px + pw, py + ph], radius=int(pw * 0.21), fill=NAVY)
    pen.rounded_rectangle(
        [px + int(pw * 0.055), py + int(pw * 0.055), px + pw - int(pw * 0.055), py + ph - int(pw * 0.055)],
        radius=int(pw * 0.155),
        fill=SCREEN,
    )
    # What he is doing on it: a bubble going out, one coming back. Blocky on purpose —
    # at 60 pt these are four pixels wide and detail would only muddy them.
    pen.rounded_rectangle(
        [px + int(pw * 0.17), py + int(ph * 0.195), px + pw - int(pw * 0.17), py + int(ph * 0.43)],
        radius=int(pw * 0.11),
        fill=BLUE,
    )
    for i in range(3):
        cx = px + int(pw * 0.285) + i * int(pw * 0.164)
        pen.ellipse([cx, py + int(ph * 0.285), cx + int(pw * 0.078), py + int(ph * 0.327)],
                    fill=(255, 255, 255, 255))
    pen.rounded_rectangle(
        [px + int(pw * 0.29), py + int(ph * 0.52), px + pw - int(pw * 0.17), py + int(ph * 0.68)],
        radius=int(pw * 0.10),
        fill=(255, 255, 255, 255),
    )
    pen.rounded_rectangle(
        [px + int(pw * 0.17), py + int(ph * 0.72), px + pw - int(pw * 0.17), py + int(ph * 0.89)],
        radius=int(pw * 0.10),
        fill=BLUE,
    )
    phone = phone.rotate(12, resample=Image.BICUBIC, expand=True, center=(scale // 2, scale // 2))
    if phone.size != (scale, scale):
        phone = phone.resize((scale, scale))
    canvas.alpha_composite(drop(phone, blur=44, alpha=78), (0, 0))
    canvas.alpha_composite(phone, (0, 0))

    # The outgoing bubble above it, with the dots that mean someone is typing.
    bubble = over()
    bw, bh = int(scale * 0.249), int(scale * 0.127)
    bx, by = int(scale * 0.566), int(scale * 0.093)
    pen = ImageDraw.Draw(bubble)
    pen.rounded_rectangle([bx, by, bx + bw, by + bh], radius=int(bh * 0.40), fill=BLUE)
    pen.polygon(
        [(bx + int(bw * 0.088), by + bh - int(bh * 0.058)),
         (bx + int(bw * 0.353), by + bh - int(bh * 0.038)),
         (bx + int(bw * 0.147), by + bh + int(bh * 0.404))],
        fill=BLUE,
    )
    for i in range(3):
        cx = bx + int(bw * 0.245) + i * int(bw * 0.245)
        pen.ellipse([cx, by + int(bh * 0.394), cx + int(bw * 0.086), by + int(bh * 0.564)],
                    fill=(255, 255, 255, 255))
    bubble = bubble.rotate(-7, resample=Image.BICUBIC, expand=True, center=(scale // 2, scale // 2))
    canvas.alpha_composite(drop(bubble, blur=38, alpha=68), (0, 0))
    canvas.alpha_composite(bubble, (0, 0))

    # RGB, not RGBA: iOS rejects an icon with an alpha channel.
    return canvas.convert("RGB").resize((size, size), Image.LANCZOS)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="the harness icon to lift the whale from")
    parser.add_argument("--out", default=DEFAULT_OUT, help="the AppIcon.appiconset directory")
    parser.add_argument("--preview", help="also write a smaller PNG here, for looking at")
    args = parser.parse_args()

    if not os.path.exists(args.source):
        print(f"no whale source at {args.source}", file=sys.stderr)
        return 2

    icon = compose(args.source)
    if args.out.endswith(".png"):
        icon.save(args.out)
        print(f"wrote {args.out}")
    else:
        os.makedirs(args.out, exist_ok=True)
        target = os.path.join(args.out, "AppIcon-1024.png")
        icon.save(target)
        print(f"wrote {target}")

    if args.preview:
        icon.resize((440, 440), Image.LANCZOS).save(args.preview)
        print(f"wrote {args.preview}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
