import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as timezone_data;

import 'bootstrap.dart';
import 'controller.dart';
import 'planner_app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  final controller = PlannerController(storage: DeviceStore());
  await controller.initialize();
  runApp(PlannerApp(controller: controller));
  final token = await readDesktopToken(args);
  if (token != null) {
    unawaited(controller.connect('http://127.0.0.1:8787', token));
  } else if (controller.configured) {
    unawaited(controller.sync());
  }
}
