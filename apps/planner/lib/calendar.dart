import 'package:timezone/timezone.dart' as tz;

class DaySlice {
  const DaySlice(
    this.block,
    this.start,
    this.end, {
    this.session,
    this.plannedStart,
    this.plannedEnd,
  });
  final Map<String, dynamic> block;
  final tz.TZDateTime start;
  final tz.TZDateTime end;

  /// Present once this block has an execution record.
  final Map<String, dynamic>? session;
  final DateTime? plannedStart, plannedEnd;

  bool get actual => session != null;
  bool get differsFromPlan =>
      actual &&
      plannedStart != null &&
      plannedEnd != null &&
      (start != plannedStart || end != plannedEnd);
}

/// The interval a block occupies on paper: the actual interval once it has
/// been started, otherwise its planned one.
({DateTime start, DateTime end}) blockSpan(
  Map<String, dynamic> block,
  Map<String, dynamic>? session,
) {
  final plannedStart = DateTime.parse(block['start_at'] as String);
  final plannedEnd = DateTime.parse(block['end_at'] as String);
  if (session == null) return (start: plannedStart, end: plannedEnd);
  final start =
      DateTime.tryParse(session['actual_start_at'] as String? ?? '') ??
      plannedStart;
  final closed = ['awaiting_feedback', 'closed'].contains(session['state']);
  final end = closed
      ? DateTime.tryParse(session['actual_end_at'] as String? ?? '') ??
            DateTime.parse(session['expected_end_at'] as String)
      : DateTime.parse(session['expected_end_at'] as String);
  return (start: start, end: end.isAfter(start) ? end : plannedEnd);
}

List<DaySlice> daySlices(
  List<Map<String, dynamic>> blocks,
  DateTime day,
  tz.Location zone, {
  List<Map<String, dynamic>> sessions = const [],
}) {
  final midnight = tz.TZDateTime(zone, day.year, day.month, day.day);
  final next = tz.TZDateTime(zone, day.year, day.month, day.day + 1);
  final byBlock = {
    for (final session in sessions) session['block_id']: session,
  };
  final result = <DaySlice>[];
  for (final block in blocks) {
    if (['superseded', 'cancelled'].contains(block['status'])) continue;
    final plannedStart = DateTime.parse(block['start_at'] as String);
    final plannedEnd = DateTime.parse(block['end_at'] as String);
    final session = byBlock[block['id']];
    final span = blockSpan(block, session);
    if (span.start.isBefore(next) && span.end.isAfter(midnight)) {
      result.add(
        DaySlice(
          block,
          tz.TZDateTime.from(
            span.start.isBefore(midnight) ? midnight : span.start,
            zone,
          ),
          tz.TZDateTime.from(span.end.isAfter(next) ? next : span.end, zone),
          session: session,
          plannedStart: plannedStart,
          plannedEnd: plannedEnd,
        ),
      );
    }
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

/// Lanes for drawing overlapping slices side by side: one lane per slice and
/// the number of lanes the slice's overlap cluster needs.
class SliceLane {
  const SliceLane(this.lane, this.lanes);
  final int lane, lanes;
}

List<SliceLane> sliceLanes(List<DaySlice> slices) {
  final laneEnds = <DateTime>[];
  final lanes = <int>[];
  for (final slice in slices) {
    var lane = laneEnds.indexWhere((end) => !end.isAfter(slice.start));
    if (lane < 0) {
      lane = laneEnds.length;
      laneEnds.add(slice.end);
    } else {
      laneEnds[lane] = slice.end;
    }
    lanes.add(lane);
  }
  final widths = List<int>.filled(slices.length, 1);
  var first = 0;
  while (first < slices.length) {
    var last = first, end = slices[first].end;
    while (last + 1 < slices.length && slices[last + 1].start.isBefore(end)) {
      last++;
      if (slices[last].end.isAfter(end)) end = slices[last].end;
    }
    var width = 1;
    for (var i = first; i <= last; i++) {
      width = width < lanes[i] + 1 ? lanes[i] + 1 : width;
    }
    for (var i = first; i <= last; i++) {
      widths[i] = width;
    }
    first = last + 1;
  }
  return [
    for (var i = 0; i < slices.length; i++) SliceLane(lanes[i], widths[i]),
  ];
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
    offsets.add(tz.TZDateTime.from(wall.add(Duration(hours: h)), zone).timeZoneOffset);
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
