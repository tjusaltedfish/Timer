part of '../home.dart';

/// Phone updates published on the paired computer: a quiet bar when a newer
/// build waits there, and a version section in settings.
extension _UpdateBanner on _PlannerHomeState {
  UpdateService? get updates => widget.updates;

  Widget updateBanner() {
    final u = updates;
    if (u == null || !u.supported || !u.available) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Material(
        key: const Key('update.banner'),
        color: u.required ? palette.inquiryWash : palette.wash,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  u.busy
                      ? '${u.status ?? '正在更新'}'
                            '${u.progress == null ? '' : ' ${(u.progress! * 100).round()}%'}'
                      : u.required
                      ? '这个版本太旧了，请更新到 ${u.latest!.version} 后再继续同步。'
                      : '有新版本 ${u.latest!.version}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: u.busy ? null : u.downloadAndInstall,
                child: const Text('下载并安装'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget versionPanel() {
    final u = updates;
    final theme = Theme.of(context);
    final server = u?.serverVersion ?? c.state['server_version'] as String?;
    return SizedBox(
      width: double.infinity,
      child: InkCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '瞬时 ${AppVersion.current}'
              '${server == null ? '' : ' · 电脑后台 $server'}',
              key: const Key('version.text'),
              style: theme.textTheme.bodySmall,
            ),
            if (u != null && u.supported) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: u.busy ? null : u.check,
                    child: const Text('检查更新'),
                  ),
                  if (u.available)
                    FilledButton(
                      onPressed: u.busy ? null : u.downloadAndInstall,
                      child: Text('下载并安装 ${u.latest!.version}'),
                    ),
                ],
              ),
              if (u.progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(
                    value: u.progress,
                    minHeight: 3,
                  ),
                ),
              for (final line in [u.status, u.problem])
                if (line != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(line, style: theme.textTheme.bodySmall),
                  ),
              const SizedBox(height: 10),
              Text(
                '更新包来自已配对的电脑，下载后先校验 SHA-256 再交给系统安装。只能覆盖安装同一调试签名打出的包。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
