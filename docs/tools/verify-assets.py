"""校验 assets/pets 下每只素材的完整性。

检查项：
  1. pet.json 存在且是合法 JSON
  2. pet.json 里 spritesheetPath 指向的文件存在
  3. 精灵图能被 Pillow 打开，尺寸能被 8 列整除（行数为 9 或 11）
  4. 每行至少有 1 个非空帧（整行全空说明行顺序或素材本身有问题）

退出码非 0 表示有问题；CI 会因此失败。
"""
import json
import os
import sys

from PIL import Image

# Windows 控制台默认可能是 GBK，打印 ✓ / 中文会抛 UnicodeEncodeError。
# 这里强制走 UTF-8，失败就退化成可替换字符，绝不让「打印」把检查结果搞崩。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

COLS = 8
ALLOWED_ROWS = (9, 11)
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "pets")


def check_pet(pet_dir: str) -> list:
    errors = []
    name = os.path.basename(pet_dir)
    meta_path = os.path.join(pet_dir, "pet.json")

    if not os.path.exists(meta_path):
        return [f"{name}: 缺少 pet.json"]

    try:
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
    except Exception as exc:
        return [f"{name}: pet.json 不是合法 JSON ({exc})"]

    sheet_name = meta.get("spritesheetPath") or "spritesheet.png"
    sheet_path = os.path.join(pet_dir, sheet_name)
    if not os.path.exists(sheet_path):
        # 仓库内同时提供 png/webp，spritesheetPath 指向哪个都行，但必须存在
        errors.append(f"{name}: pet.json 指向的 {sheet_name} 不存在")
        return errors

    try:
        with Image.open(sheet_path) as im:
            w, h = im.size
            alpha = im.convert("RGBA").getchannel("A")
    except Exception as exc:
        return [f"{name}: 无法打开 {sheet_name} ({exc})"]

    if w % COLS != 0:
        errors.append(f"{name}: 宽度 {w} 不能被 {COLS} 列整除")
        return errors

    rows = None
    for candidate in ALLOWED_ROWS:
        if h % candidate == 0 and (h // candidate) == (w // COLS) * 208 // 192:
            rows = candidate
            break
    if rows is None:
        # 退一步：只要能被 9 或 11 整除就接受，并给出警告
        rows = next((c for c in ALLOWED_ROWS if h % c == 0), None)
        if rows is None:
            errors.append(f"{name}: 高度 {h} 不能被 9 或 11 整除")
            return errors
        print(f"  ! {name}: 高度 {h} / {rows} = {h // rows}px 每格，非标准 192x208（仅提示）")

    cw, ch = w // COLS, h // rows
    print(f"  {name}: {w}x{h}  每格 {cw}x{ch}  {COLS}x{rows}")

    for r in range(rows):
        cell = alpha.crop((0, r * ch, cw, (r + 1) * ch))
        if cell.getbbox() is None:
            errors.append(f"{name}: 第 {r + 1} 行整行全透明（空行）")

    for label, key in (("显示名", "displayName"), ("描述", "description")):
        if key in meta and meta[key] and not isinstance(meta[key], str):
            errors.append(f"{name}: {label} 字段 ({key}) 应为字符串")

    return errors


def main() -> int:
    if not os.path.isdir(ROOT):
        print(f"没有找到素材目录: {ROOT}")
        return 1

    pets = sorted(d for d in os.listdir(ROOT) if os.path.isdir(os.path.join(ROOT, d)))
    if not pets:
        print("assets/pets 下没有任何素材目录")
        return 1

    print(f"检查 {len(pets)} 只素材:")
    all_errors = []
    for pet in pets:
        all_errors += check_pet(os.path.join(ROOT, pet))

    if all_errors:
        print("\n发现问题:")
        for e in all_errors:
            print("  x " + e)
        return 1

    print("\n全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
