import 'dart:io';

Future<String?> readDesktopToken(List<String> args) async {
  if (!Platform.isWindows) return null;
  final flag = args.indexOf('--desktop-token-file');
  final root =
      Platform.environment['PLANNER_DATA_DIR'] ??
      '${Platform.environment['LOCALAPPDATA']}\\TimePlanner\\data';
  final file = File(
    flag >= 0 && args.length > flag + 1
        ? args[flag + 1]
        : '$root\\desktop-token',
  );
  if (!await file.exists()) return null;
  return (await file.readAsString()).trim();
}
