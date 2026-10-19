# 当前状态

日期：2026-10-19。总体目标：完成 Android + Windows 的个人日程管理初版。尚未达到完整交付条件。

## 最新产品与视觉决定

- 以 HANDOFF 为开发入口，继续执行其中的状态机、助手、连接和验收方案。
- 用户最新指定「黑白风格的简约水墨风」。当前色表为纯灰阶，详细规范见 `docs/design/ink-system.md`，覆盖 HANDOFF 中的彩色视觉建议。
- Android SDK 安装与许可证已获得用户明确授权；模型服务采用可配置的 OpenAI 兼容 API，具体地址、模型名、Key 由用户在电脑本地填写。

## 已实现

- FastAPI / SQLite 权威后台：结果明确的任务、时间块、固定/保护约束、版本控制、执行暂停/恢复/结束、快捷反馈、等待检查点、原文与 Markdown/JSON 日终归档。
- 设备认证、一次性配对与撤销；操作日志、幂等重试；规则重排提案、原子应用、严格版本撤销、过载余量。
- 到点执行段进入待反馈；迟到的离线事件按实际时间重建；等待结果可直接验收。
- Flutter 客户端：今日、周课表、任务、反馈、回顾与连接设置；本地缓存、离线队列、冲突保留、安全令牌存储。
- 本地提醒代码：开始、结束、一次补问、等待检查点、日终；替换旧提醒并保留未回答的问询。原生通知和 ColorOS 后台表现尚未实测。
- 水墨主题：浅色/夜墨色板、文楷标题、系统正文字体、纸纹、墨色印章、笔触、圆相计时、同步墨点。所有 UI 颜色集中为灰阶 token。
- `planner_app.dart` 拆为公开入口；`app.dart` 负责 MaterialApp，`home.dart` 负责状态与外壳，页面/弹层/组件分别位于 `pages/`、`sheets/`、`widgets/`。部分页面仍通过同一 Dart library 的 extension 共享 Home 状态，后续结合控制器具名命令继续收窄耦合。
- 今日轮盘：竖向翻页、焦点清晰、前后卡片渐淡/缩小/模糊；非焦点卡先转到中心；键盘上下与 Enter；列表切换；低矮窗口自适应卡片高度、操作区固定可见；减少动画时关闭模糊、缩放与纸纹。
- 桌面今日双栏时间轴、五项手机导航、页头设置入口、适应键盘的手机底部表单。时间轴每分钟刷新。
- 周课表的跨日切片、夏令时重复/不存在时间处理保留，并统一为灰阶纸墨配色。

## 本次真实验证

| 项目 | 实际结果 / 证据 |
|---|---|
| Python | 14 passed，隔离临时数据库；存在 Starlette/httpx 弃用提示，未隐藏 |
| Flutter | 20 passed；`artifacts/ink-tests.log` |
| 静态检查 | No issues found；`artifacts/ink-analyze.log` |
| Windows 原生闭环 | 1 passed：真实隔离 HTTP 后台 + 原生界面，新建→开始→结束→等待结果；`artifacts/desktop-ink-integration.log`；测试后台已停止 |
| Windows release | 英文实体目录构建通过，`artifacts/windows-ink-release.log`；预览目录与来源见 `artifacts/windows-preview.json`。发布包尚未完成全部运行验收 |
| Android | `tools/build-android.ps1 -Mode debug` 通过；`artifacts/android-ink-final-build.log`。OPPO 对应 `apps/planner/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`，96,028,943 字节 |
| APK 元数据 | aapt2 核对包名 dev.personal.time_planner、名称日程之间、target SDK 36、arm64-v8a；当前为调试签名 |
| Web | 正式 Flutter Web 构建通过；`artifacts/ink-web-build.log` |
| 浏览器 | 真实创建并缓存 3 个验收安排，重载保留；实际检查轮盘、方向键、时间选择器、手机底部表单；控制台无捕获 error/warn |
| 响应式 | 截图 `artifacts/ink-today-360.png`、`ink-today-390.png`、`ink-today-412.png`、`ink-today-1280.png`、`ink-today-1920.png`；焦点正文与按钮无截断/横向溢出 |

