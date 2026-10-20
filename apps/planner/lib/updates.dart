import 'dart:async';

import 'package:flutter/foundation.dart';

import 'controller.dart';
import 'updates_platform.dart';

export 'updates_platform.dart' show UpdatePlatform, createUpdatePlatform;

/// `1.2.3+45`: the build number is the Android versionCode.
@immutable
class AppVersion {
  const AppVersion(this.name, this.build);
  final String name;
  final int build;

  /// Injected by tools/build-*.ps1 from pubspec.yaml (`--dart-define`).
  static const raw = String.fromEnvironment(
    'TIMER_VERSION',
    defaultValue: '0.0.0+0',
  );
  static final current = parse(raw);

  static AppVersion parse(String? text) {
    final match = RegExp(r'^(\d+\.\d+\.\d+)\+(\d+)$').firstMatch(text ?? '');
    return match == null
        ? const AppVersion('0.0.0', 0)
        : AppVersion(match.group(1)!, int.parse(match.group(2)!));
  }

  @override
  String toString() => '$name+$build';
}

@immutable
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.build,
    required this.size,
    required this.sha256,
    required this.minBuild,
  });
  final String version, sha256;
  final int build, size, minBuild;

  static UpdateInfo? fromJson(Object? value) {
    if (value is! Json) return null;
    final version = AppVersion.parse(value['version'] as String?);
    if (version.build == 0 || value['sha256'] is! String) return null;
    return UpdateInfo(
      version: version.toString(),
      build: version.build,
      size: (value['size'] as num?)?.toInt() ?? 0,
      sha256: (value['sha256'] as String).toLowerCase(),
      minBuild: (value['min_build'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Learns about phone releases from the paired computer (snapshot and
/// /api/v1/app/latest), downloads one with the device token, checks its
/// SHA-256, and only then hands it to the Android installer.
class UpdateService extends ChangeNotifier {
  UpdateService({
    required this.controller,
    required this.platform,
    AppVersion? current,
  }) : current = current ?? AppVersion.current {
    controller.addListener(_fromSnapshot);
    _fromSnapshot();
  }

  final PlannerController controller;
  final UpdatePlatform platform;
  final AppVersion current;
  UpdateInfo? latest;
  String? status, problem;
  double? progress;
  bool busy = false;

  bool get supported => platform.supported;

  /// A newer phone build is waiting on the computer.
  bool get available => latest != null && latest!.build > current.build;

  /// The computer says this build is too old to keep using.
  bool get required => latest != null && latest!.minBuild > current.build;

  String? get serverVersion => controller.state['server_version'] as String?;

  void _fromSnapshot() {
    final info = UpdateInfo.fromJson(controller.state['app_latest']);
    if (info?.build != latest?.build || info?.minBuild != latest?.minBuild) {
      latest = info;
      notifyListeners();
    }
  }

  /// Explicit check (start-up, settings): asks the computer directly.
  Future<void> check() async {
    if (!controller.configured) return;
    try {
      latest = UpdateInfo.fromJson(
        await controller.request('GET', '/api/v1/app/latest'),
      );
      problem = null;
      status = available ? null : '已是最新版本';
    } on ApiFailure catch (error) {
      if (error.status == 404) {
        latest = null;
        status = '电脑上还没有发布手机版安装包';
      } else {
        problem = error.message;
      }
    } catch (_) {
      problem = '暂时连不上电脑，稍后再检查更新。';
    }
    notifyListeners();
  }

  Future<void> downloadAndInstall() async {
    final target = latest;
    if (target == null || busy || !supported) return;
    busy = true;
    problem = null;
    progress = 0;
    status = '正在下载 ${target.version}…';
    notifyListeners();
    String? path;
    try {
      if (!await platform.canInstall()) {
        problem = '需要先允许「瞬时」安装应用：已打开系统设置，打开开关后返回再点一次。';
        await platform.openInstallSettings();
        return;
      }
      path =
          '${await platform.downloadDir()}/timer-${target.version.replaceAll('+', '-')}.apk';
      final response = await controller.openDownload('/api/v1/app/download');
      final total = target.size > 0 ? target.size : response.contentLength ?? 0;
      var received = 0;
      await platform.save(
        path,
        response.stream.map((chunk) {
          received += chunk.length;
          if (total > 0) {
            final next = (received / total).clamp(0.0, 1.0);
            if (next - (progress ?? 0) >= .02 || next == 1) {
              progress = next;
              notifyListeners();
            }
          }
          return chunk;
        }),
      );
      status = '正在校验安装包…';
      notifyListeners();
      if (await platform.sha256(path) != target.sha256) {
        await platform.delete(path);
        problem = '安装包校验失败（可能下载不完整），已删除，请重新下载。';
        return;
      }
      await platform.install(path);
      status = '已打开系统安装器，按提示「更新」即可。';
    } on ApiFailure catch (error) {
      problem = error.message;
    } catch (error) {
      problem = '下载没有完成：$error';
      if (path != null) unawaited(platform.delete(path));
    } finally {
      busy = false;
      progress = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_fromSnapshot);
    super.dispose();
  }
}
