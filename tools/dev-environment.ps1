# Shared, process-local environment for every development entry point.
function Initialize-PlannerEnvironment {
    $taskDevRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $taskDevPin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
    $taskDevShared = Join-Path $env:USERPROFILE $taskDevPin.sharedDirectory
    $taskDevTools = Join-Path $taskDevShared 'toolchains'
    $taskDevFlutterRoot = Join-Path $taskDevTools 'flutter'
    $taskDevFlutter = Join-Path $taskDevFlutterRoot 'bin\flutter.bat'
    $taskDevVersionFile = Join-Path $taskDevFlutterRoot 'bin\cache\flutter.version.json'
    if (-not (Test-Path -LiteralPath $taskDevFlutter)) {
        throw 'Shared Flutter SDK is missing. See docs/development-environment.md; do not install a second SDK.'
    }
    if (Test-Path -LiteralPath $taskDevVersionFile) {
        $taskDevVersion = Get-Content -LiteralPath $taskDevVersionFile -Raw | ConvertFrom-Json
    } else {
        $taskDevVersion = (& $taskDevFlutter --version --machine | Out-String) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Could not read Flutter SDK version.' }
    }
    if ($taskDevVersion.frameworkVersion -ne $taskDevPin.flutter -or
        $taskDevVersion.dartSdkVersion -ne $taskDevPin.dart -or
        $taskDevVersion.frameworkRevision -ne $taskDevPin.frameworkRevision) {
        throw 'Flutter SDK differs from tools/toolchain.json. Resolve the version mismatch; do not upgrade automatically.'
    }
    $taskDevHead = & git -C $taskDevFlutterRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $taskDevHead -ne $taskDevPin.frameworkRevision) {
        throw 'Flutter Git revision differs from tools/toolchain.json; cached version metadata is not sufficient.'
    }
    $env:PUB_CACHE = Join-Path $taskDevShared 'pub-cache'
    $env:ANDROID_HOME = Join-Path $taskDevTools 'android-sdk'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    # Flutter's saved android-sdk setting has higher priority than ANDROID_HOME.
    $taskDevSettingsFile = Join-Path $env:APPDATA '.flutter_settings'
    if (Test-Path -LiteralPath $taskDevSettingsFile) {
        $taskDevSettings = Get-Content -LiteralPath $taskDevSettingsFile -Raw | ConvertFrom-Json
        if ($taskDevSettings.'android-sdk' -and
            [IO.Path]::GetFullPath($taskDevSettings.'android-sdk').TrimEnd('\', '/') -ne $env:ANDROID_HOME) {
            & $taskDevFlutter config --android-sdk $env:ANDROID_HOME | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not align the saved Android SDK selection.' }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $taskDevPin.javaDirectory 'bin\java.exe')) {
        $env:JAVA_HOME = $taskDevPin.javaDirectory
    }
    foreach ($taskDevBin in @((Join-Path $taskDevFlutterRoot 'bin'),
            (Join-Path $taskDevPin.javaDirectory 'bin'), (Join-Path $env:ANDROID_HOME 'platform-tools'))) {
        if ((Test-Path -LiteralPath $taskDevBin) -and ($env:PATH.Split(';') -notcontains $taskDevBin)) {
            $env:PATH = $taskDevBin + ';' + $env:PATH
        }
    }
    $taskDevATL = Join-Path $taskDevTools 'atl\Contents\VC\Tools\MSVC\14.44.35207\atlmfc'
    if (Test-Path -LiteralPath (Join-Path $taskDevATL 'include\atlbase.h')) {
        $env:PLANNER_ATL_ROOT = $taskDevATL
    }
    [pscustomobject]@{
        Root = $taskDevRoot
        App = Join-Path $taskDevRoot 'apps\planner'
        Flutter = $taskDevFlutter
        FlutterRoot = $taskDevFlutterRoot
        Dart = Join-Path $taskDevFlutterRoot 'bin\dart.bat'
        PubCache = $env:PUB_CACHE
        Shared = $taskDevShared
        Android = $env:ANDROID_HOME
        Python = Join-Path $taskDevRoot 'server\.venv\Scripts\python.exe'
        Version = $taskDevVersion.frameworkVersion
    }
}
