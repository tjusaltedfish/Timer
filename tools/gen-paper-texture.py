"""Reproducible 256px seamless paper grain; Pillow is a build-only tool."""
import random
from pathlib import Path
from PIL import Image, ImageDraw

random.seed(20261019)
image = Image.new('L', (256, 256))
image.putdata([max(0, min(255, round(random.gauss(190, 30)))) for _ in range(256**2)])
draw = ImageDraw.Draw(image)
for _ in range(100):
    x, y = random.randrange(256), random.randrange(256)
    dx, dy = random.randrange(-2, 3), random.randrange(3, 12)
    shade = random.randrange(90, 160)
    for ox in (-256, 0, 256):
        for oy in (-256, 0, 256):
            draw.line((x+ox, y+oy, x+dx+ox, y+dy+oy), fill=shade)
output = Path(__file__).resolve().parents[1] / 'apps/planner/assets/textures/paper.png'
output.parent.mkdir(parents=True, exist_ok=True)
image.quantize(colors=16).save(output, optimize=True)
assert output.stat().st_size < 40000
print(f'{output.name}: {output.stat().st_size:,} bytes')
