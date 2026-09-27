#!/usr/bin/env python3
"""Draw site/images/og-card.png - the link preview for the download page.

Without one, a feed takes the only image the page names, the 512px app icon,
and stretches it over a 1200x630 card.  So the card is drawn here: the app
icon at a size it was drawn for, on the ground the page stands on.  Nothing
is written on it - the title and description in the <head> sit under the
card in every feed, and a card that repeats them says everything twice.
The same card as the 218e Rewired page's (~/SDIY/218ev3-Firmware-Flashing,
tools/make-og-card.py), with the icon in place of the banana.

    python3 tools/make-og-card.py        (needs Pillow)

Run by hand and the PNG committed, as the icons are.  Redraw it when the app
icon, the wave or the page's --bg changes, and put the new file's stamp on
og:image in site/index.html (the script prints it).
"""
import argparse
import hashlib
import re
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SITE = REPO / "site"

# Facebook's recommended size and the 1.91:1 it crops everything else to;
# X, LinkedIn, Slack and iMessage read the same card.
W, H = 1200, 630

# How tall the icon's rounded square stands, as a share of the card.  0.6
# keeps the 512px source above the size it is drawn at (no upscaling) and
# leaves enough ground around it that it reads as placed, not cropped.
SUBJECT = round(H * 0.6)
# The macOS icon grid: an 824-unit body on a 1024 canvas.  The body is
# centred on its canvas, so centring the canvas centres the square.
BODY = 824 / 1024

# 1 is `cover`, as the stylesheet places the wave.  A card is a sixth of the
# area of the viewport the wave was drawn for, and at 1 its strokes come out
# too small to read at .5 opacity; zooming in gives fewer, larger ones.
WAVE_ZOOM = 1.5


def background():
    """The page's --bg, read from the stylesheet rather than repeated here."""
    css = (SITE / "style.css").read_text(encoding="utf-8")
    m = re.search(r":root\s*\{[^}]*?--bg:\s*(#[0-9a-fA-F]{3,8})\s*;", css)
    if not m:
        raise SystemExit("--bg is not in :root in site/style.css")
    return m.group(1)


def ground(colour):
    """The flat colour, then the wave over it at .5, as body::before has it."""
    card = Image.new("RGBA", (W, H), colour)
    wave = Image.open(SITE / "images" / "wave_bg.png").convert("RGBA")
    scale = max(W / wave.width, H / wave.height) * WAVE_ZOOM
    wave = wave.resize((round(wave.width * scale), round(wave.height * scale)),
                       Image.LANCZOS)
    left, top = (wave.width - W) // 2, (wave.height - H) // 2
    wave = wave.crop((left, top, left + W, top + H))
    wave.putalpha(wave.getchannel("A").point(lambda a: a // 2))
    card.alpha_composite(wave)
    return card


def build(out):
    card = ground(background())
    icon = Image.open(SITE / "icons" / "app-icon.png").convert("RGBA")
    side = round(SUBJECT / BODY)
    if side > icon.width:
        raise SystemExit(f"app-icon.png is {icon.width}px; the card needs {side}px")
    icon = icon.resize((side, side), Image.LANCZOS)
    card.alpha_composite(icon, ((W - side) // 2, (H - side) // 2))
    card.convert("RGB").save(out, "PNG", optimize=True)
    out = Path(out)
    stamp = hashlib.sha256(out.read_bytes()).hexdigest()[:8]
    name = out.relative_to(REPO) if out.is_relative_to(REPO) else out
    print(f"  wrote {name} ({out.stat().st_size // 1024} KB), stamp ?v={stamp}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=str(SITE / "images" / "og-card.png"))
    build(ap.parse_args().out)


if __name__ == "__main__":
    main()
