import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as timezone_data;

import 'bootstrap.dart';
import 'controller.dart';
import 'desktop/desktop_window.dart';
import 'planner_app.dart';
import 'reminders.dart';
import 'updates.dart';

// Startup checkpoints are kept in the shipped app on purpose: when the phone
// gets stuck on the splash screen there are no Dart logs to look at, and a
// user can capture these tags with `adb logcat | grep boot`. Each step is
// guarded so one failing plugin cannot freeze the whole launch.
void _boot(String step) => debugPrint('[boot] $step');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    _boot('FlutterError ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    _boot('uncaught $error');
    return true;
  };
  _boot('start');
  timezone_data.initializeTimeZones();
  // Draw behind transparent system bars so the paper reaches the screen edge.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  try {
    await DesktopWindow.instance.init(args);
    _boot('desktop window ready');
  } catch (error) {
    _boot('desktop window failed: $error');
  }
  final controller = PlannerController(storage: DeviceStore());
  try {
    await controller.initialize();
    _boot('controller ready');
  } catch (error) {
    _boot('controller failed: $error');
  }
  final reminders = ReminderService(
    controller: controller,
    driver: NativeReminderDriver(),
  );
  final updates = UpdateService(
    controller: controller,
    platform: createUpdatePlatform(),
  );
  String? token;
  try {
    token = await readDesktopToken(args);
    _boot('token ${token == null ? 'absent' : 'present'}');
  } catch (error) {
    _boot('token failed: $error');
  }
  // An explicit desktop token keeps the legacy single-user desktop path; every
  // other launch goes through the account gate (login page or /me check).
  runApp(
    PlannerApp(
      controller: controller,
      reminders: reminders,
      updates: updates,
      requireLogin: token == null,
    ),
  );
  _boot('runApp returned');
  unawaited(reminders.initialize());
  if (token != null) {
    unawaited(controller.connect('http://127.0.0.1:8787', token));
  }
}
