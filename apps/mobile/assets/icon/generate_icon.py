"""Generate the Sidemesh app icon — "prompt mesh" concept.

Produces a 1024x1024 PNG at assets/icon/app_icon.png.

Design: a terminal prompt ``>_`` rendered as a small mesh. Three nodes form
a chevron ``>`` (the tip highlighted in rust as the active peer you're
driving), connected by thick ink strokes. A rust underscore beneath reads
as the blinking cursor. Flat fills, no gradients — reads clearly at small
sizes and instantly says "dev tool, fleet of peers".
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
OUT = Path(__file__).with_name("app_icon.png")

# Palette (kept from prior iteration — warmer cream, charcoal-navy, earthy rust)
BG = (240, 232, 216)
INK = (32, 36, 50)
AMBER = (198, 96, 52)


def main() -> None:
    img = Image.new("RGB", (SIZE, SIZE), BG)
    d = ImageDraw.Draw(img)

    # Chevron node positions (roughly centered, slight lean left so the
    # cursor underneath feels anchored to the same optical center as `>`).
    top = (int(SIZE * 0.34), int(SIZE * 0.30))
    tip = (int(SIZE * 0.72), int(SIZE * 0.48))
    bot = (int(SIZE * 0.34), int(SIZE * 0.66))

    stroke = int(SIZE * 0.05)             # bold chevron lines
    node_r = int(SIZE * 0.065)            # back nodes
    tip_r = int(SIZE * 0.085)             # front/active node, slightly larger
    pupil_r_back = int(node_r * 0.30)
    pupil_r_tip = int(tip_r * 0.32)

    # --- Chevron lines (drawn first so node discs tuck over the ends) ---
    # Rounded-cap look: use thick lines, then cap with small ink discs at each end.
    d.line((*top, *tip), fill=INK, width=stroke)
    d.line((*tip, *bot), fill=INK, width=stroke)
    cap_r = stroke // 2
    for p in (top, tip, bot):
        d.ellipse((p[0] - cap_r, p[1] - cap_r, p[0] + cap_r, p[1] + cap_r), fill=INK)

    # --- Back nodes (ink) with cream pupils ---
    for (nx, ny) in (top, bot):
        d.ellipse((nx - node_r, ny - node_r, nx + node_r, ny + node_r), fill=INK)
        d.ellipse((nx - pupil_r_back, ny - pupil_r_back,
                   nx + pupil_r_back, ny + pupil_r_back), fill=BG)

    # --- Active tip node (rust) with cream pupil ---
    tx, ty = tip
    d.ellipse((tx - tip_r, ty - tip_r, tx + tip_r, ty + tip_r), fill=AMBER)
    d.ellipse((tx - pupil_r_tip, ty - pupil_r_tip,
               tx + pupil_r_tip, ty + pupil_r_tip), fill=BG)

    # --- Underscore cursor `_` ---
    cur_left = int(SIZE * 0.34)
    cur_right = int(SIZE * 0.66)
    cur_y = int(SIZE * 0.82)
    cur_h = int(SIZE * 0.045)
    cur_radius = cur_h // 2
    d.rounded_rectangle(
        (cur_left, cur_y, cur_right, cur_y + cur_h),
        radius=cur_radius,
        fill=AMBER,
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, format="PNG", optimize=True)
    print(f"wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
