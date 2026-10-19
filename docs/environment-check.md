# 环境检查

日期：2026-10-19（用户时区 America/Los_Angeles）。只做了只读检查与项目文件生成，没有安装软件、接受许可证或更改系统配置。

| 项目 | 结果 | 证据/下一步 |
|---|---|---|
| Python | 3.12.11 可用 | `C:\Users\ASUS\anaconda3\envs\pytorch\python.exe`；用于本轮文档与预览 |
| Git | 2.53.0.windows.2 可用 | 当前目录不属于 Git 仓库；未连接远端 |
| Node/npm | 24.14.0 / 11.9.0 可用 | 当前草图无 npm 依赖 |
| Java | Temurin 21.0.9 可用 | 后续检查 Flutter 实际 JDK 与 Gradle 兼容性 |
| Flutter/Dart | PATH 未找到 | FLUTTER_ROOT 未设置；并未穷举磁盘确认不存在 |
| ADB | PATH 未找到 | 默认 Android SDK 目录未发现 |
| Android SDK/Studio | 默认位置未发现 | ANDROID_HOME、ANDROID_SDK_ROOT 未设置；自定义位置待确认 |
| Windows C++ 工具链 | 未验证可用 | cl/cmake 未出现在 PATH，默认 vswhere.exe 路径不存在 |
| FastAPI/Uvicorn/Pydantic/pytest | 指定 Python 未安装 | 正式开发建立项目独立 .venv，不修改研究环境 |
| 手机连接 | 尚未验证 | OPPO Find X8s / ColorOS 17 来自用户说明；未读取设备 |

## 后续步骤

1. 确认是否有其他 SDK 安装位置；缺失时安装 Flutter 稳定版并记录版本。
2. 补齐 Android SDK、Platform Tools、构建工具；用户处理必要许可证与手机授权。
3. Windows 桌面需要 Visual Studio 的 Desktop development with C++ 工作负载；执行前说明安装范围。
4. 创建独立 Python 虚拟环境并锁定依赖。
5. 使用 `flutter doctor -v`、`flutter devices`、`adb devices` 验证，而非只以目录存在判断成功。

当前足够浏览草图，尚无已验证的 Flutter 构建条件。没有新增 MCP/插件前置需求。

## 官方依据

- [Flutter Windows 环境](https://docs.flutter.dev/platform-integration/windows/setup)
- [Flutter 安装](https://docs.flutter.dev/install)
- [Flutter/JDK 排错](https://docs.flutter.dev/install/troubleshoot)
- [Android 提醒](https://developer.android.com/develop/background-work/services/alarms)
- [ColorOS 省电模式](https://support.oppo.com/cn/answer/?aid=SI2105920)
