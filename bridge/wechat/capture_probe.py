"""Read-only probe: can the Weixin window be captured without bringing it forward?

Captures one frame in memory with PrintWindow(PW_RENDERFULLCONTENT) and with a
plain screen copy, reports only the share of non-black pixels, and discards the
pixels. Nothing is saved and no chat content is inspected.
"""
import ctypes
import sys
from ctypes import wintypes

user32, gdi32 = ctypes.windll.user32, ctypes.windll.gdi32
user32.SetProcessDPIAware()


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


def lit_share(hwnd, use_print_window):
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    screen = user32.GetDC(0)
    memory = gdi32.CreateCompatibleDC(screen)
    bitmap = gdi32.CreateCompatibleBitmap(screen, width, height)
    gdi32.SelectObject(memory, bitmap)
    if use_print_window:
        ok = user32.PrintWindow(hwnd, memory, 2)  # PW_RENDERFULLCONTENT
    else:
        ok = gdi32.BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top, 0x00CC0020)
    header = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), width, -height, 1, 32, 0, 0, 0, 0, 0, 0)
    buffer = (ctypes.c_ubyte * (width * height * 4))()
    gdi32.GetDIBits(memory, bitmap, 0, height, buffer, ctypes.byref(header), 0)
    lit = sum(1 for i in range(0, len(buffer), 4 * 97) if buffer[i] or buffer[i + 1] or buffer[i + 2])
    total = len(range(0, len(buffer), 4 * 97))
    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(memory)
    user32.ReleaseDC(0, screen)
    return bool(ok), round(lit / max(total, 1), 3), (width, height)


hwnd = int(sys.argv[1])
foreground = user32.GetForegroundWindow() == hwnd
for label, flag in (("PrintWindow", True), ("ScreenCopy", False)):
    ok, share, size = lit_share(hwnd, flag)
    print(f"{label}: ok={ok} non_black_share={share} size={size} weixin_in_foreground={foreground}")
