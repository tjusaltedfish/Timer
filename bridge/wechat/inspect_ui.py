"""Read-only UIA inspection of Windows Weixin main windows (stage W1).

Never clicks, types, focuses or moves anything. Names that may contain chat
content (text, list items, documents, custom controls) are reduced to their
length; only interface chrome names (buttons, tabs, menus, windows) are kept,
so the report shows whether the needed controls exist without copying
conversations.

Usage: bridge/wechat/.venv/Scripts/python.exe bridge/wechat/inspect_ui.py OUT.json
"""
import ctypes
import json
import os
import sys
from collections import Counter
from ctypes import wintypes

from pywinauto import Desktop

KEEP_NAMES = {"Button", "TabItem", "MenuItem", "Window", "TitleBar", "ToolBar", "SplitButton", "CheckBox", "Tab"}
MAX_DEPTH, MAX_NODES = 40, 6000


def describe(info):
    control = info.control_type or ""
    name = info.name or ""
    try:
        rect = info.rectangle
        size = [rect.width(), rect.height()]
    except Exception:  # noqa: BLE001 - some providers refuse geometry
        size = None
    return {
        "type": control,
        "class": info.class_name or "",
        "automation_id": info.automation_id or "",
        "name": name if control in KEEP_NAMES else (f"<{len(name)} chars>" if name else ""),
        "size": size,
    }


def process_name(pid):
    kernel = ctypes.windll.kernel32
    handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return "?"
    try:
        buffer = ctypes.create_unicode_buffer(1024)
        size = wintypes.DWORD(len(buffer))
        ok = kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size))
        return os.path.basename(buffer.value) if ok else "?"
    finally:
        kernel.CloseHandle(handle)


def walk(info, depth, budget, counts):
    node = describe(info)
    counts[node["type"]] += 1
    budget[0] -= 1
    if depth >= MAX_DEPTH or budget[0] <= 0:
        node["truncated"] = True
        return node
    try:
        children = info.children()
    except Exception as error:  # noqa: BLE001
        node["error"] = type(error).__name__
        return node
    if children:
        node["children"] = [walk(child, depth + 1, budget, counts) for child in children if budget[0] > 0]
    return node


def main(out):
    report = []
    for window in Desktop(backend="uia").windows():
        info = window.element_info
        process = process_name(info.process_id)
        if process.lower() != "weixin.exe" or not info.name:
            continue
        counts, budget = Counter(), [MAX_NODES]
        tree = walk(info, 0, budget, counts)
        rect = info.rectangle
        report.append({
            "pid": info.process_id,
            "handle": info.handle,
            "title": info.name,
            "rect": [rect.left, rect.top, rect.width(), rect.height()],
            "node_count": sum(counts.values()),
            "type_counts": dict(counts.most_common()),
            "tree": tree,
        })
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=1)
    for window in report:
        print(window["pid"], window["handle"], window["title"], window["rect"], window["node_count"], window["type_counts"])


if __name__ == "__main__":
    main(sys.argv[1])
