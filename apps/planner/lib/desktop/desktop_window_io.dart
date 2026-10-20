import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class DesktopWindow with WindowListener {
  DesktopWindow._();
  static final instance = DesktopWindow._();

  static const normalMinimum = Size(380, 520), widgetMinimum = Size(280, 300);
  static const widgetDefault = Size(340, 560);

  bool _enabled = false;
  bool get enabled => _enabled;
  final widgetMode = ValueNotifier(false);
  final pinned = ValueNotifier(false);
  final maximized = ValueNotifier(false);
  final opacity = ValueNotifier(1.0);
  Listenable get changes => Listenable.merge([widgetMode, pinned, maximized]);
  Timer? _saveBounds;

  Future<void> init(List<String> args) async {
    if (kIsWeb || !Platform.isWindows) return;
    await windowManager.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final startAsWidget =
        args.contains('--widget') || (prefs.getBool('desktop.widget') ?? false);
    opacity.value = prefs.getDouble('desktop.opacity') ?? 1.0;
    final normal = _rect(prefs.getString('desktop.normal'));
    final options = WindowOptions(
      title: '瞬时',
      size: normal?.size ?? const Size(1280, 820),
      minimumSize: normalMinimum,
      center: normal == null,
      backgroundColor: const Color(0x00000000),
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    _enabled = true;
    windowManager.addListener(this);
    // The runner no longer shows the window itself; always show it, even if
    // restoring the saved layout fails.
    await windowManager.waitUntilReadyToShow(options, () async {
      try {
        if (normal != null && await _visible(normal)) {
          await windowManager.setBounds(normal);
        }
        if (startAsWidget) await _enterWidget(prefs);
      } catch (error) {
        debugPrint('Window layout restore skipped: $error');
      } finally {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }

  Rect? _rect(String? value) {
    final parts = value?.split(',').map(double.tryParse).toList();
    if (parts == null || parts.length != 4 || parts.contains(null)) return null;
    return Rect.fromLTWH(parts[0]!, parts[1]!, parts[2]!, parts[3]!);
  }

  String _text(Rect r) => [r.left, r.top, r.width, r.height].join(',');

  /// A saved rectangle is only reused when it still lands on a display.
  Future<bool> _visible(Rect r) async {
    final displays = await screenRetriever.getAllDisplays();
    return displays.any((d) {
      final origin = d.visiblePosition ?? Offset.zero;
      final size = d.visibleSize ?? d.size;
      return (origin & size).overlaps(r.deflate(40));
    });
  }

  Future<void> _enterWidget(SharedPreferences prefs) async {
    var bounds = _rect(prefs.getString('desktop.widgetBounds'));
    if (bounds == null || !await _visible(bounds)) {
      final display = await screenRetriever.getPrimaryDisplay();
      final origin = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      bounds = Rect.fromLTWH(
        origin.dx + size.width - widgetDefault.width - 24,
        origin.dy + 24,
        widgetDefault.width,
        widgetDefault.height,
      );
    }
    if (await windowManager.isMaximized()) await windowManager.unmaximize();
    await windowManager.setMinimumSize(widgetMinimum);
    await windowManager.setBounds(bounds);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setOpacity(opacity.value);
    pinned.value = true;
    widgetMode.value = true;
  }

  Future<void> setWidgetMode(bool value) async {
    if (!_enabled || value == widgetMode.value) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('desktop.widget', value);
    if (value) {
      if (!await windowManager.isMaximized()) {
        await prefs.setString(
          'desktop.normal',
          _text(await windowManager.getBounds()),
        );
      }
      await _enterWidget(prefs);
    } else {
      await prefs.setString(
        'desktop.widgetBounds',
        _text(await windowManager.getBounds()),
      );
      widgetMode.value = false;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setOpacity(1);
      pinned.value = false;
      await windowManager.setMinimumSize(normalMinimum);
      final normal = _rect(prefs.getString('desktop.normal'));
      if (normal != null && await _visible(normal)) {
        await windowManager.setBounds(normal);
      } else {
        await windowManager.setSize(const Size(1280, 820));
        await windowManager.center();
      }
    }
  }

  Future<void> setPinned(bool value) async {
    if (!_enabled) return;
    await windowManager.setAlwaysOnTop(value);
    pinned.value = value;
  }

  Future<void> setOpacity(double value) async {
    opacity.value = value.clamp(.5, 1.0);
    if (!_enabled) return;
    await windowManager.setOpacity(opacity.value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('desktop.opacity', opacity.value);
  }

  Future<void> minimize() async {
    if (_enabled) await windowManager.minimize();
  }

  Future<void> toggleMaximize() async {
    if (!_enabled || widgetMode.value) return;
    await windowManager.isMaximized()
        ? windowManager.unmaximize()
        : windowManager.maximize();
  }

  Future<void> close() async {
    if (_enabled) await windowManager.close();
  }

  Future<void> startDragging() async {
    if (_enabled) await windowManager.startDragging();
  }

  void _rememberBounds() {
    _saveBounds?.cancel();
    _saveBounds = Timer(const Duration(milliseconds: 600), () async {
      if (await windowManager.isMaximized()) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        widgetMode.value ? 'desktop.widgetBounds' : 'desktop.normal',
        _text(await windowManager.getBounds()),
      );
    });
  }

  @override
  void onWindowMoved() => _rememberBounds();
  @override
  void onWindowResized() => _rememberBounds();
  @override
  void onWindowMaximize() => maximized.value = true;
  @override
  void onWindowUnmaximize() => maximized.value = false;
}
