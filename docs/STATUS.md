# 当前状态

日期：2026-10-19。总体目标：完成 Android + Windows 的个人日程管理初版。尚未达到完整交付条件。

## 仓库与交接入口

- 私有仓库：[tjusaltedfish/Timer](https://github.com/tjusaltedfish/Timer)，分支 `main`，已完成首次推送并核对远程提交一致。
- 产品里程碑 `77882f0`：助手、桌面挂件、分类、睡眠及 v3 界面；环境修复 `8e5bce5`：共享 SDK、缓存和双工具环境入口。
- 当前实现与未验证项以本文为准；任务拆解见 `vibe-blueprint/08-implementation-plan.md`；环境以 `development-environment.md` 为准；当前视觉以 `design/ink-system.md` 为准；学习复盘的已确认设计见 `design/daily-review.md`。

## 后续开发：弹性执行基础

- 同日日终回顾版本重复已修复，连续提交保留独立版本及原文；幂等重试不新增版本，旧重复版本记录之后按最大版本继续递增。
- 已接入 session.start 的 keep_duration / keep_end、session.extend、waiting.snooze，以及 interrupted 必填剩余投入。界面提供迟到选择、15/30 分钟续时、检查点改约和中断后重排入口。
- 计时到点后续时不补算未确认的空档；离线事件按真实发生时间重建。等待检查点使用操作 ID 保持离线反馈→改约的身份一致。
- 客户端操作与执行规则已拆到 operations.dart / execution.dart，存储拆到 storage.dart；统一时钟支持边界测试。
- 当前后台 35 项、Flutter 43 项测试通过，analyze 无问题。包含手机宽度的迟到/续时/中断/改约、离线重启、计时区间与提醒替换测试。原生打包回归将在本阶段完成后执行。
- 下一切片：确定性小幅顺延、提案与撤销；统一问询、已有块改期等剩余工作继续推进。

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

## 本轮实现

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

## 本轮真实验证

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

以下功能仍需继续实现或验收；续时、迟到模式和检查点改约的基础实现见本文最新记录：

1. 按已确认的 `docs/design/daily-review.md` 实现材料收集、AI 复盘、回忆卡片与间隔复习。
2. 用户在电脑端「设置 · 助手」填写服务地址、模型名、Key，跑一次「测试连接」和一次真实对话。
3. OPPO 真机：安装 APK、通知权限、ColorOS 后台；跨网络连接（Cloudflare Tunnel，需用户操作域名与账号）。
4. HANDOFF 中剩余的弹性操作（续时、检查点改约、一级自动微调）、拖动改期、托盘常驻与开机自启。
