part of '../home.dart';

extension _AdjustmentNotice on _PlannerHomeState {
  void _onAdjustment() {
    if (!mounted || !c.connected) return;
    for (final session in c.sessions.reversed) {
      final info = session['adjustment'] as Json?;
      if (info == null ||
          !['applied', 'proposal', 'blocked'].contains(info['status'])) {
        continue;
      }
      final plan = (c.state['proposals'] as List? ?? [])
          .cast<Json>()
          .where((p) => p['id'] == info['proposal_id'])
          .firstOrNull;
      if (plan == null) continue;
      final status = plan['status'];
      if (status == 'applied') {
        if (plan['applied_revision'] != c.state['revision']) continue;
        final at = DateTime.tryParse(
          plan['applied_at'] ?? plan['created_at'] ?? '',
        );
        if (at == null || c.nowUtc.difference(at).inSeconds > 15) continue;
      } else if (['draft', 'blocked'].contains(status)) {
        if (plan['base_revision'] != c.state['revision'] ||
            !DateTime.parse(plan['expires_at']).isAfter(c.nowUtc)) {
          continue;
        }
      } else {
        continue;
      }
      if (!_seenAdjustments.add('${plan['id']}:$status')) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(
              status == 'applied'
                  ? '${plan['auto'] == true ? '已顺延' : '已调整'} ${(plan['new_blocks'] as List).length} 段'
                  : status == 'blocked'
                  ? '后续安排需要手动确认，原安排已保留。'
                  : '后续安排有一份调整建议，确认后生效。',
            ),
            action: SnackBarAction(
              label: status == 'applied' ? '撤销' : '查看调整',
              onPressed: () => status == 'applied'
                  ? _undoAdjustment(plan)
                  : showPlanProposal(plan),
            ),
          ),
        );
      });
      return;
    }
  }

  Future<void> _undoAdjustment(Json plan) => attempt(() async {
    await c.applyProposal(plan['id'], undo: true);
    message('已撤销时间表顺延；本次实际投入和续时仍保留。');
  });
}
