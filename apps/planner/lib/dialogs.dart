import 'package:flutter/material.dart';

import 'widgets/ink_sheet.dart';

/// Caps a dialog body so the action row (「保存安排」之类) stays on screen.
///
/// Sheets are presented inside a scroll view on phones, so an unbounded body
/// (time wheels + duration chips) can push the buttons below the fold; capping
/// the body turns that into "the fields scroll, the buttons stay put".
BoxConstraints sheetBodyConstraints(BuildContext context) {
  final height = MediaQuery.sizeOf(context).height;
  return BoxConstraints(maxHeight: (height * .55).clamp(220.0, 520.0));
}

/// Callers may own form controllers; release them only after the route is unmounted.
Future<T?> showOwnedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final ModalRoute<T> route = MediaQuery.sizeOf(context).width < 600
      ? ModalBottomSheetRoute<T>(
          isScrollControlled: true,
          useSafeArea: true,
          capturedThemes: InheritedTheme.capture(
            from: context,
            to: Navigator.of(context).context,
          ),
          builder: (_) => InkSheet(builder: builder),
        )
      : DialogRoute<T>(context: context, builder: builder);
  final result = await Navigator.of(context).push(route);
  await route.completed;
  return result;
}
