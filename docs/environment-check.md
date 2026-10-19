# 当前环境检查

日期：2026-10-19（用户时区 America/Los_Angeles）。项目已更名为 `C:/Users/ASUS/Documents/Timer`。

| 项目 | 当前实测结果 | 入口或证据 |
|---|---|---|
| Flutter / Dart | 3.47.7 / 3.13.5，doctor 无问题 | `tools/toolchain.json` 固定 Git revision |
| 共享 SDK 与 Pub 缓存 | 实际物理路径未被 AppData 重定向 | `%USERPROFILE%/DevTools/Timer`；见共同开发环境说明 |
| Android SDK | platform 36、build-tools 36.0.0，许可已接受 | 共享根目录 `toolchains/android-sdk`；Android debug 三种 ABI 构建通过 |
| Java | Temurin 21.0.9 可用 | 由共享环境入口选择 |
| Windows C++ / ATL | VS Build Tools 2022 与用户目录 ATL 可用 | Windows release 构建通过 |
| Python / 后台 | 项目独立 .venv 可用，25 项测试通过 | `server/.venv/Scripts/python.exe -m pytest` |
| Flutter 代码检查 | 34 项测试通过，analyze 无问题 | `artifacts/sdk-repair-flutter-test.log`、`sdk-repair-analyze.log` |
| Git | main 已推送私有仓库 | [tjusaltedfish/Timer](https://github.com/tjusaltedfish/Timer) |
| OPPO 真机 | 安装、锁屏提醒、省电和移动网络尚未验收 | 不以桌面或 Mock 测试替代 |
| 真实模型 | 尚未由用户填写真实服务配置并实测 | 目前通过 Mock 验证接口与拟办行为 |

## 使用方式

日常先运行 `./tools/setup-dev.ps1`。仅在迁移或发现旧生成路径时使用 `-Clean`。SDK 版本、依赖锁文件、Android 路径和插件联接统一由项目脚本维护。

完整说明见 [共同开发环境](development-environment.md)，最新实现与剩余功能见 [当前状态](STATUS.md)。`artifacts` 内日志不提交 Git；已验证结果摘要保存在状态文档。

最初的只读检查、旧目录和缺失记录可从 Git 历史查看，当前环境已完成准备。后续不得根据旧快照重复安装 SDK、升级依赖或修改研究 Python 环境。
