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
    shadow: p.bloom,
    scrim: p.bloom,
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
    letterSpacing: .4,
    color: p.inkJiao,
  );
  final soft = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(InkMetrics.controlRadius),
  );
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(InkMetrics.controlRadius),
    borderSide: BorderSide(color: p.inkJiao.withValues(alpha: 0)),
  );
  return base.copyWith(
    scaffoldBackgroundColor: p.paper,
    canvasColor: p.paper,
    extensions: [InkTokens(p)],
    textTheme: base.textTheme
        .apply(bodyColor: p.inkNong, displayColor: p.inkJiao)
        .copyWith(
          displaySmall: title(34, 1.2),
          headlineSmall: title(26, 1.3),
          titleLarge: title(23, 1.35),
          titleMedium: title(18, 1.4),
          titleSmall: title(15, 1.4),
          bodyLarge: TextStyle(fontSize: 15, height: 1.7, color: p.inkNong),
          bodyMedium: TextStyle(fontSize: 14.5, height: 1.7, color: p.inkNong),
          bodySmall: TextStyle(fontSize: 12.5, height: 1.5, color: p.inkZhong),
          labelLarge: TextStyle(
            fontSize: 14,
            height: 1.4,
            fontWeight: FontWeight.w500,
            letterSpacing: .3,
            color: p.inkNong,
          ),
        ),
    splashFactory: InkRipple.splashFactory,
    splashColor: p.wash,
    highlightColor: p.inkJiao.withValues(alpha: .03),
    hoverColor: p.inkJiao.withValues(alpha: .035),
    focusColor: p.washStrong,
    dividerColor: p.line,
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.inkZhong, size: 22),
    cardTheme: CardThemeData(
      color: p.paperRaised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(InkMetrics.cardRadius),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.inkJiao,
        foregroundColor: p.paper,
        disabledBackgroundColor: p.wash,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: soft,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 14.5, letterSpacing: .4),
      ),
    ),
    // Secondary actions are tonal washes rather than hard outlines.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.inkNong,
        backgroundColor: p.wash,
        side: BorderSide(color: p.wash),
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: soft,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.inkNong,
        minimumSize: const Size(44, 44),
        shape: soft,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.inkZhong,
        minimumSize: const Size(44, 44),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.inkJiao.withValues(alpha: .035),
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      border: field,
      enabledBorder: field,
      focusedBorder: field.copyWith(
        borderSide: BorderSide(
          color: p.inkJiao.withValues(alpha: .35),
          width: 1.2,
        ),
      ),
      labelStyle: TextStyle(color: p.inkZhong),
      floatingLabelStyle: TextStyle(color: p.inkNong),
      hintStyle: TextStyle(color: p.inkDan),
      counterStyle: TextStyle(color: p.inkDan, fontSize: 11),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.paperRaised,
      surfaceTintColor: p.paperRaised,
      modalBarrierColor: p.bloom.withValues(alpha: .18),
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(InkMetrics.sheetRadius),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.paperRaised,
      surfaceTintColor: p.paperRaised,
      barrierColor: p.bloom.withValues(alpha: .18),
      elevation: 0,
      shadowColor: p.bloom,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(InkMetrics.sheetRadius),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.paper.withValues(alpha: 0),
      surfaceTintColor: p.paper.withValues(alpha: 0),
      elevation: 0,
      height: 68,
      indicatorColor: p.washStrong,
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? p.inkJiao : p.inkZhong,
          size: 22,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected) ? p.inkJiao : p.inkZhong,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.paper.withValues(alpha: 0),
      indicatorColor: p.washStrong,
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: IconThemeData(color: p.inkJiao),
      unselectedIconTheme: IconThemeData(color: p.inkZhong),
      selectedLabelTextStyle: TextStyle(color: p.inkJiao, fontSize: 12),
      unselectedLabelTextStyle: TextStyle(color: p.inkZhong, fontSize: 12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.wash,
      selectedColor: p.inkJiao,
      secondarySelectedColor: p.inkJiao,
      side: BorderSide.none,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(color: p.inkNong, fontSize: 13.5),
      secondaryLabelStyle: TextStyle(color: p.paper, fontSize: 13.5),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      side: BorderSide(color: p.inkDan, width: 1.4),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.inkJiao : null,
      ),
      checkColor: WidgetStatePropertyAll(p.paper),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.paper : p.inkDan,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.inkJiao : p.wash,
      ),
      trackOutlineColor: WidgetStatePropertyAll(p.inkJiao.withValues(alpha: 0)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.inkJiao,
      inactiveTrackColor: p.washStrong,
      thumbColor: p.inkJiao,
      overlayColor: p.wash,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.inkZhong,
      linearTrackColor: p.wash,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.inkJiao.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(10),
      ),
      textStyle: TextStyle(color: p.paper, fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.inkJiao,
      contentTextStyle: TextStyle(color: p.paper, fontSize: 14),
      actionTextColor: p.paper,
      shape: soft,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.inkJiao,
      foregroundColor: p.paper,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.paperRaised,
      surfaceTintColor: p.paperRaised,
      elevation: 2,
      shadowColor: p.bloom.withValues(alpha: .25),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      iconColor: p.inkZhong,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: p.paperRaised,
      surfaceTintColor: p.paperRaised,
      headerForegroundColor: p.inkJiao,
    ),
  );
}
