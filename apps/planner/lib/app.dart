import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'controller.dart';
import 'home.dart';
import 'reminders.dart';
import 'theme/ink_theme.dart';

class PlannerApp extends StatelessWidget {
  const PlannerApp({super.key, required this.controller, this.reminders});
  final PlannerController controller;
  final ReminderService? reminders;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '日程之间',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
    theme: buildInkTheme(Brightness.light),
    darkTheme: buildInkTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: PlannerHome(controller: controller, reminders: reminders),
  );
}
