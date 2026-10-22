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

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  // Draw behind transparent system bars so the paper reaches the screen edge.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  await DesktopWindow.instance.init(args);
  final controller = PlannerController(storage: DeviceStore());
  await controller.initialize();
  final reminders = ReminderService(
    controller: controller,
    driver: NativeReminderDriver(),
  );
  final updates = UpdateService(
    controller: controller,
    platform: createUpdatePlatform(),
  );
  final token = await readDesktopToken(args);
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
  unawaited(reminders.initialize());
  if (token != null) {
    unawaited(controller.connect('http://127.0.0.1:8787', token));
  }
}
