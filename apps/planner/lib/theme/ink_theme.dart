import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildInkTheme(Brightness brightness) {
  final p = brightness == Brightness.light ? InkPalette.light : InkPalette.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.inkJiao,
    onPrimary: p.paper,
    primaryContainer: p.wash,
    onPrimaryContainer: p.inkJiao,
    secondary: p.inkZhong,
    onSecondary: p.paper,
    secondaryContainer: p.wash,
    onSecondaryContainer: p.inkJiao,
    tertiary: p.accent,
    onTertiary: p.paper,
    tertiaryContainer: p.wash,
    onTertiaryContainer: p.inkJiao,
    surface: p.paperRaised,
    onSurface: p.inkNong,
    onSurfaceVariant: p.inkZhong,
    surfaceContainerHighest: p.paper,
    surfaceContainer: p.paperRaised,
    surfaceDim: p.paper,
    surfaceBright: p.paperRaised,
    surfaceContainerLowest: p.paperRaised,
    surfaceContainerLow: p.paperRaised,
    surfaceContainerHigh: p.paper,
    inverseSurface: p.inkNong,
    onInverseSurface: p.paper,
    inversePrimary: p.paper,
    primaryFixed: p.line,
    primaryFixedDim: p.inkQing,
    onPrimaryFixed: p.inkJiao,
    onPrimaryFixedVariant: p.inkNong,
    secondaryFixed: p.line,
    secondaryFixedDim: p.inkQing,
    onSecondaryFixed: p.inkJiao,
    onSecondaryFixedVariant: p.inkNong,
    tertiaryFixed: p.line,
    tertiaryFixedDim: p.inkQing,
    onTertiaryFixed: p.inkJiao,
    onTertiaryFixedVariant: p.inkNong,
    surfaceTint: p.paperRaised,
    outline: p.inkZhong,
    outlineVariant: p.line,
    error: p.accent,
    onError: p.paper,
    errorContainer: p.inquiryWash,
    onErrorContainer: p.accent,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: defaultTargetPlatform == TargetPlatform.windows
        ? 'Microsoft YaHei UI'
        : null,
  );
  TextStyle title(double size, double height) => TextStyle(
    fontFamily: 'WenKai',
    fontFamilyFallback: const ['Microsoft YaHei UI', 'sans-serif'],
    fontSize: size,
    height: height,
    fontWeight: FontWeight.w400,
    color: p.inkJiao,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(InkMetrics.controlRadius),
  );
  return base.copyWith(
    scaffoldBackgroundColor: p.paper,
    extensions: [InkTokens(p)],
    textTheme: base.textTheme
        .apply(bodyColor: p.inkNong, displayColor: p.inkJiao)
        .copyWith(
          displaySmall: title(34, 1.2),
          headlineSmall: title(24, 1.3),
          titleLarge: title(24, 1.3),
          titleMedium: title(18, 1.4),
          bodyLarge: TextStyle(fontSize: 15, height: 1.65, color: p.inkNong),
          bodyMedium: TextStyle(fontSize: 15, height: 1.65, color: p.inkNong),
          bodySmall: TextStyle(fontSize: 12, height: 1.4, color: p.inkZhong),
          labelLarge: TextStyle(
            fontSize: 13,
            height: 1.4,
            fontWeight: FontWeight.w500,
            color: p.inkNong,
          ),
        ),
    splashFactory: InkRipple.splashFactory,
    splashColor: p.wash,
    highlightColor: p.wash,
    hoverColor: p.wash,
    focusColor: p.inkQing,
    dividerColor: p.line,
    dividerTheme: DividerThemeData(color: p.line, thickness: 1),
    iconTheme: IconThemeData(color: p.inkZhong, size: 22),
    cardTheme: CardThemeData(
      color: p.paperRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: p.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.inkJiao,
        foregroundColor: p.paper,
        minimumSize: const Size(44, 48),
        shape: shape,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.inkNong,
        side: BorderSide(color: p.line),
        minimumSize: const Size(44, 48),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.inkNong,
        minimumSize: const Size(44, 48),
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      border: UnderlineInputBorder(borderSide: BorderSide(color: p.line)),
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: p.line),
      ),
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: p.inkJiao, width: 1.5),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.paperRaised,
      surfaceTintColor: p.paperRaised,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.paperRaised,
      surfaceTintColor: p.paperRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: p.paper,
      elevation: 0,
      indicatorColor: p.paper,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 12, color: p.inkZhong),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.paper,
      indicatorColor: p.paper,
      selectedIconTheme: IconThemeData(color: p.inkJiao),
      unselectedIconTheme: IconThemeData(color: p.inkZhong),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.paperRaised,
      selectedColor: p.wash,
      side: BorderSide(color: p.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      labelStyle: TextStyle(color: p.inkNong),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.inkJiao,
      contentTextStyle: TextStyle(color: p.paper),
      shape: shape,
      behavior: SnackBarBehavior.floating,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.inkJiao,
      foregroundColor: p.paper,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: p.paperRaised,
      surfaceTintColor: p.paperRaised,
      headerForegroundColor: p.inkJiao,
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: p.paperRaised,
      dialBackgroundColor: p.paper,
      dialHandColor: p.inkJiao,
      hourMinuteColor: p.wash,
      hourMinuteTextColor: p.inkJiao,
      dayPeriodColor: p.wash,
      dayPeriodTextColor: p.inkJiao,
    ),
  );
}
