"""Overlay a numbered grid on an image to help determine column/row proportions.

Usage: python overlay-grid.py <image> [-c COLS] [-r ROWS] [-o OUTPUT]

The grid helps an LLM count "squares" to determine exact column widths
and positions when analyzing printed forms for MXL template generation.

Numbers are rendered in a dedicated margin band outside the image content,
so they never overlap with the form and remain readable at any grid density.
"""
import argparse
import os
from PIL import Image, ImageDraw, ImageFont

MARGIN_TOP = 20
MARGIN_LEFT = 24


def main():
    parser = argparse.ArgumentParser(description="Overlay numbered grid on image")
    parser.add_argument("image", help="Input image path")
    parser.add_argument("-c", "--cols", type=int, default=50,
                        help="Number of vertical divisions (default: 50)")
    parser.add_argument("-r", "--rows", type=int, default=0,
                        help="Number of horizontal divisions (0 = auto, match cell aspect ratio)")
    parser.add_argument("-o", "--output", help="Output path (default: <name>-grid.<ext>)")
    args = parser.parse_args()

    src = Image.open(args.image).convert("RGBA")
    sw, sh = src.size

    cols = args.cols
    step_x = sw / cols
    rows = args.rows
    if rows == 0:
        rows = round(sh / step_x)
    step_y = sh / rows

    # Canvas with margins for labels
    cw = MARGIN_LEFT + sw
    ch = MARGIN_TOP + sh
    canvas = Image.new("RGBA", (cw, ch), (255, 255, 255, 255))
    canvas.paste(src, (MARGIN_LEFT, MARGIN_TOP))

    overlay = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Font for labels in margin
    label_font_size = 12
    try:
        label_font = ImageFont.truetype("arial.ttf", label_font_size)
    except Exception:
        label_font = ImageFont.load_default()

    # --- Vertical lines + numbers in top margin ---
    for i in range(cols + 1):
        x = MARGIN_LEFT + round(i * step_x)
        major = i % 10 == 0
        mid = i % 5 == 0

        alpha = 160 if major else (110 if mid else 40)
        lw = 2 if major else 1
        draw.line([(x, MARGIN_TOP), (x, ch)], fill=(255, 0, 0, alpha), width=lw)

        # Labels: always show multiples of 5; show all if spacing allows
        show_label = major or mid or step_x >= 20
        if show_label:
            label = str(i)
            bbox = label_font.getbbox(label)
            tw = bbox[2] - bbox[0]
            tx = x - tw // 2
            ty = 2
            color = (200, 0, 0, 255) if (major or mid) else (200, 0, 0, 180)
            draw.text((tx, ty), label, fill=color, font=label_font)

    # --- Horizontal lines + numbers in left margin ---
    for j in range(rows + 1):
        y = MARGIN_TOP + round(j * step_y)
        major = j % 10 == 0
        mid = j % 5 == 0

        alpha = 160 if major else (110 if mid else 20)
        lw = 2 if major else 1
        draw.line([(MARGIN_LEFT, y), (cw, y)], fill=(0, 0, 200, alpha), width=lw)

        show_label = major or mid or step_y >= 20
        if show_label:
            label = str(j)
            bbox = label_font.getbbox(label)
            tw = bbox[2] - bbox[0]
            tx = MARGIN_LEFT - tw - 3
            ty = y - label_font_size // 2
            color = (0, 0, 200, 255) if (major or mid) else (0, 0, 200, 180)
            draw.text((tx, ty), label, fill=color, font=label_font)

    result = Image.alpha_composite(canvas, overlay).convert("RGB")

    if args.output:
        out = args.output
    else:
        name, ext = os.path.splitext(args.image)
        out = f"{name}-grid{ext}"

    result.save(out)
    print(f"Grid: {cols} x {rows} cells")
    print(f"Cell size: {step_x:.1f} x {step_y:.1f} px")
    print(f"Image: {sw} x {sh} px")
    print(f"Saved: {out}")


if __name__ == "__main__":
    main()
