import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class SyncDot extends StatelessWidget {
  const SyncDot({
    super.key,
    required this.connected,
    required this.syncing,
    required this.pending,
    this.conflict,
    this.error,
    required this.onTap,
  });
  final bool connected, syncing;
  final int pending;
  final String? conflict, error;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final label = conflict != null
        ? '同步冲突'
        : syncing
        ? '正在同步'
        : pending > 0
        ? '$pending 条待同步'
        : connected
        ? '已同步'
        : '本地记录';
    return Tooltip(
      message: '$label${error == null ? '' : '，$error'}',
      child: Semantics(
        label: label,
        button: true,
        child: IconButton(
          onPressed: onTap,
          icon: syncing
              ? SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1,
                    color: p.inkZhong,
                  ),
                )
              : Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: conflict != null
                        ? p.accent
                        : connected
                        ? p.inkZhong
                        : null,
                    border: Border.all(
                      color: conflict != null ? p.accent : p.inkZhong,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
