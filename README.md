# 个人弹性日程助手

让秋招自学、毕业实验代码与 Fab 工艺工作形成「计划 → 执行 → 结果反馈 → 调整 → 归档」的闭环。

当前已进入正式实现：Flutter Android/Windows 工程与 Python 电脑后台已有任务、执行和反馈闭环，Windows 原生构建及隔离后台端到端测试通过。完整初版仍在推进，提醒、助手和 Android 构建未完成，详见 [当前状态](docs/STATUS.md)。

- [蓝图入口](docs/vibe-blueprint/00-index.md)
- [需求验收](docs/vibe-blueprint/02-scope-and-requirements.md)
- [开发任务](docs/vibe-blueprint/08-implementation-plan.md)
- [环境检查](docs/environment-check.md)
- [页面草图](prototype/index.html)：演示数据，刷新恢复。

## 查看草图

直接打开 `prototype/index.html`，或从本目录运行以下命令，再打开 `http://127.0.0.1:8765/prototype/`：

```powershell
& 'C:\Users\ASUS\anaconda3\envs\pytorch\python.exe' -m http.server 8765 --bind 127.0.0.1
```

草图包含今日卡片、周课表、任务详情、结果反馈、重排预览、示例助手和日终回顾。顶部切换手机预览。正式产品目标为 Flutter Android + Windows；HTML 草图用于确认界面与流程。

## 正式代码与验证

- `apps/planner`：Flutter 客户端；`server/app`：电脑常驻后台；`server/tests`：隔离数据测试。
- 后台在 `server` 目录运行 `.\.venv\Scripts\python.exe -m pytest`。
- Flutter 在真实 `apps/planner` 路径执行 `flutter test`；当前 Windows 环境的 `flutter analyze` 使用状态文档中的 ASCII 入口，以避开分析服务器的非 ASCII 路径传输问题。
- 本机原生构建：`tools/build-windows.ps1 -Mode release`。构建脚本使用已准备的用户目录 SDK 与 ATL，不改全局 PATH。
- `tools/test-desktop.ps1 -Fixture <隔离测试配置>` 用于真实 Windows 原生闭环；测试配置包含临时设备凭证，保存在忽略提交的 `artifacts`，不要共享。

当前没有可直接分发的双端发布包；旧 HTML 草图仍只是流程演示，不连接正式数据库。
