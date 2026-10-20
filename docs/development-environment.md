# 共同开发环境

项目当前目录：`C:/Users/ASUS/Documents/Timer`。脚本根据自身位置寻找项目，可随目录迁移。

## 统一入口

Codex、Claude 或手工终端开始验证前，在项目根目录执行：

```powershell
./tools/setup-dev.ps1
```

该命令校验 `tools/toolchain.json` 中的 Flutter 3.47.7 / Dart 3.13.5 与实际 Git revision，选择已有 SDK 和缓存，以 `flutter pub get --enforce-lockfile` 补齐缺包，并准备 Windows 插件联接。不会自动升级依赖、修改锁文件或重装 SDK；环境变量只在当前进程及其子进程中使用。若 Flutter 用户设置仍保存旧 Android SDK 路径，会通过官方 `flutter config --android-sdk` 对齐到共享 SDK，因为该设置优先于环境变量。

只有改名/移动目录或确认生成文件仍指向旧路径时，执行一次：

```powershell
./tools/setup-dev.ps1 -Clean
```

这会清除项目生成的构建缓存，再恢复依赖，并把 `%USERPROFILE%/DevTools/Timer/workspace` 重新联接到当前目录。SDK、Pub 缓存、后台数据和源码保留。

## 固定位置

| 内容 | 位置 |
|---|---|
| Flutter SDK | `%USERPROFILE%/DevTools/Timer/toolchains/flutter` |
| Pub 缓存 | `%USERPROFILE%/DevTools/Timer/pub-cache` |
| Android SDK | `%USERPROFILE%/DevTools/Timer/toolchains/android-sdk` |
| Java | `tools/toolchain.json` 中已安装的 Temurin 21 |
| 后台 Python | `server/.venv/Scripts/python.exe` |
| 后台数据及模型 Key | 默认 `%USERPROFILE%/TimePlanner/data`，不上传 Git |

`pubspec.lock` 固定包版本及哈希；`.dart_tool`、Flutter ephemeral、`build`、`android/local.properties` 是本机生成配置。它们不可从另一个目录直接复用或提交 Git。SDK 位于项目外，改名不需要重装。

## 验证与构建

```powershell
# 项目根目录
./server/.venv/Scripts/python.exe -m pytest server/tests -q
. ./tools/dev-environment.ps1
$taskEnv = Initialize-PlannerEnvironment
Push-Location $taskEnv.App
& $taskEnv.Flutter test --no-pub
& $taskEnv.Flutter analyze --no-pub
Pop-Location
./tools/build-windows.ps1 -Mode release
./tools/build-android.ps1 -Mode debug
```

如果本机分析服务再次出现路径编码问题，可使用已修复的 ASCII 联接入口。当前 Timer 路径本身已为英文。

## 跨工具缓存缺失的已确认原因

本次在 Codex 中用 `os.path.realpath` 实际检查发现：逻辑位置 `AppData/Local/TimePlanner/toolchains` 与 `AppData/Local/Pub/Cache` 会解析到 `AppData/Local/Packages/OpenAI.Codex_.../LocalCache/Local/` 下。由此可见，在当前 Store 打包应用的进程中，这些路径存在重定向，不能作为两个工具共用物理目录的依据。

共享工具链与缓存改放用户目录下的 `DevTools/Timer`，并通过相同的初始化脚本固定路径。`tools/migrate-shared-toolchain.ps1` 是一次性迁移工具：复制原有 SDK、ATL 和包缓存，保持原副本，并重新生成 Flutter 工具的依赖元数据，不升级 SDK。首次迁移后运行 `setup-dev.ps1 -Clean`。新机器缺少原 SDK 时，先安装 `tools/toolchain.json` 指定 revision 的官方 Flutter，并准备官方 Android SDK，再运行环境入口。

每次切换工具无需重新安装工具链。遇到包不存在时先恢复锁定依赖；遇到旧绝对路径时才清理项目生成缓存。SDK 与应用数据分开管理，默认应用数据仍在 `%USERPROFILE%/TimePlanner/data`。不要删除整个 `%USERPROFILE%/TimePlanner`；`%LOCALAPPDATA%/TimePlanner` 里只剩工具链缓存等旧内容。
