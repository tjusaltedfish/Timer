part of '../home.dart';

/// Account section: who is signed in, log out, and change the server address.
/// Device management and password changes are P3; the entry points explain
/// that instead of pretending to work.
extension _AccountSettings on _PlannerHomeState {
  Widget accountPanel() {
    final user = c.user;
    final username = user?['username'] as String? ?? '';
    final display = (user?['display_name'] as String?)?.trim() ?? '';
    final name = display.isNotEmpty
        ? display
        : username.isNotEmpty
        ? username
        : '已登录';
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('账号', style: TextStyle(fontSize: 19)),
          const SizedBox(height: 12),
          if (user != null) ...[
            Text(name, style: const TextStyle(fontSize: 20)),
            if (username.isNotEmpty && username != name) ...[
              const SizedBox(height: 4),
              Text('用户名：$username'),
            ],
            const SizedBox(height: 8),
            Text('服务器：${c.serverUrl}'),
            Text('待同步：${c.pending.length} 条'),
            if (c.connectionError != null) Text(c.connectionError!),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  key: const Key('account.logout'),
                  onPressed: logoutDialog,
                  child: const Text('退出登录'),
                ),
                OutlinedButton(
                  key: const Key('account.server'),
                  onPressed: serverAddressDialog,
                  child: const Text('修改服务器地址'),
                ),
                OutlinedButton(
                  key: const Key('account.devices'),
                  onPressed: () => message('设备管理会在下一版开放。'),
                  child: const Text('设备管理'),
                ),
                OutlinedButton(
                  key: const Key('account.password'),
                  onPressed: () => message('修改密码会在下一版开放，当前请联系站长重置。'),
                  child: const Text('修改密码'),
                ),
              ],
            ),
          ] else ...[
            const Text('本机兼容模式：还没有登录账号。'),
            const SizedBox(height: 8),
            Text('服务器：${c.serverUrl}'),
            const SizedBox(height: 8),
            Text(
              c.requiresLogin
                  ? '登录后可以管理账号；当前没有可用的登录状态。'
                  : '当前通过桌面临时令牌连接。登录账号后，日程会随账号在多台设备之间同步。',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> logoutDialog() async {
    final pending = c.pending.length;
    final confirmed = await showOwnedDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: Text(
          pending == 0
              ? '退出后需要重新输入用户名和密码。本机缓存的日程会被清除。'
              : '还有 $pending 条本地记录没同步。退出登录会清除这些本机记录，建议先「立即同步」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('account.logout-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed == true) await attempt(c.logout);
  }

  Future<void> serverAddressDialog() async {
    final controller = TextEditingController(text: c.serverUrl);
    String? error;
    var working = false;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('服务器地址'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('换服务器会退出当前账号并清除本机缓存的日程，之后需要重新登录。'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('account.server-field'),
                  controller: controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'http://127.0.0.1:8765',
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      error!,
                      key: const Key('account.server-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('account.server-save'),
              onPressed: working
                  ? null
                  : () async {
                      setDialog(() {
                        working = true;
                        error = null;
                      });
                      try {
                        await c.changeServer(controller.text);
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                      } catch (failure) {
                        if (dialogContext.mounted) {
                          setDialog(() {
                            error = failure.toString();
                            working = false;
                          });
                        }
                      }
                    },
              child: Text(working ? '保存中…' : '保存并重新登录'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }
}
