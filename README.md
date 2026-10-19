# 个人弹性日程助手

让秋招自学、毕业实验代码与 Fab 工艺工作形成「计划 → 执行 → 结果反馈 → 调整 → 归档」的闭环。

当前已进入正式实现：Flutter Android/Windows 客户端与 Python 电脑后台已有任务、执行和反馈闭环。界面采用[墨晕白纸](docs/design/ink-system.md)风格，支持卡片轮盘、点选时段新建、滚轮选时、Windows 桌面置顶挂件、睡眠记录和可配置的 AI 助手（OpenAI 中转站或 DeepSeek，Key 只存在电脑上）。日终复盘与知识回忆见[设计稿](docs/design/daily-review.md)。完整初版仍在推进，详见[当前状态](docs/STATUS.md)。

- [接手开发指导（技术 + 水墨审美，优先阅读）](docs/HANDOFF.md)
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

- 环境入口：先运行 `./tools/setup-dev.ps1`；移动或改名后运行一次 `./tools/setup-dev.ps1 -Clean`。详见[共同开发环境](docs/development-environment.md)。Codex 与 Claude 共用 `%USERPROFILE%/DevTools/Timer` 下的工具链和包缓存。
- `apps/planner`：Flutter 客户端；`server/app`：电脑常驻后台；`server/tests`：隔离数据测试。
- 后台在 `server` 目录运行 `.\.venv\Scripts\python.exe -m pytest`。
- Flutter 测试和静态检查在英文目录 `apps/planner` 执行；初始化方式和完整命令见共同开发环境说明。
- 本机原生构建：`tools/build-windows.ps1 -Mode release`。构建脚本使用已准备的用户目录 SDK 与 ATL，不改全局 PATH。
- Android 验证包：`tools/build-android.ps1 -Mode debug`，OPPO 使用 `apps/planner/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`。正式个人签名配置仍待完成。
- `tools/test-desktop.ps1 -Fixture <隔离测试配置>` 用于真实 Windows 原生闭环；测试配置包含临时设备凭证，保存在忽略提交的 `artifacts`，不要共享。

当前没有可直接分发的双端发布包；旧 HTML 草图仍只是流程演示，不连接正式数据库。
