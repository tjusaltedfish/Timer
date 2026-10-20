import 'package:flutter/material.dart';

/// Clear mineral colours that tell tasks apart in the week view. They only
/// mark a block (a thin bar and a flat, faint tint); the text stays in ink.
abstract final class ScheduleInk {
  static const light = [
    Color(0xFFC0473A), // 朱砂
    Color(0xFF2B6CB0), // 石青
    Color(0xFF2E8564), // 石绿
    Color(0xFFA87A12), // 藤黄
    Color(0xFFAD4477), // 胭脂
    Color(0xFF4C55B0), // 靛蓝
    Color(0xFF9E5A33), // 赭石
    Color(0xFF357484), // 黛青
  ];
  static const dark = [
    Color(0xFFF0897D),
    Color(0xFF7DB0F0),
    Color(0xFF6FCFA6),
    Color(0xFFEBC15E),
    Color(0xFFE88BB6),
    Color(0xFF9EA6F4),
    Color(0xFFE3A27C),
    Color(0xFF86C4D2),
  ];

  /// Tint strength of a block's fill over the paper.
  static double tint(Brightness brightness) =>
      brightness == Brightness.dark ? .22 : .14;

  static Color forTask(
    String id,
    List<Map<String, dynamic>> tasks,
    Brightness brightness,
  ) {
    // Soft-deleted tasks stay in this ordered list, so deleting or renaming a
    // neighbour never changes the colour of an existing task.
    var index = tasks.indexWhere((t) => t['id'] == id);
    if (index < 0) {
      index = id.codeUnits.fold(0, (value, c) => (value * 31 + c) & 0x7fffffff);
    }
    final palette = brightness == Brightness.dark ? dark : light;
    return palette[index % palette.length];
  }
}
