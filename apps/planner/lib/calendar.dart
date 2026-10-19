import 'package:timezone/timezone.dart' as tz;

class DaySlice {
  const DaySlice(this.block, this.start, this.end);
  final Map<String, dynamic> block;
  final tz.TZDateTime start;
  final tz.TZDateTime end;
}

List<DaySlice> daySlices(
  List<Map<String, dynamic>> blocks,
  DateTime day,
  tz.Location zone,
) {
  final midnight = tz.TZDateTime(zone, day.year, day.month, day.day);
  final next = tz.TZDateTime(zone, day.year, day.month, day.day + 1);
  final result = <DaySlice>[];
  for (final block in blocks) {
    if (['superseded', 'cancelled'].contains(block['status'])) continue;
    final start = DateTime.parse(block['start_at'] as String);
    final end = DateTime.parse(block['end_at'] as String);
    if (start.isBefore(next) && end.isAfter(midnight)) {
      result.add(
        DaySlice(
          block,
          tz.TZDateTime.from(start.isBefore(midnight) ? midnight : start, zone),
          tz.TZDateTime.from(end.isAfter(next) ? next : end, zone),
        ),
      );
    }
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

List<tz.TZDateTime> localTimeCandidates(
  DateTime day,
  int hour,
  int minute,
  tz.Location zone,
) {
  final wall = DateTime.utc(day.year, day.month, day.day, hour, minute);
  final offsets = <Duration>{};
  for (var h = -48; h <= 48; h++) {
    offsets.add(
      tz.TZDateTime.from(wall.add(Duration(hours: h)), zone).timeZoneOffset,
    );
  }
  final result = <tz.TZDateTime>[];
  for (final offset in offsets) {
    final candidate = tz.TZDateTime.from(wall.subtract(offset), zone);
    if (candidate.year == day.year &&
        candidate.month == day.month &&
        candidate.day == day.day &&
        candidate.hour == hour &&
        candidate.minute == minute) {
      result.add(candidate);
    }
  }
  result.sort();
  return result;
}

String utcOffset(Duration value) {
  final minutes = value.inMinutes.abs();
  return 'UTC${value.isNegative ? '-' : '+'}${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
}
