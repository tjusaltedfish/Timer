"""Read-only probe: counts UIA raw-view descendants under Weixin render panes.

Prints only control types, class names and counts; never names or values.
"""
import ctypes
import os
from collections import Counter
from ctypes import wintypes

from pywinauto import Desktop
from pywinauto.uia_defines import IUIA


def process_name(pid):
    kernel = ctypes.windll.kernel32
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        return "?"
    try:
        buffer = ctypes.create_unicode_buffer(1024)
        size = wintypes.DWORD(len(buffer))
        ok = kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size))
        return os.path.basename(buffer.value) if ok else "?"
    finally:
        kernel.CloseHandle(handle)


def raw_count(element, walker, depth=0, counts=None, limit=[5000]):
    counts = counts if counts is not None else Counter()
    child = walker.GetFirstChildElement(element)
    while child and limit[0] > 0:
        limit[0] -= 1
        counts[(child.CurrentControlType, child.CurrentClassName)] += 1
        if depth < 40:
            raw_count(child, walker, depth + 1, counts, limit)
        child = walker.GetNextSiblingElement(child)
    return counts


walker = IUIA().iuia.RawViewWalker
for window in Desktop(backend="uia").windows():
    info = window.element_info
    if process_name(info.process_id).lower() != "weixin.exe" or not info.name:
        continue
    counts = raw_count(info.element, walker)
    placement = ctypes.windll.user32.IsIconic(info.handle)
    print(f"pid={info.process_id} minimized={bool(placement)} visible={bool(ctypes.windll.user32.IsWindowVisible(info.handle))} raw_nodes={sum(counts.values())}")
    for (control, cls), n in counts.most_common(12):
        print(f"   {n:5d}  type={control} class={cls}")
