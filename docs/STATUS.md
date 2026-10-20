# 当前状态

日期：2026-10-19。总体目标：完成 Android + Windows 的个人日程管理初版。尚未达到完整交付条件。

## 仓库与交接入口

- 私有仓库：[tjusaltedfish/Timer](https://github.com/tjusaltedfish/Timer)，分支 `main`，已完成首次推送并核对远程提交一致。
- 产品里程碑 `77882f0`：助手、桌面挂件、分类、睡眠及 v3 界面；环境修复 `8e5bce5`：共享 SDK、缓存和双工具环境入口。
- 当前实现与未验证项以本文为准；任务拆解见 `vibe-blueprint/08-implementation-plan.md`；环境以 `development-environment.md` 为准；当前视觉以 `design/ink-system.md` 为准；学习复盘的已确认设计见 `design/daily-review.md`。

## 一键发布与手机 App 内更新

- 版本唯一来源 `apps/planner/pubspec.yaml`；构建脚本以 `--dart-define=TIMER_VERSION` 注入客户端，后台启动时读取同一文件。`/health` 与快照返回后台版本及最新手机版本；设置页「版本」显示两端版本。
- `tools/release.ps1`：Timer 窗口开着时直接停止；build 号取 pubspec 与已发布版本的较大值加一；构建 Windows release 与安卓 debug、安装电脑版、发布 arm64 APK 到 `<数据目录>/releases`（`latest.json` 含版本、大小、SHA-256、`min_build`，保留两个 APK，不进 Git）；按桌面快捷方式同样的方式（`Start-Timer.ps1 -BackendOnly`）重启后台并核对版本；失败时恢复版本号。
- 后台 `GET /api/v1/app/latest`、`/api/v1/app/download` 需配对凭证（经已有 `^/api/v1/` 隧道规则，不新增公开路径）。安卓：启动与回到前台时检查，顶部提示「下载并安装」，下载后由 Kotlin 计算 SHA-256 校验，再经 FileProvider（仅 cache/updates）调起系统安装器；无安装权限时引导到系统设置；低于 `min_build` 时提示必须更新。
- 验证：后台 74 passed（新增发布 5 项）；Flutter 54 passed（新增更新 6 项）；analyze 无问题；脚本在 PowerShell 5.1 解析通过，Timer 开着时发布脚本不改动任何东西。
- 真实发布（2026-10-19）：`tools/release.ps1` 把版本 1.0.0+1 → **1.0.0+2**，Windows 版已安装，arm64 APK（96,331,501 字节）已发布，后台重启后 `/health` 报告 1.0.0+2。首次运行发现：在输出被管道捕获时，后台进程继承了管道，脚本在重启这一步不退出；已拆出 `tools/restart-backend.ps1`（Start-Process 不继承句柄、只等启动器退出），同条件实测 5 秒返回。
- 外网实测（临时配对设备，用后撤销）：无凭证 401；凭证查到 1.0.0+2；经 `timer.studydazi.top` 下载完整 96,331,501 字节且 SHA-256 一致；撤销后凭证立即 401。
- 手机上当前安装的是更新功能之前的旧包，**需要手动装一次 1.0.0+2**（已放到电脑桌面 `Timer-手机版.apk`），之后才能在 App 内收到更新提示。OPPO 上的下载、权限引导与安装器尚待真机实测。
- 只能在同一调试签名（`%USERPROFILE%\.android\debug.keystore`）下覆盖安装。

## 新增交互入口：微信助手（公众号测试号，已真实接通）

- 用户已明确：电脑登录自己的微信小号，通过普通好友私聊与手机大号交互，承担安排、反馈、主动提醒与每日总结。App 与电脑后台继续保留并共用日程数据。
- 调研与方案见 [微信小号接入](design/wechat-personal-channel.md)。推荐先评估独立 Windows UIA 桥接，首个候选是 pywechat 仓库内的 pyweixin；具体依赖须经小号控件与收发测试后确定。
- 本机只读核查：已安装微信 **4.1.15.13**。wxauto4 上游已标注停止更新；pyweixin 的新版说明提示 UI 树受账号影响；WeChatFerry 原仓库已归档且最近发布配套为微信 3.9.12.51。不能按旧教程直接宣布兼容。
- 电脑不休眠不代表锁屏可发送。小号 UI 可读性、锁屏/最小化/远程桌面、重复消息和目标身份都未验证；当前没有微信桥接或投递队列，也没有发送测试消息。
- 用户确认：走小号好友私聊；电脑不锁屏、不熄屏；授权只读检查。
- **W1 实测（只读）**：用户还原小号窗口后，UIA 控件视图、原始视图与 MSAA 均只看到 Qt 外壳和空的 `MMUIRenderSubWindowHW` 渲染面，没有聊天标题、消息、输入框或发送控件 → pyweixin/wxauto 类读控件方案在本机不兼容。微信不在前台时 PrintWindow 可完整截图；Windows 自带中文 OCR 可用。详见设计文档第 9 节，检查脚本在 `bridge/wechat/`（独立 `.venv`，仅 pywinauto）。
- 后续若继续小号路线，只能是「后台截图 OCR 收消息 + 短暂前台粘贴发送」，准确率和打扰程度待 W2 实测；未发送任何测试消息，未改微信或系统设置。
- **用户决定（W1 之后）**：不走截图 OCR / 模拟输入，改用微信公众平台接口测试号；手机大号关注测试号对话，回调经用户域名 + Cloudflare Tunnel 只开放 `/wechat/callback`。方案见设计文档第 10 节。
- **后台通道已实现（模拟微信服务器验证）**：签名回调、绑定大号、入站去重、「今天/帮助/确认 编号/不必 编号」、助手对话与拟办确认、持久出站队列（48 小时外改发模板、超时记 unknown 不重发、断网退避重试）、设置页「微信助手」。后台 63 passed、Flutter 48 passed、analyze 无问题、真实 HTTP 签名冒烟通过。详见设计文档第 11 节；用户操作步骤见 `guides/wechat-test-account.md`。
- 日常安装：`tools/install-timer.ps1` 把最新 Windows 版装到 `%USERPROFILE%/Apps/Timer` 并在桌面放「Timer」快捷方式；双击时若后台未运行则先隐藏启动后台（127.0.0.1:8787），再开窗口。已实测：快捷方式启动后 `/health` 正常、窗口打开、真实后台 `/api/v1/wechat/config` 可用。
- 接通进展：官方 DeepSeek 已配置并实测（测试连接与 JSON 拟办生成成功；此前中转站因地址缺 /v1 返回网页、且无该模型，已改进相应提示并加「可用模型」）。Cloudflare 隧道 `timer.studydazi.top` 已建，只开放 `/wechat/callback`，外网实测签名校验通过、其他接口 404；启动脚本会同时拉起隧道。
- **真实接通（2026-10-19）**：测试号接口配置提交成功；手机大号已绑定，绑定回复经客服消息实际送达（outbox `sent`）。排查中发现并修复：最初填的 appID 不是关注的测试号（48001 / 40003，现已改为中文提示）；绑定码原先只存内存、后台重启后失效（现存哈希于磁盘，错误码会回复提示）；隧道在本机代理 TUN 模式下 QUIC 不稳（改用 `protocol: http2`）。后台 68 passed。
- 手机同步：用户同意后隧道增开 `/api/v1/`（全部需配对凭证，外网无凭证 401、`/health` `/docs` 仍 404）；配对限流改按 `CF-Connecting-IP` 区分隧道来源（新增测试，后台 69 passed）。最新 arm64 debug APK 已放到电脑桌面，待用户在 OPPO 上安装与配对。
- 待做：大号实际对话与拟办确认的实测；服务端主动提醒与日报调度；后台与隧道开机自启。

## 最新进展：弹性执行与自动微调

- 同日日终回顾版本重复已修复，连续提交保留独立版本及原文；幂等重试不新增版本，旧重复版本记录之后按最大版本继续递增。
- 已接入 session.start 的 keep_duration / keep_end、session.extend、waiting.snooze，以及 interrupted 必填剩余投入。界面提供迟到选择、15/30 分钟续时、检查点改约和中断后重排入口。
- 计时到点后续时不补算未确认的空档；离线事件按真实发生时间重建。等待检查点使用操作 ID 保持离线反馈→改约的身份一致。
- 客户端操作与执行规则已拆到 operations.dart / execution.dart，存储拆到 storage.dart；统一时钟支持边界测试。
- 迟到保留时长、续时或暂停后恢复时，确定性规则可顺延同日的后续弹性安排；每段位移不超过 30 分钟，且作息、截止、依赖与执行历史约束全部满足才自动应用。设置页可关闭自动微调；已应用后显示 10 秒撤销入口，撤销只还原后续安排。
- 较大位移、关闭自动微调或离线事件同步后，先展示调整建议；固定/保护/检查时段、跨日、作息或截止冲突会保留整条原安排并解释原因。离线队列禁止自动替换未来块 ID，保证后续排队的执行操作仍可重放。
- 规则重排和手动新建也考虑当前执行的预计结束时间，避免把续时占用误当空档。操作约定见 `elastic-operations.md`。
- 实际验证：后台 **52 passed**、Flutter **47 passed**、analyze **No issues found**。覆盖手机宽度的迟到/续时/中断/改约、离线重启、提醒替换，以及自动顺延、确认、硬约束、撤销、夏令时与离线批量重放。
- Windows 原生集成 **1 passed**，连接真实隔离后台完成「创建两段 → 开始 → 续时并顺延 → 撤销且保留续时 → 等待反馈 → 检查点改约」。本地证据：`artifacts/elastic-desktop-integration.log` 与 `artifacts/elastic-native-qa/`；截图已检查。测试未写入用户数据库。
- Windows release 和三种 ABI 的 Android debug APK 已重新构建成功，日志为 `artifacts/elastic-windows-build.log`、`artifacts/elastic-android-build.log`；Windows 输出以 `artifacts/windows-preview.json` 指向的目录为准。Android 尚未在 OPPO 安装验收。
- 本地试用文件：`artifacts/Timer-Windows-elastic-preview.zip`（解压后运行，须保留随附 DLL 与 data 目录）和 `artifacts/Timer-Android-arm64-debug.apk`。仅包含客户端，电脑后台仍按现有开发方式独立运行；校验和见 `artifacts/elastic-package-sha256.json`。构建产物不上传 Git。
- 剩余开发：统一问询与自然语言回复、已有块改期、AI 日终复盘与材料/知识回忆，以及常驻备份；真实 API、手机通知和跨网络仍需实际验收。

## 本次环境修复与保存

- 项目当前路径 `C:/Users/ASUS/Documents/Timer`；Claude 的产品进展已保存为提交 `77882f0`。
- 已确认原 SDK/缓存的逻辑 AppData 路径在 Codex 进程中实际指向 `OpenAI.Codex_.../LocalCache/Local`。共享工具链和缓存迁到 `%USERPROFILE%/DevTools/Timer`；`os.path.realpath` 已验证新 SDK 和 meta 包文件没有被重定向。原 SDK 与缓存副本保留。
- `tools/toolchain.json` 固定 Flutter 3.47.7 / Dart 3.13.5 及 Git revision；`tools/dev-environment.ps1` 统一选择 SDK、Pub、Android、Java、ATL，并校验实际 Git HEAD。环境变量仅作用于进程。
- `tools/setup-dev.ps1` 按锁文件恢复依赖、更新 Android 本地 SDK 路径、准备插件联接；`-Clean` 用于改名或工具链迁移后的旧生成配置清理。共享工作区联接为 `%USERPROFILE%/DevTools/Timer/workspace`，目标是当前 Timer 仓库。
- `AGENTS.md`、`CLAUDE.md` 和 `docs/development-environment.md` 提供两端共用规则：不自动升级依赖，不删除或重复安装 SDK/Pub 缓存。
- 新共享环境实测：`flutter doctor -v` 为 **No issues found**；后台 **25 passed**；Flutter **34 passed**；analyze **No issues found**；Windows release、Android 三种 ABI 的 debug APK 均构建成功。记录在忽略提交的 `artifacts/sdk-repair-*.log`。
- 环境修复阶段曾复现同日回顾版本 `1, 2, 2`；现已在后续业务开发中修复，见本文弹性执行基础记录。

## 最新产品与视觉决定

- 视觉改为「墨晕白纸」v3：纯白纸面、墨从角落化开、大圆角、柔光晕、温和文案；仍为黑白（近中性灰，三通道差 ≤ 6）。规范见 `docs/design/ink-system.md`，替代上一版灰阶细线方案。
- 分类完全由用户自己建立、改名、归档；不再内置「毕业代码 / 秋招 / Fab / 个人」四类（那只是开发动机）。任务可以不归类。已有数据中的旧分类保留，可在设置里改名或归档。
- 新增：主动记录睡眠。
- 日终复盘 + 知识回忆：设计选项已确认，见 `docs/design/daily-review.md`；材料读取、AI 复盘、回忆卡片和间隔复习尚未实现。
- 黑名单 / 锁 App 功能已删除，不做。

## 前阶段已实现：v3 界面与助手等

- 主题：新 tokens、主题、墨晕绘制（`widgets/ink_bloom.dart`）、纸面背景、柔和卡片、焦点卡墨晕化开动画、胶囊式轮盘/列表切换。
- 卡片轮盘重写（`widgets/card_wheel.dart`）：卡片定高，只做绘制层变换，拖动跟手；自定义吸附物理（任何轻划都前进一张，只有很用力才跳两张，临界阻尼弹簧缓停）；鼠标滚轮一格一张；修复高度变化后停在两张卡之间的问题；修复卡片压住「此刻」标题、虚化邻卡盖住焦点卡按钮的问题。
- 时间选择：日期 / 时 / 分滚轮（时、分循环），替换 Material 表盘；已过去的时刻淡化划线并自动挪回；鼠标需在滚轮上停留片刻才响应滚轮，避免页面滚动时误改；记录睡眠时同样禁止未来时刻。
- 禁止安排过去：新建表单默认取当前时刻之后，保存前再次校验；助手拟办在生成和确认两处校验。
- 周课表重写：手机横滑多日、左侧时间轴固定；点空白处直接新建（默认一小时），长按拖动圈选一段；过去时段淡化不可点；桌面悬停显示「+ 时间」。桌面今日时间轴同样可点空白新建。
- 外壳与窗口：手机透明状态栏与底部导航和纸面一体；三档自适应（<600 底部导航，600–1000 窄侧栏，≥1000 侧栏 + 双栏）；Windows 无边框窗口 + 纸面标题栏（挂件、置顶、最小化、最大化、关闭），记住位置大小。
- 桌面挂件：一键收成置顶小窗（此刻 + 接下来 + 安排一件事），可调透明度，`--widget` 启动参数直接进入挂件。
- 助手：后台 `server/app/assistant.py` 与 7 个接口（配置、测试连接、对话、历史、拟办确认 / 放下）；OpenAI 兼容（中转站或 DeepSeek），Key 只存电脑数据目录或环境变量、永不返回；模型只见短编号，拟办需「照此办理」后在一个事务里执行并写操作日志。设置页「助手」面板（电脑端可编辑，手机只看状态）；助手页对话与拟办卡片。
- 分类：`project.create` / `project.update` 操作；任务表单与编辑可选「不归类」或新建分类；设置页分类管理；诸事页按分类分组、已毕折叠。
- 睡眠：`sleep.log` / `sleep.delete` 操作；今日页「去睡了 / 醒了」、补记与修改（入睡、醒来、自评、备注）；回顾页近七天平均；日报 Markdown/JSON 增加睡眠一节；助手上下文包含最近一觉。
- 构建脚本：`tools/build-windows.ps1` 不再因 robocopy 返回码误报失败。

## 前阶段验证记录（最新弹性阶段结果见上文）

| 项目 | 结果 |
|---|---|
| Python | 25 passed（含助手 9 项：配置不泄露 Key、手机不能改配置、连接测试、未配置提示、确认后才生效、过去时间与虚构编号被丢弃、短编号改期、非法 JSON 重试、日上限与服务故障；分类与睡眠 2 项） |
| Flutter | 34 passed（含轮盘轻划一张、慢拖吸附、高度变化不停在半页、滚轮不选过去、时刻循环、课表点选与过去拒绝、表单不产生过去安排、分类与睡眠、芯片文字颜色），`artifacts/v3-test.log` |
| 静态检查 | No issues found（ASCII 联接入口） |
| Web | 浏览器实测 375×812 与 1280×820：新建、滚轮选时、课表点空白新建、轮盘居中与轻划；测试数据只写在预览浏览器本地 |
| Windows release | 构建通过，实际启动并截图验证纸面标题栏与 `--widget` 挂件模式（置顶小窗、位置右上） |
| Android | 三种 ABI 的 debug APK 构建通过；正式签名与 OPPO 真机验收待完成 |

未验证：真实模型调用（尚无用户 Key）、OPPO 真机安装与通知、手机与电脑跨网络同步、挂件拖动/透明度滑块的手动操作、深色模式真机观感。

## 工具链入口

- Flutter、Android、ATL 和 Pub 缓存均从 `%USERPROFILE%/DevTools/Timer` 选取；版本和 revision 由 `tools/toolchain.json` 固定。
- 每次切换工具先运行 `tools/setup-dev.ps1`；仅在迁移或确认生成路径过期时加 `-Clean`。详细说明与命令见 `development-environment.md`。
- 最早的环境缺失记录及旧 AppData 路径保留在 Git 历史中，不再作为当前安装或构建指令。

## 下一步

以下功能仍需继续实现或验收：

1. 按已确认的 `docs/design/daily-review.md` 实现材料收集、AI 复盘、回忆卡片与间隔复习。
2. 用户在电脑端「设置 · 助手」填写服务地址、模型名、Key，跑一次「测试连接」和一次真实对话。
3. OPPO 真机：安装 APK、通知权限、ColorOS 后台；跨网络连接（Cloudflare Tunnel，需用户操作域名与账号）。
4. 统一问询队列与自然语言反馈、已有块的表单/拖动改期、托盘常驻、开机自启及备份恢复。续时、迟到模式、检查点改约和一级微调已实现，见本文最新记录。
