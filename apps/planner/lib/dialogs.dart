import 'package:flutter/material.dart';

import 'widgets/ink_sheet.dart';

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
