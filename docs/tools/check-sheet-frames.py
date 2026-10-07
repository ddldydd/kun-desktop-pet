"""检查每只宠物的精灵图：逐格统计非透明像素占比，找出「空帧」——空帧会让小宠周期性消失（频闪）。"""
import os

import numpy as np
from PIL import Image

ROWS = ["idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review"]
root = os.path.join(os.environ["USERPROFILE"], ".petdex", "pets")

for slug in sorted(os.listdir(root)):
    png = os.path.join(root, slug, "spritesheet.png")
    if not os.path.exists(png):
        continue
    im = Image.open(png).convert("RGBA")
    w, h = im.size
    cols, rows = 8, 9
    cw, ch = w // cols, h // rows
    a = np.asarray(im)[:, :, 3]
    print(f"\n=== {slug}  {w}x{h}  cell {cw}x{ch} ===")
    print("        " + "".join(f"col{c:<7d}" for c in range(cols)))
    for r in range(rows):
        cells = []
        for c in range(cols):
            cell = a[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw]
            frac = 100.0 * (cell > 8).mean()
            cells.append(frac)
        flags = "".join("  EMPTY " if f < 0.5 else f"  {f:5.1f}%" for f in cells)
        print(f"{ROWS[r]:<13s}{flags}")
