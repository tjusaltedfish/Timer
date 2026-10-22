"""Lightweight JSONL timing log.

"为什么回得慢" 这类问题只能靠现场数据回答：每轮通道处理与每次模型往返都记一行，
放在数据目录里，不参与业务、写失败也不影响任何东西。
"""

from __future__ import annotations

import json
import time
from pathlib import Path

LIMIT = 2 * 1024 * 1024


def record(directory: Path | str, event: str, **fields) -> None:
    """Append one line to <data>/channel_timings.jsonl, rotating past 2MB."""
    try:
        path = Path(directory) / "channel_timings.jsonl"
        try:
            if path.stat().st_size > LIMIT:
                path.unlink()
        except OSError:
            pass
        line = json.dumps({"event": event, "at": time.time(), **fields}, ensure_ascii=False)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + chr(10))
    except OSError:
        pass
