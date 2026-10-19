import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;
import 'package:time_planner/calendar.dart';

void main() {
  setUpAll(data.initializeTimeZones);
  test(
    'cross-midnight block is visible on both days without duplicating duration',
    () {
      final zone = tz.getLocation('America/Los_Angeles');
      final blocks = <Map<String, dynamic>>[
        {
          'id': 'b',
          'status': 'scheduled',
          'start_at': tz.TZDateTime(
            zone,
            2026,
            10,
            19,
            22,
            30,
          ).toUtc().toIso8601String(),
          'end_at': tz.TZDateTime(
            zone,
            2026,
            10,
            20,
            1,
            30,
          ).toUtc().toIso8601String(),
        },
      ];
      final first = daySlices(blocks, DateTime(2026, 10, 19), zone).single;
      final second = daySlices(blocks, DateTime(2026, 10, 20), zone).single;
      expect(first.end.difference(first.start).inMinutes, 90);
      expect(second.end.difference(second.start).inMinutes, 90);
    },
  );
  test('nonexistent and ambiguous local times are detected instead of silently shifted', () {
    final zone = tz.getLocation('America/Los_Angeles');
    expect(localTimeCandidates(DateTime(2026, 3, 8), 2, 30, zone), isEmpty);
    final repeated = localTimeCandidates(DateTime(2026, 11, 1), 1, 30, zone);
    expect(repeated.length, 2);
    expect(repeated.last.difference(repeated.first).inMinutes, 60);
    expect(localTimeCandidates(DateTime(2026, 10, 19), 9, 0, zone).length, 1);
  });
}
