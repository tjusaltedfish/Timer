"""Build a labelled contact sheet of the meme assets for visual review."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent / "server" / "assets" / "memes"
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "artifacts/meme-sheet.png")
CELL = 280
COLS = 5


def main():
    files = sorted(p for p in ROOT.rglob("*") if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".webp"})
    rows = (len(files) + COLS - 1) // COLS
    sheet = Image.new("RGB", (COLS * CELL, rows * (CELL + 26)), "white")
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("msyh.ttc", 18)
    except OSError:
        font = ImageFont.load_default()
    for index, path in enumerate(files):
        try:
            image = Image.open(path).convert("RGB")
        except Exception as error:  # noqa: BLE001
            print("skip", path, error)
            continue
        image.thumbnail((CELL - 8, CELL - 8))
        x, y = (index % COLS) * CELL, (index // COLS) * (CELL + 26)
        sheet.paste(image, (x + (CELL - image.width) // 2, y + (CELL - image.height) // 2))
        label = f"{path.parent.name}/{path.name}"
        draw.text((x + 4, y + CELL + 2), label, fill="black", font=font)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUT)
    print("wrote", OUT, sheet.size, len(files))


if __name__ == "__main__":
    main()
