import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as timezone_data;

import 'bootstrap.dart';
import 'controller.dart';
import 'desktop/desktop_window.dart';
import 'planner_app.dart';
import 'reminders.dart';

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
  runApp(PlannerApp(controller: controller, reminders: reminders));
  unawaited(reminders.initialize());
  final token = await readDesktopToken(args);
  if (token != null) {
    unawaited(controller.connect('http://127.0.0.1:8787', token));
  } else if (controller.configured) {
    unawaited(controller.sync());
  }
}
