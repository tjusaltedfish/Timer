import 'package:flutter/material.dart';

/// Callers may own form controllers; release them only after the route is unmounted.
Future<T?> showOwnedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await Navigator.of(context).push(route);
  await route.completed;
  return result;
}
