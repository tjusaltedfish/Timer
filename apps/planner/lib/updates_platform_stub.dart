abstract class UpdatePlatform {
  bool get supported;
  Future<String> downloadDir();
  Future<void> save(String path, Stream<List<int>> bytes);
  Future<String> sha256(String path);
  Future<void> delete(String path);
  Future<bool> canInstall();
  Future<void> openInstallSettings();
  Future<void> install(String path);
}

/// Windows (updated by tools/release.ps1) and Web cannot install updates.
class UnsupportedUpdates implements UpdatePlatform {
  @override
  bool get supported => false;
  Never _no() => throw UnsupportedError('这个平台不支持在 App 内安装更新');
  @override
  Future<String> downloadDir() async => _no();
  @override
  Future<void> save(String path, Stream<List<int>> bytes) async => _no();
  @override
  Future<String> sha256(String path) async => _no();
  @override
  Future<void> delete(String path) async {}
  @override
  Future<bool> canInstall() async => false;
  @override
  Future<void> openInstallSettings() async {}
  @override
  Future<void> install(String path) async => _no();
}

UpdatePlatform createUpdatePlatform() => UnsupportedUpdates();
