import 'dart:io';

import 'package:flutter/services.dart';

import 'updates_platform_stub.dart' show UpdatePlatform, UnsupportedUpdates;

export 'updates_platform_stub.dart' show UpdatePlatform;

/// Android: files under the app cache's updates/ folder, shared with the
/// system installer through FileProvider (see MainActivity.kt).
class _AndroidUpdates implements UpdatePlatform {
  static const _channel = MethodChannel('timer/updates');
  @override
  bool get supported => Platform.isAndroid;
  @override
  Future<String> downloadDir() async =>
      (await _channel.invokeMethod<String>('downloadDir'))!;
  @override
  Future<void> save(String path, Stream<List<int>> bytes) async {
    final sink = File(path).openWrite();
    try {
      await sink.addStream(bytes);
    } finally {
      await sink.close();
    }
  }

  @override
  Future<String> sha256(String path) async =>
      (await _channel.invokeMethod<String>('sha256', {'path': path}))!;
  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;
  @override
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');
  @override
  Future<void> install(String path) =>
      _channel.invokeMethod<void>('install', {'path': path});
}

UpdatePlatform createUpdatePlatform() =>
    Platform.isAndroid ? _AndroidUpdates() : UnsupportedUpdates();
