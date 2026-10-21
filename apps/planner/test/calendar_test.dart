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
  test('a started block is sliced by its actual interval and keeps its plan', () {
    final zone = tz.getLocation('America/Los_Angeles');
    String at(int day, int hour, int minute) =>
        tz.TZDateTime(zone, 2026, 10, day, hour, minute).toUtc().toIso8601String();
    final blocks = <Map<String, dynamic>>[
      {
        'id': 'b',
        'status': 'scheduled',
        'start_at': at(19, 9, 0),
        'end_at': at(19, 10, 0),
      },
    ];
    final sessions = <Map<String, dynamic>>[
      {
        'id': 's',
        'block_id': 'b',
        'state': 'awaiting_feedback',
        'actual_start_at': at(19, 9, 12),
        'actual_end_at': at(19, 10, 25),
        'expected_end_at': at(19, 10, 25),
      },
    ];
    final slice = daySlices(
      blocks,
      DateTime(2026, 10, 19),
      zone,
      sessions: sessions,
    ).single;
    expect(slice.actual, isTrue);
    expect(slice.start.hour, 9);
    expect(slice.start.minute, 12);
    expect(slice.end.hour, 10);
    expect(slice.end.minute, 25);
    expect(slice.plannedStart!.minute, 0);
    expect(slice.differsFromPlan, isTrue);
  });

  test('overlapping slices share a cluster width while separate ones stay full', () {
    final zone = tz.getLocation('America/Los_Angeles');
    String at(int hour, int minute) =>
        tz.TZDateTime(zone, 2026, 10, 19, hour, minute).toUtc().toIso8601String();
    Map<String, dynamic> block(String id, int h1, int m1, int h2, int m2) => {
      'id': id,
      'status': 'scheduled',
      'start_at': at(h1, m1),
      'end_at': at(h2, m2),
    };
    final slices = daySlices(
      [block('a', 9, 0, 10, 0), block('b', 9, 30, 10, 30), block('c', 11, 0, 12, 0)],
      DateTime(2026, 10, 19),
      zone,
    );
    final lanes = sliceLanes(slices);
    expect(lanes[0].lane, 0);
    expect(lanes[0].lanes, 2);
    expect(lanes[1].lane, 1);
    expect(lanes[1].lanes, 2);
    expect(lanes[2].lane, 0);
    expect(lanes[2].lanes, 1);
  });

  test('nonexistent and ambiguous local times are detected instead of silently shifted', () {
    final zone = tz.getLocation('America/Los_Angeles');
    expect(localTimeCandidates(DateTime(2026, 3, 8), 2, 30, zone), isEmpty);
    final repeated = localTimeCandidates(DateTime(2026, 11, 1), 1, 30, zone);
    expect(repeated.length, 2);
    expect(repeated.last.difference(repeated.first).inMinutes, 60);
    expect(localTimeCandidates(DateTime(2026, 10, 19), 9, 0, zone).length, 1);
  });
}
