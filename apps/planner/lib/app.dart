import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'controller.dart';
import 'home.dart';
import 'reminders.dart';
import 'updates.dart';
import 'theme/ink_theme.dart';

class PlannerApp extends StatelessWidget {
  const PlannerApp({
    super.key,
    required this.controller,
    this.reminders,
    this.updates,
  });
  final PlannerController controller;
  final ReminderService? reminders;
  final UpdateService? updates;
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
    builder: (context, child) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: const Color(0x00000000),
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: const Color(0x00000000),
          systemNavigationBarDividerColor: const Color(0x00000000),
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        ),
        child: child!,
      );
    },
    home: PlannerHome(
      controller: controller,
      reminders: reminders,
      updates: updates,
    ),
  );
}
