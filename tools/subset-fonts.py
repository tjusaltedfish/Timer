"""Build the bundled title font. Run with the project's asset-tool venv.

Source: official LXGW WenKai v1.530 Regular (SIL OFL, docs/licenses/).
The subset is renamed Planner WenKai to distinguish the modified font.
"""
import argparse
from pathlib import Path
from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
args = parser.parse_args()
characters = (ROOT / 'tools/fonts/charset.txt').read_text(encoding='utf-8')
options = subset.Options()
options.recalc_timestamp = False
options.name_IDs = ['*']
font = TTFont(args.source, recalcTimestamp=False)
subsetter = subset.Subsetter(options=options)
subsetter.populate(text=characters)
subsetter.subset(font)
for item in font['name'].names:
    if item.nameID in {1, 3, 4, 6, 16}:
        value = 'PlannerWenKai-Regular' if item.nameID == 6 else 'Planner WenKai'
        item.string = value.encode(item.getEncoding())
output = ROOT / 'apps/planner/assets/fonts/PlannerWenKai-Regular.ttf'
output.parent.mkdir(parents=True, exist_ok=True)
font.save(output)
assert output.stat().st_size <= 4 * 1024 * 1024, 'Font exceeded the 4 MiB budget'
print(f'{output.name}: {output.stat().st_size:,} bytes')
