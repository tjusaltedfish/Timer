import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/ink_card.dart';
import '../widgets/ink_wheel_picker.dart';
import '../widgets/paper_background.dart';
import '../widgets/seal.dart';
import 'onboarding_controller.dart';

/// First screen after the first login: four basics, then the tour.
///
/// Everything here is local-first. The daily window is queued as a regular
/// settings operation, the profile/onboarding patch is best-effort, so the
/// screen works the same with the computer unreachable.
class BasicSetupPage extends StatefulWidget {
  const BasicSetupPage({super.key, required this.controller});

  final OnboardingController controller;

  @override
  State<BasicSetupPage> createState() => _BasicSetupPageState();
}

class _BasicSetupPageState extends State<BasicSetupPage> {
  static const _zones = [
    'America/Los_Angeles',
    'Asia/Shanghai',
    'Asia/Tokyo',
    'Europe/London',
    'UTC',
  ];

  late final TextEditingController _name;
  late String _timezone;
  late TimeOfDay _start;
  late TimeOfDay _end;
  bool _confirmFirst = false;
  bool _busy = false;
  String? _error;

  OnboardingController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final planner = c.planner;
    _name = TextEditingController(
      text: (planner.user?['display_name'] as String?) ?? '',
    );
    _timezone = (planner.settings['timezone'] as String?) ?? 'UTC';
    if (!_zones.contains(_timezone)) _timezone = _zones.last;
    _start = _parse(planner.settings['day_start'] as String?, 9);
    _end = _parse(planner.settings['day_end'] as String?, 22);
    _confirmFirst = c.confirmFirst;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  static TimeOfDay _parse(String? value, int fallbackHour) {
    final parts = value?.split(':') ?? const [];
    if (parts.length < 2) return TimeOfDay(hour: fallbackHour, minute: 0);
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return TimeOfDay(hour: fallbackHour, minute: 0);
    }
    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }

  static int _minutes(TimeOfDay time) => time.hour * 60 + time.minute;

  static String _format(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  Future<void> _pickStart() async {
    final picked = await pickWheelTime(
      context,
      initial: _start,
      title: '每天几点开始',
    );
    if (picked != null && mounted) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await pickWheelTime(context, initial: _end, title: '每天几点结束');
    if (picked != null && mounted) setState(() => _end = picked);
  }

  Future<void> _skip() async {
    await widget.controller.skipSetup();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '写一个显示名，别人才知道是谁。');
      return;
    }
    if (_minutes(_end) <= _minutes(_start)) {
      setState(() => _error = '结束时间要晚于开始时间。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await c.completeSetup(
      displayName: name,
      timezone: _timezone,
      dayStart: _format(_start),
      dayEnd: _format(_end),
      confirmFirst: _confirmFirst,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    return PaperBackground(
      child: Scaffold(
        backgroundColor: palette.paper.withValues(alpha: 0),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 36, 24, 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Seal('瞬', label: '瞬时', size: 30),
                    const SizedBox(height: 24),
                    Text(
                      '先说说你想怎么用它。',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(color: palette.inkJiao),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '四件小事定下来，之后都会按这个来；想改随时在设置里找。',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: palette.inkZhong),
                    ),
                    const SizedBox(height: 24),
                    _card(
                      title: '怎么称呼你',
                      child: TextField(
                        key: const Key('setup.name'),
                        controller: _name,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: '显示名',
                          hintText: '别人看到的名字',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _card(
                      title: '每天的时间',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButtonFormField<String>(
                            key: const Key('setup.timezone'),
                            initialValue: _timezone,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: '时区'),
                            items: [
                              for (final zone in _zones)
                                DropdownMenuItem(
                                  value: zone,
                                  child: Text(zone),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _timezone = value);
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                key: const Key('setup.start'),
                                onPressed: _busy ? null : _pickStart,
                                child: Text('开始 ${_format(_start)}'),
                              ),
                              OutlinedButton(
                                key: const Key('setup.end'),
                                onPressed: _busy ? null : _pickEnd,
                                child: Text('结束 ${_format(_end)}'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '可安排范围 ${_format(_start)}—${_format(_end)}，之外算休息。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: palette.inkDan),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _card(
                      title: '助手',
                      child: SwitchListTile(
                        key: const Key('setup.confirm'),
                        contentPadding: EdgeInsets.zero,
                        value: _confirmFirst,
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _confirmFirst = value),
                        title: const Text('助手先问再做'),
                        subtitle: const Text('打开后，助手改动日程前会先征求你的意见。'),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        key: const Key('setup.error'),
                        style: TextStyle(color: palette.marks.first),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: const Key('setup.submit'),
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('开始使用'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: TextButton(
                        key: const Key('setup.skip'),
                        onPressed: _busy ? null : _skip,
                        child: const Text('先跳过，稍后在设置里改'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '接下来会用十步带你认一认常用的地方，随时可以跳过。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: palette.inkDan),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card({required String title, required Widget child}) => InkCard(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(color: context.inkPalette.inkNong),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}
