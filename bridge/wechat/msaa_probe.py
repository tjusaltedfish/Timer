"""Read-only probe: MSAA (IAccessible) child counts for Weixin windows.

Reports counts and roles only; no names or values are printed.
"""
import ctypes
import sys
import time
from ctypes import wintypes

import comtypes.client
from comtypes import automation

oleacc = ctypes.oledll.oleacc
comtypes.client.GetModule("oleacc.dll")
from comtypes.gen.Accessibility import IAccessible  # noqa: E402

user32 = ctypes.windll.user32
OBJID_CLIENT = 0xFFFFFFFC


def accessible(hwnd):
    pointer = ctypes.POINTER(IAccessible)()
    oleacc.AccessibleObjectFromWindow(
        hwnd, OBJID_CLIENT, ctypes.byref(IAccessible._iid_), ctypes.byref(pointer)
    )
    return pointer


def children_of(hwnd):
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def collect(child, _):
        name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(child, name, 256)
        found.append((child, name.value))
        return True

    user32.EnumChildWindows(hwnd, collect, 0)
    return found


for hwnd in map(int, sys.argv[1:]):
    for attempt in range(3):
        for child, cls in [(hwnd, "top"), *children_of(hwnd)]:
            try:
                acc = accessible(child)
                count = acc.accChildCount
                role = acc.accRole(automation.VARIANT(0))
            except Exception as error:  # noqa: BLE001
                count, role = f"error {type(error).__name__}", "-"
            print(f"hwnd={hwnd} attempt={attempt} part={cls} msaa_children={count} role={role}")
        time.sleep(3)
