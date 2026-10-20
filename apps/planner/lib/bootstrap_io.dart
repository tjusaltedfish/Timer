import 'dart:io';

Future<String?> readDesktopToken(List<String> args) async {
  if (!Platform.isWindows) return null;
  final flag = args.indexOf('--desktop-token-file');
  // Same folder as the computer backend, kept out of AppData because
  // packaged apps redirect AppData writes into private copies.
  final root =
      Platform.environment['PLANNER_DATA_DIR'] ??
      '${Platform.environment['USERPROFILE']}\\TimePlanner\\data';
  final file = File(
    flag >= 0 && args.length > flag + 1
        ? args[flag + 1]
        : '$root\\desktop-token',
  );
  if (!await file.exists()) return null;
  return (await file.readAsString()).trim();
}