Flutter 测试包含灰阶与正文对比度（≥4.5:1）、非焦点卡保护、键盘翻页、减少动画、五种宽度、360px 键盘弹出保存，以及现有同步/日历/提醒回归。测试和浏览器预览中均未调用真实模型。

浏览器预览 `http://127.0.0.1:8788/` 是正式 Flutter 界面。其缓存中的 3 项是验收数据，尚未连接正式后台，不应当作真实日程同步。截图是 Web 响应式验收，不能替代 OPPO 真机证据。

## 工具链与构建方法

- 实际可用：Flutter 3.47.7 / Dart 3.13.5、VS Build Tools 2022、Windows SDK 10.0.26100.0、用户目录 ATL。Flutter revision abaf9c5237。
- Android SDK：`%LOCALAPPDATA%/TimePlanner/toolchains/android-sdk`，platform 36 / build-tools 36.0.0 / NDK 28.2.13676358 / CMake 3.22.1 / platform-tools 37.0.1；doctor 确认许可已接受，日志 `artifacts/doctor-current.log`。新版官方 CLI 为 `android sdk`。
- `flutter test` 在真实项目路径执行，`flutter analyze` 在 `%LOCALAPPDATA%/TimePlanner/workspace/apps/planner` 的 ASCII 联接入口执行。
- Android 在 ASCII 联接下复制资产报错，真实路径加项目级路径检查参数成功；`tools/build-android.ps1` 固化实测命令。脚本 release 模式明确要求后续个人签名配置，不产出伪装的正式包。
- Windows debug 在真实路径构建；release 的 AOT 工具不能读取中文 app.dill 路径。`tools/build-windows.ps1` 使用 `%LOCALAPPDATA%/TimePlanner/b/<id>` 实体副本，并复制原生插件源码供 CMake 使用，绕开该环境的新联接读取问题。输出收集至仓库忽略的 `artifacts/windows-preview-<id>`。
- Python 产品虚拟环境 `server/.venv`；字体与纸纹构建工具依赖单列 `tools/requirements-assets.txt`，没有修改研究环境。字体子集和纸纹均有可重复运行脚本与许可证。

## 里程碑与接续顺序

- M0：现有进展已核对并保存为提交 `81c5566`，工具链已验证。
- M1：黑白设计系统、界面拆分及双端构建完成本轮验证；通用组件继续随问询/周课表细化。
- M2：轮盘、列表、圆相、桌面时间轴已实现并完成组件/浏览器验证；Android profile 流畅度尚未验证。
- 接下来按 HANDOFF 先做 M4（统一问询、迟到/续时/检查点改约、确定性微调与撤销），再做 M3（手机多日密度、拖动与表单改期），随后 M5 助手、M7 连接与真机、M6 自动分析、M8 常驻打包、M9 验收。

## 尚未完成 / 不可声称已验证

- 助手页面仍明确显示未配置；模型调用、拟办、AI 日终分析未实现。真实服务配置尚未由用户填写。
- 新弹性操作 session.extend / waiting.snooze / keep_end、客户端 block.move 乐观更新、一级微调及完整问询队列尚待实现。
- 每日自动分析作业、备份恢复、回顾草稿保存、设备列表管理与托盘常驻仍待完成。
- Cloudflare Tunnel、域名 DNS、手机移动网络配对未配置；电脑后台仍仅监听回环地址。尚无手机实际连通证据。
- ADB 未检测到连接的手机；正式个人签名、真机安装、通知权限、锁屏 30 分钟提醒、ColorOS 后台和轮盘 profile 测试尚未进行。
- 深色主题色板与组件测试已覆盖；深色真实设备视觉走查尚未完成。
