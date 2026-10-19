import 'package:flutter/foundation.dart';

class DesktopWindow {
  DesktopWindow._();
  static final instance = DesktopWindow._();

  bool get enabled => false;
  final widgetMode = ValueNotifier(false);
  final pinned = ValueNotifier(false);
  final maximized = ValueNotifier(false);
  final opacity = ValueNotifier(1.0);
  Listenable get changes => Listenable.merge([widgetMode, pinned, maximized]);

  Future<void> init(List<String> args) async {}
  Future<void> setWidgetMode(bool value) async {}
  Future<void> setPinned(bool value) async {}
  Future<void> setOpacity(double value) async {}
  Future<void> minimize() async {}
  Future<void> toggleMaximize() async {}
  Future<void> close() async {}
  Future<void> startDragging() async {}
}
