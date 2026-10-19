import 'package:flutter/material.dart';

/// Monochrome ink palette (user direction, 2026-10-19). Body contrast >=4.5:1.
@immutable
class InkPalette {
  const InkPalette({
    required this.paper,
    required this.paperRaised,
    required this.inkJiao,
    required this.inkNong,
    required this.inkZhong,
    required this.inkDan,
    required this.inkQing,
    required this.line,
    required this.accent,
    required this.projects,
  });
  final Color paper,
      paperRaised,
      inkJiao,
      inkNong,
      inkZhong,
      inkDan,
      inkQing,
      line,
      accent;
  final Map<String, Color> projects;
  Color get wash => inkJiao.withValues(alpha: .06);
  Color get inquiryWash => accent.withValues(alpha: .08);
  static const light = InkPalette(
    paper: Color(0xFFF5F5F5),
    paperRaised: Color(0xFFFDFDFD),
    inkJiao: Color(0xFF1C1C1C),
    inkNong: Color(0xFF333333),
    inkZhong: Color(0xFF5E5E5E), // Body text; contrast checked in tests.
    inkDan: Color(0xFF888888), // 3.22:1; decoration / disabled only.
    inkQing: Color(0xFFC6C6C6),
    line: Color(0xFFDADADA),
    accent: Color(0xFF292929), // Body text; contrast checked in tests.
    projects: {
      'code': Color(0xFF454545),
      'learn': Color(0xFF626262),
      'fab': Color(0xFF727272),
      'personal': Color(0xFF808080),
    },
  );
  static const dark = InkPalette(
    paper: Color(0xFF151515),
    paperRaised: Color(0xFF1D1D1D),
    inkJiao: Color(0xFFECECEC),
    inkNong: Color(0xFFD4D4D4),
    inkZhong: Color(0xFFA3A3A3), // Body text; contrast checked in tests.
    inkDan: Color(0xFF757575),
    inkQing: Color(0xFF3A3A3A),
    line: Color(0xFF2C2C2C),
    accent: Color(0xFFD8D8D8), // Body text; contrast checked in tests.
    projects: {
      'code': Color(0xFFBCBCBC),
      'learn': Color(0xFFA8A8A8),
      'fab': Color(0xFF989898),
      'personal': Color(0xFF888888),
    },
  );
}

@immutable
class InkTokens extends ThemeExtension<InkTokens> {
  const InkTokens(this.palette, {this.texture = true});
  final InkPalette palette;
  final bool texture;
  @override
  InkTokens copyWith({InkPalette? palette, bool? texture}) =>
      InkTokens(palette ?? this.palette, texture: texture ?? this.texture);
  @override
  InkTokens lerp(covariant InkTokens? other, double t) =>
      other == null || t < .5 ? this : other;
}

extension InkContext on BuildContext {
  InkPalette get inkPalette => Theme.of(this).extension<InkTokens>()!.palette;
}

abstract final class InkMetrics {
  static const cardRadius = 6.0, controlRadius = 4.0;
  static const micro = Duration(milliseconds: 160);
  static const transition = Duration(milliseconds: 240);
}
