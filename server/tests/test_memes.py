"""表情包素材：只认十类，路径不许逃出素材目录。"""
import random

from app import memes


def test_pick_is_none_for_unknown_category():
    assert memes.pick("狂喜") is None


def test_pick_is_deterministic_with_a_seeded_rng():
    first = memes.pick("开心", random.Random(0))
    second = memes.pick("开心", random.Random(0))
    assert first == second and first.startswith("开心/")


def test_read_refuses_paths_outside_the_folder():
    for bad in ("", "开心", "../etc/passwd", "开心/../qq.py", "开心/../../server/app/qq.py", "狂喜/1.png"):
        assert memes.read(bad) is None


def test_read_returns_bytes_for_a_real_meme():
    name = memes.pick("开心", random.Random(0))
    assert name and memes.read(name)[:2] in (b"\x89P", b"\xff\xd8")


def test_available_reports_shipped_art():
    assert memes.available() is True
