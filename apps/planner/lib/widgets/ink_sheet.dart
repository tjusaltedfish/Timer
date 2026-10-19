import 'package:flutter/material.dart';

import 'brush_divider.dart';

/// Retains existing form ownership while presenting it as a keyboard-safe sheet.
class InkSheet extends StatelessWidget {
  const InkSheet({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SingleChildScrollView(
        child: MediaQuery(
          data: media.copyWith(viewInsets: EdgeInsets.zero),
          child: Theme(
            data: Theme.of(context).copyWith(
              dialogTheme: Theme.of(context).dialogTheme.copyWith(
                insetPadding: EdgeInsets.zero,
                alignment: Alignment.topCenter,
                constraints: BoxConstraints(maxWidth: media.size.width),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: BrushDivider(width: 40),
                ),
                Builder(builder: builder),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
