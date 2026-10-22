import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'controller.dart';
import 'home.dart';
import 'pages/auth_gate.dart';
import 'reminders.dart';
import 'updates.dart';
import 'theme/ink_theme.dart';

class PlannerApp extends StatelessWidget {
  const PlannerApp({
    super.key,
    required this.controller,
    this.reminders,
    this.updates,
    this.requireLogin = false,
  });
  final PlannerController controller;
  final ReminderService? reminders;
  final UpdateService? updates;

  /// When true, an account session is required and the login page is shown
  /// until [PlannerController.authenticated] holds. Desktop-token/pairing mode
  /// keeps using the planner directly (default false) for compatibility.
  final bool requireLogin;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '瞬时',
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
    home: requireLogin
        ? AuthGate(
            controller: controller,
            reminders: reminders,
            updates: updates,
          )
        : PlannerHome(
            controller: controller,
            reminders: reminders,
            updates: updates,
          ),
  );
}
