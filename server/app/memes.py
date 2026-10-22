"""表情包：聊天回复后面可以补一张图。

素材只来自「大肥鱼表情包」（DeepSeek 鲸鱼娘二创，CC0），逐张按画面情绪分好类，
放在 `server/assets/memes/<类别>/`。模型只说类别，发哪张由这里决定；
没有素材时整个功能自动静默——不会让聊天失败。
"""
import random
import re
from pathlib import Path

# 类别 -> 什么时候该用。这段说明会原样喂给模型，所以它就是「发图符合逻辑」的规则。
CATEGORIES = {
    "happy": "真办成了事、听到好消息、替他高兴时",
    "like": "想夸他、觉得这个安排不错、被夸了有点得意时",
    "angry": "他拖延、找借口、说话欠揍，你假装凶他时",
    "baka": "他犯小错、犯迷糊、可可爱爱地抱怨时",
    "fool": "你自己出丑、耍赖、想摆烂、想缓和气氛时",
    "confused": "你没听懂、需要他再说一句时",
    "sad": "他受挫、没做成、你需要认真安慰或道歉时",
    "sigh": "无奈、感慨、老问题又来了时",
    "sleep": "深夜、劝他睡、他说累了时",
    "surprised": "出乎意料、突然的变化时",
    "work": "正经干活、催他开工时（低频）",
}
ROOT = Path(__file__).resolve().parent.parent / "assets" / "memes"
SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
SAFE = re.compile(r"^[\w\u4e00-\u9fa5-]+$")


def hint():
    """The prompt fragment that tells the model which sticker fits which moment."""
    return "；".join(f"{name}={when}" for name, when in CATEGORIES.items())


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


def name_of(path):
    """``类别/文件名`` for one asset path."""
    return f"{path.parent.name}/{path.name}"


def pick(category, rng=None, avoid=()):
    """Relative name like ``happy/1.jpg``, or None when this category has no art.

    ``avoid`` lists recently sent names so a one-sticker category does not look canned.
    """
    options = files(category)
    if not options:
        return None
    fresh = [path for path in options if name_of(path) not in avoid] or options
    chooser = rng.choice if rng is not None else random.choice
    return name_of(chooser(fresh))


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
