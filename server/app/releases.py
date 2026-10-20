"""App versions and phone releases.

The single version source is apps/planner/pubspec.yaml (`version: 1.2.3+45`;
the number after "+" is the Android versionCode and must keep increasing).
Published phone builds live outside Git in <data>/releases/:
    latest.json            version, build, file, size, sha256, min_build
    timer-<version>.apk    the arm64 APK it describes

Publish from tools/release.ps1:
    python -m app.releases publish <apk> [--require] [--data DIR]
"""
import argparse
import hashlib
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

PUBSPEC = Path(__file__).resolve().parents[2] / "apps" / "planner" / "pubspec.yaml"
VERSION = re.compile(r"^(\d+\.\d+\.\d+)\+(\d+)$")
KEEP_APKS = 2


def parse_version(text):
    """'1.2.3+45' -> ('1.2.3', 45); anything else -> None."""
    match = VERSION.match((text or "").strip())
    return (match.group(1), int(match.group(2))) if match else None


def source_version(pubspec=PUBSPEC):
    try:
        for line in Path(pubspec).read_text(encoding="utf-8").splitlines():
            if line.startswith("version:"):
                value = line.split(":", 1)[1].strip()
                if parse_version(value):
                    return value
    except OSError:
        pass
    return "0.0.0+0"


def releases_dir(directory):
    return Path(directory) / "releases"


def read_latest(directory):
    """Published phone release, or None. A record whose APK is missing is ignored."""
    folder = releases_dir(directory)
    try:
        info = json.loads((folder / "latest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not parse_version(info.get("version")) or not (folder / str(info.get("file", ""))).is_file():
        return None
    return info


def apk_path(directory, info):
    return releases_dir(directory) / info["file"]


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def publish(directory, apk, version, require=False, now=None):
    """Copy the APK into <data>/releases and point latest.json at it.

    min_build only moves when `require` is set, so ordinary releases are
    offered, and a breaking one can insist."""
    parsed = parse_version(version)
    if not parsed:
        raise ValueError(f"版本号格式应为 1.2.3+45：{version}")
    folder = releases_dir(directory)
    folder.mkdir(parents=True, exist_ok=True)
    previous = read_latest(directory)
    if previous and parse_version(previous["version"])[1] >= parsed[1]:
        raise ValueError(f"新版本号 {version} 的 build 必须大于已发布的 {previous['version']}")
    name = f"timer-{version.replace('+', '-')}.apk"
    temporary = folder / (name + ".tmp")
    shutil.copyfile(apk, temporary)
    temporary.replace(folder / name)
    info = {
        "version": version, "name": parsed[0], "build": parsed[1], "file": name,
        "size": (folder / name).stat().st_size, "sha256": sha256_of(folder / name),
        "min_build": parsed[1] if require else (previous or {}).get("min_build", 0),
        "published_at": (now or datetime.now(timezone.utc)).isoformat(),
    }
    record = folder / "latest.json.tmp"
    record.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    record.replace(folder / "latest.json")
    apks = sorted(folder.glob("timer-*.apk"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in apks[KEEP_APKS:]:
        old.unlink(missing_ok=True)
    return info


def public(info):
    if not info:
        return None
    return {key: info[key] for key in ("version", "name", "build", "size", "sha256", "min_build", "published_at")}


def default_data_dir():
    # Outside AppData on purpose: packaged apps (Claude, Codex) silently redirect
    # AppData writes into their own caches, which split the data into copies.
    return Path(os.environ.get("PLANNER_DATA_DIR", Path.home() / "TimePlanner" / "data"))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="python -m app.releases")
    sub = parser.add_subparsers(dest="command", required=True)
    pub = sub.add_parser("publish", help="publish an APK as the latest phone release")
    pub.add_argument("apk")
    pub.add_argument("--version", default=None, help="defaults to pubspec.yaml")
    pub.add_argument("--require", action="store_true", help="older phone builds must update")
    pub.add_argument("--data", default=None)
    args = parser.parse_args(argv)
    info = publish(args.data or default_data_dir(), args.apk, args.version or source_version(), args.require)
    print(json.dumps(public(info), ensure_ascii=False))


if __name__ == "__main__":
    main()
