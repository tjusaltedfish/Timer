part of '../home.dart';

extension _PairSheet on _PlannerHomeState {
  Future<void> pairDialog() async {
    final url = TextEditingController(text: c.serverUrl),
        code = TextEditingController();
    String? error;
    var working = false;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('连接电脑'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('在电脑端生成一次性配对码，输入电脑的私人网络服务地址。'),
                const SizedBox(height: 16),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'http://电脑地址:8787',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: '8 位配对码'),
                ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      setDialog(() => working = true);
                      try {
                        await c.pair(url.text, code.text, '个人客户端');
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        if (context.mounted) {
                          setDialog(() {
                            error = e.toString();
                            working = false;
                          });
                        }
                      }
                    },
              child: Text(working ? '连接中…' : '配对'),
            ),
          ],
        ),
      ),
    );
    url.dispose();
    code.dispose();
  }

  Future<void> pairingCode() async => attempt(() async {
    final value = await c.onlineRequest('/api/v1/pairing/code', {});
    if (mounted) {
      await showOwnedDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('手机配对码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                value['code'],
                style: const TextStyle(fontSize: 32, letterSpacing: 4),
              ),
              const SizedBox(height: 12),
              const Text('5 分钟有效，仅可使用一次。手机需要能访问电脑的服务地址。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  });

  Future<void> conflictDialog() async {
    final confirm = await showOwnedDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('处理同步冲突'),
        content: Text(
          '${c.conflict}\n\n可以重试，或保留完整的本地操作副本，再采用电脑记录。副本不会删除，之后可据此手动补录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后处理'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保留副本并采用电脑记录'),
          ),
        ],
      ),
    );
    if (confirm == true) await attempt(c.preserveConflictAndRefresh);
  }
}
