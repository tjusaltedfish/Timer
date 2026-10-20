/// Platform side of in-app updates. Android only; everywhere else (Windows is
/// updated by tools/release.ps1, Web cannot install) `supported` is false.
library;

export 'updates_platform_stub.dart'
    if (dart.library.io) 'updates_platform_io.dart';
