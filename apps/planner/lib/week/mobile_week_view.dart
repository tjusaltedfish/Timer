import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../controller.dart';
import '../formatting.dart';
import '../theme/tokens.dart';
import 'day_overview.dart';

/// 手机的「一周」：默认是选中那天的时间列表，用日期条换天；需要拖动、捏合时
/// 再进「详细课表」。
///
/// 「详细课表」沿用桌面那套 hour 网格，由 [detailBuilder] 注入（固定细节：
/// DST 时间解析、横向滑动仍走 WeekCalendar），这里只负责切换与缩放。
class MobileWeekView extends StatefulWidget {
  const MobileWeekView({
    super.key,
    required this.blocks,
    required this.tasks,
    this.sessions = const [],
    required this.zone,
    required this.now,
    required this.selectedDay,
    required this.weekNav,
    required this.detail,
    required this.onDetailChanged,
    required this.onSelectDay,
    required this.onBlockTap,
    required this.detailBuilder,
    this.onPlan,
    this.summary,
  });

  final List<Json> blocks;
  final List<Json> tasks;
  final List<Json> sessions;
  final tz.Location zone;
  final DateTime now;
  final DateTime selectedDay;

  /// 上一周 / 今天 / 下一周 那一行，由首页提供（保持与桌面一致）。
  final Widget weekNav;

  final bool detail;
  final ValueChanged<bool> onDetailChanged;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;

  /// 详细课表的网格；参数是当前缩放倍数。
  final Widget Function(double zoom) detailBuilder;

  /// 空状态里「排一件事」的入口。
  final VoidCallback? onPlan;

  /// 列表上方的一行本周小结（点开看明细）。
  final Widget? summary;

  static const double minZoom = .75, maxZoom = 2;
  static const String backLabel = '‹ 返回列表';

  @override
  State<MobileWeekView> createState() => _MobileWeekViewState();
}

class _MobileWeekViewState extends State<MobileWeekView> {
  double _zoom = 1;

  // 双指捏合：两根手指的距离变化换算成缩放倍数。
  final _fingers = <int, Offset>{};
  double? _pinchSpread;
  double _pinchZoom = 1;

  double get _spread {
    final points = _fingers.values.toList();
    return (points[0] - points[1]).distance;
  }

  void _fingerDown(PointerDownEvent event) {
    _fingers[event.pointer] = event.position;
    if (_fingers.length == 2) {
      setState(() {
        _pinchSpread = _spread;
        _pinchZoom = _zoom;
      });
    }
  }

  void _fingerMove(PointerMoveEvent event) {
    if (!_fingers.containsKey(event.pointer)) return;
    _fingers[event.pointer] = event.position;
    final from = _pinchSpread;
    if (_fingers.length != 2 || from == null || from < 1) return;
    final next = (_pinchZoom * _spread / from)
        .clamp(MobileWeekView.minZoom, MobileWeekView.maxZoom);
    // 5% 一档，避免每一帧都重排整张课表。
    final stepped = (next * 20).round() / 20;
    if (stepped != _zoom) setState(() => _zoom = stepped);
  }

  void _fingerUp(PointerEvent event) {
    _fingers.remove(event.pointer);
    if (_fingers.length < 2 && _pinchSpread != null) {
      setState(() => _pinchSpread = null);
    }
  }

  DateTime get _day => widget.selectedDay;
  bool get _today => dateKey(_day) == dateKey(widget.now);
  String get _dayLabel => '${_day.month}月${_day.day}日 '
      '${weekdays[_day.weekday - 1]}';

  void _zoomBy(double delta) => setState(() {
        _zoom = (_zoom + delta)
            .clamp(MobileWeekView.minZoom, MobileWeekView.maxZoom)
            .toDouble();
      });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.detail,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 手机返回键先退一层：详细课表 → 当天列表。
        widget.onDetailChanged(false);
      },
      child: widget.detail ? _detail(context) : _list(context),
    );
  }

  Widget _list(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('week.list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.weekNav,
        _DayStrip(
          selected: widget.selectedDay,
          now: widget.now,
          onSelect: widget.onSelectDay,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                '$_dayLabel${_today ? ' · 今天' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            TextButton(
              key: const Key('week.detail.open'),
              onPressed: () => widget.onDetailChanged(true),
              child: const Text('详细课表'),
            ),
          ],
        ),
        ?widget.summary,
        const SizedBox(height: 6),
        Expanded(
          child: DayOverview(
            day: widget.selectedDay,
            now: widget.now,
            blocks: widget.blocks,
            tasks: widget.tasks,
            sessions: widget.sessions,
            zone: widget.zone,
            onBlockTap: widget.onBlockTap,
            onPlan: widget.onPlan,
          ),
        ),
      ],
    );
  }

  Widget _detail(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.inkPalette;
    return SingleChildScrollView(
      key: const Key('week.detail'),
      // 捏合时页面不跟着上下滚。
      physics: _pinchSpread == null
          ? null
          : const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TextButton(
                key: const Key('week.detail.close'),
                onPressed: () => widget.onDetailChanged(false),
                child: const Text(MobileWeekView.backLabel),
              ),
              Expanded(
                child: Text(
                  '$_dayLabel · 详细课表',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (!_today)
                TextButton(
                  key: const Key('week.today'),
                  onPressed: () => widget.onSelectDay(widget.now),
                  child: const Text('今天'),
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('week.zoom.out'),
                  tooltip: '缩小',
                  visualDensity: VisualDensity.compact,
                  onPressed: _zoom > MobileWeekView.minZoom
                      ? () => _zoomBy(-.25)
                      : null,
                  icon: const Icon(Icons.remove, size: 18),
                ),
                Text(
                  '${(_zoom * 100).round()}%',
                  style: TextStyle(fontSize: 11, color: palette.inkZhong),
                ),
                IconButton(
                  key: const Key('week.zoom.in'),
                  tooltip: '放大',
                  visualDensity: VisualDensity.compact,
                  onPressed: _zoom < MobileWeekView.maxZoom
                      ? () => _zoomBy(.25)
                      : null,
                  icon: const Icon(Icons.add, size: 18),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Listener(
            key: const Key('week.detail.pinch'),
            behavior: HitTestBehavior.translucent,
            onPointerDown: _fingerDown,
            onPointerMove: _fingerMove,
            onPointerUp: _fingerUp,
            onPointerCancel: _fingerUp,
            child: widget.detailBuilder(_zoom),
          ),
          const SizedBox(height: 70),
        ],
      ),
    );
  }
}

/// 选中那天所在一周的七天，点一下换到那天。
class _DayStrip extends StatelessWidget {
  const _DayStrip({
    required this.selected,
    required this.now,
    required this.onSelect,
  });

  final DateTime selected, now;
  final ValueChanged<DateTime> onSelect;

  static const _names = '一二三四五六日';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.inkPalette;
    final monday = DateTime(
      selected.year,
      selected.month,
      selected.day - selected.weekday + 1,
    );
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Builder(
              builder: (context) {
                final date = DateTime(monday.year, monday.month, monday.day + i);
                final chosen = dateKey(date) == dateKey(selected);
                final today = dateKey(date) == dateKey(now);
                return Semantics(
                  button: true,
                  selected: chosen,
                  label: '${date.month}月${date.day}日 ${weekdays[i]}',
                  child: InkWell(
                    key: ValueKey('week.day.$i'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onSelect(date),
                    child: Ink(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      decoration: BoxDecoration(
                        color: chosen ? palette.washStrong : null,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: ExcludeSemantics(
                        child: Column(
                          children: [
                            Text(
                              today ? '今' : _names[i],
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${date.day}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight:
                                    chosen ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
