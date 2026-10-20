import 'package:flutter/material.dart';

/// Muted pigments identify tasks; the application chrome keeps its ink palette.
abstract final class ScheduleInk {
  static const light = [
    Color(0xFF2F535B), // 青黛
    Color(0xFF6C4435), // 赭石
    Color(0xFF544866), // 藕紫
    Color(0xFF3E5342), // 松绿
    Color(0xFF6F3D4A), // 胭脂
    Color(0xFF5E4B23), // 秋香
    Color(0xFF394E70), // 花青
    Color(0xFF5C4A3E), // 茶褐
  ];
  static const dark = [
    Color(0xFFA8CFD2),
    Color(0xFFE4B69F),
    Color(0xFFCABAE0),
    Color(0xFFB7CDB0),
    Color(0xFFE5B0BD),
    Color(0xFFDCC791),
    Color(0xFFB2C8EB),
    Color(0xFFD5C3B2),
  ];

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
