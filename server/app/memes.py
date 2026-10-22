"""表情包：聊天回复后面可以补一张图。

模型只说类别（开心 / 累了 …），真正发哪张由这里决定。素材放在
`server/assets/memes/<类别>/`，没有素材时整个功能自动静默——不会让聊天失败。
"""
import random
import re
from pathlib import Path

# 模型可以填的 meme 取值；顺序即优先级，前几个用得最多。
CATEGORIES = ("开心", "得意", "夸你", "鼓励", "累了", "无语", "委屈", "偷懒", "道谢", "道歉")
ROOT = Path(__file__).resolve().parent.parent / "assets" / "memes"
SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
SAFE = re.compile(r"^[\w\u4e00-\u9fa5-]+$")


def _folder(category):
    if category not in CATEGORIES:
        return None
    return ROOT / category


def files(category):
    """Sibling files of one category, sorted so tests are deterministic."""
    folder = _folder(category)
    if folder is None or not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir() if p.suffix.lower() in SUFFIXES and p.stat().st_size <= 4 * 1024 * 1024)


def pick(category, rng=None):
    """Relative name like ``开心/aa.png``, or None when this category has no art."""
    options = files(category)
    if not options:
        return None
    return f"{category}/{rng.choice(options).name if rng else random.choice(options).name}"


def read(name):
    """Bytes of a picked meme; None when the name is unknown or escapes the folder."""
    if not name or not SAFE.fullmatch(name.split("/")[0]) or "/" not in name:
        return None
    folder, _, filename = name.partition("/")
    if folder not in CATEGORIES or not SAFE.fullmatch(filename.rsplit(".", 1)[0]):
        return None
    path = ROOT / folder / filename
    if path.suffix.lower() not in SUFFIXES or not path.is_file():
        return None
    return path.read_bytes()


def available():
    return any(files(category) for category in CATEGORIES)
