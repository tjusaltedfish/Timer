part of '../home.dart';

extension _SettingsPage on _PlannerHomeState {
  Widget settingsPage() => SingleChildScrollView(
    child: padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('让手机和电脑接上。', '先保留本地记录，连接恢复后再同步。'),
          panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.connected ? '电脑服务已连接' : '当前使用本地记录',
                  style: const TextStyle(fontSize: 20),
                ),
                const SizedBox(height: 12),
                Text('地址：${c.serverUrl}'),
                Text('待同步：${c.pending.length} 条'),
                if (c.connectionError != null) Text(c.connectionError!),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton(
                      onPressed: pairDialog,
                      child: const Text('连接 / 配对电脑'),
                    ),
                    OutlinedButton(
                      onPressed: () => attempt(c.sync),
                      child: const Text('立即同步'),
                    ),
                    if (c.state['device']?['role'] == 'desktop')
                      OutlinedButton(
                        onPressed: pairingCode,
                        child: const Text('生成手机配对码'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          categoriesPanel(),
          const SizedBox(height: 18),
          AssistantSettingsPanel(
            key: ValueKey('assistant-settings-${c.configured}'),
            controller: c,
          ),
          const SizedBox(height: 18),
          WechatSettingsPanel(
            key: ValueKey('wechat-settings-${c.configured}'),
            controller: c,
          ),
          const SizedBox(height: 18),
          versionPanel(),
          const SizedBox(height: 18),
          if (widget.reminders != null) ...[
            panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('提醒与结果追问', style: TextStyle(fontSize: 19)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开始、结束、结果检查和日终提醒'),
                    value: widget.reminders!.enabled,
                    onChanged: (enabled) => attempt(
                      () => enabled
                          ? widget.reminders!.enable()
                          : widget.reminders!.disable(),
                    ),
                  ),
                  Text(widget.reminders!.status),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => attempt(widget.reminders!.test),
                        child: const Text('启用并发送测试提醒'),
                      ),
                      if (widget.reminders!.driver.schedulesInSystem)
                        OutlinedButton(
                          onPressed: () =>
                              attempt(widget.reminders!.requestExact),
                          child: const Text('允许准时提醒'),
                        ),
                      TextButton(
                        onPressed: () => attempt(
                          () => widget.reminders!.refresh(force: true),
                        ),
                        child: const Text('重新检查提醒'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '开始提醒后，结束时询问结果；未反馈时最多补提醒一次。等待结果单独设置检查点。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
          panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('时间设置', style: TextStyle(fontSize: 19)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: c.settings['timezone'],
                  decoration: const InputDecoration(labelText: '日程时区'),
                  items:
                      {
                            c.settings['timezone'] as String,
                            'America/Los_Angeles',
                            'Asia/Shanghai',
                            'UTC',
                          }
                          .map(
                            (z) => DropdownMenuItem(value: z, child: Text(z)),
                          )
                          .toList(),
                  onChanged: (value) => attempt(
                    () => c.submit('settings.update', {'timezone': value}),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '可安排范围 ${c.settings['day_start']}—${c.settings['day_end']}。用餐和休息可通过新建「保护时段」设置。',
                ),
                SwitchListTile(
                  key: const Key('settings.auto-adjust'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许同日小幅顺延'),
                  subtitle: const Text(
                    '后续弹性段每段最多 30 分钟；遇到固定预约、保护时段或约束时先保留原安排。',
                  ),
                  value: c.settings['auto_adjust'] as bool? ?? true,
                  onChanged: (value) => attempt(
                    () => c.submit('settings.update', {'auto_adjust': value}),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => editTimeSetting('day_start'),
                      child: Text('开始 ${c.settings['day_start']}'),
                    ),
                    OutlinedButton(
                      onPressed: () => editTimeSetting('day_end'),
                      child: Text('结束 ${c.settings['day_end']}'),
                    ),
                    OutlinedButton(
                      onPressed: () => editTimeSetting('daily_review_time'),
                      child: Text('日终回顾 ${c.settings['daily_review_time']}'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (c.preservedConflicts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text('已保留 ${c.preservedConflicts.length} 份冲突时的本地副本。'),
            ),
        ],
      ),
    ),
  );

  Future<void> editTimeSetting(String field) async {
    final parts = (c.settings[field] as String)
        .split(':')
        .map(int.parse)
        .toList();
    final value = await pickWheelTime(
      context,
      initial: TimeOfDay(hour: parts[0], minute: parts[1]),
      title: const {
        'day_start': '一天从几点开始安排',
        'day_end': '几点之后不再安排',
        'daily_review_time': '几点做日终回顾',
      }[field]!,
    );
    if (value == null) return;
    await attempt(() async {
      final text =
          '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
      final start = field == 'day_start'
          ? text
          : c.settings['day_start'] as String;
      final end = field == 'day_end' ? text : c.settings['day_end'] as String;
      if (start.compareTo(end) >= 0) throw ApiFailure('结束时间必须晚于开始时间。', 422);
      await c.submit('settings.update', {field: text});
    });
  }
}
