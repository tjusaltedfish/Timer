"""表情包素材：只认「大肥鱼」那套，路径不许逃出素材目录，类别说明要喂给模型。"""
import random

from app import memes


def test_pick_is_none_for_unknown_category():
    assert memes.pick("狂喜") is None


def test_pick_is_deterministic_with_a_seeded_rng():
    first = memes.pick("happy", random.Random(0))
    second = memes.pick("happy", random.Random(0))
    assert first == second and first.startswith("happy/")


def test_pick_skips_recent_names_until_it_must():
    only = memes.files("sleep")[0]
    assert memes.pick("sleep", avoid=[memes.name_of(only)]) == memes.name_of(only)


def test_pick_prefers_art_not_recently_sent():
    name = memes.files("fool")[0]
    picked = memes.pick("fool", random.Random(0), avoid=[memes.name_of(name)])
    assert picked != memes.name_of(name)


def test_read_refuses_paths_outside_the_folder():
    for bad in ("", "happy", "../etc/passwd", "happy/../qq.py", "happy/../../server/app/qq.py", "狂喜/1.png"):
        assert memes.read(bad) is None


def test_read_returns_bytes_for_a_real_meme():
    name = memes.pick("happy", random.Random(0))
    assert name and memes.read(name)[:2] in (b"\x89P", b"\xff\xd8")


def test_available_reports_shipped_art():
    assert memes.available() is True


def test_every_asset_is_a_single_pack_image():
    """素材只能是大肥鱼那套：jpg/png、落在已知类别里、体积合理。"""
    for category in memes.CATEGORIES:
        for path in memes.files(category):
            assert path.parent.name == category
            assert path.suffix.lower() in {".jpg", ".jpeg", ".png"}
            assert 1024 < path.stat().st_size < 900 * 1024


def test_hint_lists_every_category_with_when_to_use_it():
    text = memes.hint()
    for category, when in memes.CATEGORIES.items():
        assert f"{category}={when}" in text
