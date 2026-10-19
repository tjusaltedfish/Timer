/// Native window chrome for the Windows build: frameless window with an ink
/// title bar, always-on-top pinning and a compact desktop widget mode.
/// On every other platform (and in tests) [DesktopWindow.enabled] stays false.
library;

export 'desktop_window_stub.dart' if (dart.library.io) 'desktop_window_io.dart';
