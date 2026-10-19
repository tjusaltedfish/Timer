import 'package:flutter/material.dart';

/// "Ink blooming on white paper" palette (v3, 2026-10-19).
///
/// Still black-and-white: every ink is a near-neutral grey whose channels
/// differ by at most 6 (checked in tests) (a faint pine-soot warmth). Paper is pure white.
/// Body contrast >= 4.5:1 is enforced in tests.
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
    required this.marks,
    required this.bloom,
  });
  final Color paper,
      paperRaised,
      inkJiao,
      inkNong,
      inkZhong,
      inkDan,
      inkQing,
      line,
      accent,
      bloom;

  /// Category marks, assigned to the user's categories in creation order.
  final List<Color> marks;

  /// Thin ink wash used for selected / tonal surfaces.
  Color get wash => inkJiao.withValues(alpha: .055);
  Color get washStrong => inkJiao.withValues(alpha: .09);
  Color get inquiryWash => accent.withValues(alpha: .07);

  /// Soft halo under raised paper: ink bleeding into the sheet, never a hard drop.
  List<BoxShadow> get halo => [
    BoxShadow(
      color: bloom.withValues(alpha: .075),
      blurRadius: 30,
      spreadRadius: -8,
      offset: const Offset(0, 12),
    ),
    BoxShadow(
      color: bloom.withValues(alpha: .04),
      blurRadius: 6,
      offset: const Offset(0, 1),
    ),
  ];

  static const light = InkPalette(
    paper: Color(0xFFFFFFFF),
    paperRaised: Color(0xFFFFFFFF),
    inkJiao: Color(0xFF23211F),
    inkNong: Color(0xFF3A3734),
    inkZhong: Color(0xFF625F5C), // Body text, ~6.2:1 on white.
    inkDan: Color(0xFF8D8B87), // Decoration / disabled only.
    inkQing: Color(0xFFD2D0CD),
    line: Color(0xFFEFEDEA),
    accent: Color(0xFF2E2B28), // Seal ink.
    bloom: Color(0xFF2A2724),
    marks: [
      Color(0xFF3F3C39),
      Color(0xFF5D5A57),
      Color(0xFF75736F),
      Color(0xFF999693),
    ],
  );
  static const dark = InkPalette(
    paper: Color(0xFF121110),
    paperRaised: Color(0xFF1C1B19),
    inkJiao: Color(0xFFEDEBE8),
    inkNong: Color(0xFFD5D3CF),
    inkZhong: Color(0xFFA6A4A0),
    inkDan: Color(0xFF797673),
    inkQing: Color(0xFF3D3B38),
    line: Color(0xFF2A2826),
    accent: Color(0xFFE2E0DC),
    bloom: Color(0xFF000000),
    marks: [
      Color(0xFFC9C6C3),
      Color(0xFFAFACA9),
      Color(0xFF95928F),
      Color(0xFF7D7A77),
    ],
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
  bool get stillMotion => MediaQuery.disableAnimationsOf(this);
}

abstract final class InkMetrics {
  static const cardRadius = 22.0, sheetRadius = 26.0, controlRadius = 14.0;
  static const micro = Duration(milliseconds: 180);
  static const transition = Duration(milliseconds: 320);
  static const bloom = Duration(milliseconds: 620);
  static const settle = Curves.easeOutCubic;
}
