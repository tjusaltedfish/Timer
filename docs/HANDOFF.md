# 接手开发指导：技术方案与水墨审美规范

> 写给接手本项目的 AI 开发者（也给人看）。日期 2026-10-19。
> 开发入口：先读根目录 `AGENTS.md` 和 `docs/STATUS.md`，再读本文的状态表与当前任务相关方案。本文 §4–10 保留详细设计目标，不代表其中能力均已实现；当前视觉、环境和实现差异以对应专项文档与源码为准。
> 本文与旧蓝图冲突时，以本文为准（尤其是视觉部分：旧蓝图的「暖白 + 墨绿」方案已被「简约水墨」替代）。

> **最新用户视觉要求（2026-10-19 续接）**：黑白灰的简约水墨风。实际色表以 `docs/design/ink-system.md` 和 `lib/theme/tokens.dart` 为准；本文后续有关朱砂与淡彩的描述由这条要求覆盖。

> **环境更新（2026-10-19）**：项目已更名为 `C:/Users/ASUS/Documents/Timer`。Codex 的 AppData 工具链路径经实测会发生 Store 应用重定向；共享 SDK、Pub 缓存和工作区联接现位于 `%USERPROFILE%/DevTools/Timer`。环境操作以 `AGENTS.md`、`docs/development-environment.md`、`tools/toolchain.json` 为准，先运行 `tools/setup-dev.ps1`，不要按下文历史记录重复安装 SDK。最新功能进度以 `docs/STATUS.md` 为准。

> **微信路线历史**：曾调研个人小号桌面接入，W1 后用户已改选公众号测试号；当前已接通的正式入口是公众号。路线变更与既有接通证据见 `design/wechat-personal-channel.md`、`guides/wechat-test-account.md`，不要按旧 UIA 方案重复开发。

> **1.1.0+3 续接**：首页时钟/日期、手机整周总览、专注面板、通用编辑删除、执行感知助手与偏好、材料原文复盘、公众号主动调度和通知启用入口已实现并做隔离验证。规则与模板见 [助手机制](design/assistant-behavior.md)。原小号路线已经被用户改为公众号测试号；旧设计细节以专项文档为准。当前正式后台仍为 1.0.0+2，须在正常数据环境激活准备包；不要把 Codex 的 AppData 包缓存当成正式数据库。

---

## 0. 铁律（违反任何一条都算返工）

1. **用户是唯一用户**：纯自用，Android（OPPO Find X8s，ColorOS 17）+ Windows 电脑。不做多用户、不做注册登录、不上架。
2. **电脑端后台是唯一权威数据源**（FastAPI + SQLite）。客户端只有离线缓存与操作队列，绝不另起一套真相。
3. **所有数据修改都走「操作」**（`POST /api/v1/operations`，带 `operation_id` 幂等）。不要新增绕过操作日志的写接口；AI 助手的修改也必须落成同样的操作。
4. **沉默不等于完成**。没有用户明确反馈，任务永远不会自动变成 done。计时到点只能把执行段变成「待反馈」。
5. **AI 只提议，不擅自改日程**。模型输出的修改一律是「拟办（draft）」，用户点确认后才执行。唯一例外见 §6.4 的「一级自动微调」，它是确定性规则，不经过模型。
6. **API Key 只存在电脑上**，不进 Git、不下发到手机、不出现在日志和快照里。
7. **App 黑名单 / 番茄钟锁机功能已被用户删除**，不要实现，也不要申请相关权限（无障碍、使用情况访问、设备管理等）。
8. 每完成一个里程碑：跑完 §11 的验证命令，更新 `docs/STATUS.md`，**只写真实跑过的结果**。没跑过的就写「未验证」。
9. 不要为了让测试通过而删测试或放宽断言；文案改了，就同步改测试里的 finder。
10. 项目当前路径为 `C:/Users/ASUS/Documents/Timer`；工具链与缓存使用共享 DevTools 路径，见 §2.3。

---

## 1. 用户原始需求 → 实现状态对照

| # | 用户需求 | 当前状态 | 剩余工作 |
|---|---|---|---|
| 1 | 七天课表、滑动选择 | 桌面七列、手机横滑多日、点选和圈选新建已实现 | 已有块的表单/拖动及离线改期 |
| 2 | 时间段结束后主动问结果 | 结束与补问提醒、快捷反馈、等待检查点已有 | OPPO 通知实测、统一问询队列与自然语言回复联动 |
| 3 | 迟到、拖延、未完成、等待时弹性调整 | 迟到模式、续时、中断余量、检查点改约、规则重排、一级微调与撤销已有 | 统一问询与自然语言回复联动、完整双端试用 |
| 4 | 状态机 | 任务、执行段、时间块及基础派生显示状态已有 | 完整事件→调整规则与相应测试 |
| 5 | 列表与渐虚卡片轮盘 | 已实现，含鼠标滚轮、轻划吸附、窗口变化修复 | Android 真机 profile 与完整可访问性验收 |
| 6 | 对话助手、提醒、日终分析和电脑存档 | 兼容 API 通道、对话/拟办、提醒与原文归档已有，Mock 测试通过 | 真实 API、问询联动、自动 AI 日终分析；材料与知识回忆按已确认设计实现 |
| 7 | Android 手机与 Windows 电脑 | Windows release 和 Android debug 构建通过，源码已推送私有仓库 | 正式签名、跨网络连接、OPPO 真机、常驻与恢复验收 |
| 新增 | 分类、睡眠、桌面挂件 | 已实现相应管理、记录和窗口功能 | 挂件拖动/透明度手测，真机与同步场景验收 |
| 新增 | 微信小号作为私聊助手 | 用户形态确认，资料调研与本机版本核查完成 | W1–W6：账号/版本与桌面状态验证、桥接与投递、对话关联、主动提醒、日报与试用 |

---

## 2. 当前真实状态（2026-10-19 本次核查）

### 2.1 代码与仓库

- FastAPI/SQLite 后台实际测试 **92 passed**；Flutter 实际测试 **59 passed**；analyze **No issues found**；Windows 原生集成 **1 passed**。最新规则与验证见 `elastic-operations.md` 和 `STATUS.md`。
- Windows release、Android 三种 ABI 的 debug APK 已构建成功；Flutter doctor **No issues found**。
- 私有仓库 `https://github.com/tjusaltedfish/Timer`，分支 `main`；历史锚点为产品 `77882f0`、环境 `8e5bce5`，后续已新增回顾版本修复与弹性执行；最新提交以 `git log` 为准。
- 原有大型 UI 已拆分，助手在 `server/app/assistant.py`，窗口管理在 `apps/planner/lib/desktop/`。最新状态和已知缺陷见 `docs/STATUS.md`。

### 2.2 当前工具链

共享根目录 `%USERPROFILE%/DevTools/Timer`：Flutter 3.47.7 / Dart 3.13.5、Android SDK、ATL、Pub 缓存及工作区联接。`tools/toolchain.json` 固定版本与 revision，`dev-environment.ps1` 校验实际 Git HEAD。

原 AppData 路径在 Codex 进程中发生 Store 应用重定向；新 SDK 与缓存文件已通过真实物理路径验证。不要从旧环境记录推断 SDK 丢失后重复安装。

### 2.3 环境恢复步骤

1. 在项目根目录运行 `./tools/setup-dev.ps1`：固定 SDK/缓存、对齐 Android 配置、按锁文件恢复包、准备插件联接。
2. 仅在项目改名/移动或确认生成路径过期时加 `-Clean`；不要日常清空 SDK 或 Pub 缓存。
3. 测试与构建使用 §11 的入口；完整环境说明见 `docs/development-environment.md`。
4. Android SDK 许可已有用户授权；正式个人签名仍待用户设置口令。真机权限和账号/DNS 授权由用户本人完成。
5. 现有环境不需要重装 VS 或 SDK。新机器缺失组件时先确认具体缺项，再按固定版本准备；不要自动升级工具链。

---

## 3. 架构总览

```
┌──────────── 电脑（Windows，不休眠）─────────────┐
│  FastAPI 后台  127.0.0.1:8787                    │
│   ├─ SQLite：document(整份状态JSON) + operations │
│   │          (幂等) + events(不可变日志)+ devices │
│   ├─ 维护循环（5s）：到点段→待反馈；归档写盘      │
│   ├─ 规划器 planning.py：有界重排提案            │
│   ├─ assistant.py：LLM 网关、拟办（已有）        │
│   ├─ 自动日终分析 / 材料与回忆（待实现）        │
│   └─ archives/：YYYY-MM-DD.md / .json 日报存档   │
│  Flutter Windows 客户端（读本机 desktop-token）  │
└───────────────▲──────────────────────────────────┘
                │ HTTPS（Cloudflare Tunnel，§8）或局域网
┌───────────────┴──── 手机（Android）──────────────┐
│  Flutter 客户端：本地缓存 + 离线操作队列          │
│  本地通知（开始 / 结束问询 / 补问 / 检查点 / 日终）│
└──────────────────────────────────────────────────┘
```

### 3.1 关键文件

新增微信入口拟采用独立 Windows 交互进程，通过本机鉴权接口复用现有助手和领域操作；后台增加接收去重与投递队列。它不替代现有客户端或数据源，也不依赖开发助手常驻。具体方案、路线限制和验收在 `design/wechat-personal-channel.md`，目前尚无对应代码。

| 文件 | 作用 |
|---|---|
| `server/app/models.py` | 所有操作的 Pydantic 校验模型，`MODELS` 字典是操作白名单 |
| `server/app/domain.py` | 状态转换（`apply()`），在事务内执行 |
| `server/app/planning.py` | 重排提案 / 应用 / 撤销 |
| `server/app/maintenance.py` | 到点自动把执行段置为待反馈 |
| `server/app/reports.py` | 日报生成与归档写盘 |
| `apps/planner/lib/controller.dart` | 客户端状态、同步、离线队列、乐观更新 `_optimistic()` |
| `apps/planner/lib/reminders.dart` | 由状态推导出全部提醒，调度系统通知 |
| `apps/planner/lib/calendar.dart` | 按时区把时间块切成每日片段（处理跨日、夏令时） |
| `apps/planner/lib/week_calendar.dart` | 周课表组件 |
| `apps/planner/lib/planner_app.dart` | 公开入口；app/home/pages/sheets/widgets 已拆分，后续继续收窄大型组件职责 |
| `server/app/assistant.py` | 模型配置、请求、短编号上下文和拟办转换 |
| `apps/planner/lib/desktop/` | Windows 窗口、置顶与挂件模式 |

### 3.2 现有操作（`kind`）

`task.create` `task.update` `block.create` `block.move` `session.start` `session.pause` `session.resume` `session.end` `session.extend` `feedback.create` `waiting.resolve` `waiting.snooze` `review.save` `settings.update` `plan.apply` `plan.undo` `project.create` `project.update` `sleep.log` `sleep.delete`

助手的过去/当前/未来规则见 `design/assistant-behavior.md`；迟到模式、续时、检查点改约和确定性顺延的已实现约定见 `elastic-operations.md`；客户端的乐观操作与存储已拆到 `operations.dart` / `execution.dart` / `storage.dart`。

注意：`block.move` 后台支持，但客户端 `_optimistic()` **没有实现**（会抛「需要连接电脑」）。做拖动改期前要补上。

新增操作时三处必须同时改：`models.py` 的模型与 `MODELS`、`domain.py` 的 `apply()`、`controller.dart` 的 `_optimistic()`，并各自补测试。

---

## 4. 水墨审美规范（核心）

### 4.1 设计理念：一句话

**「宣纸上的几笔墨」**——大面积留白，信息用墨色深浅分层，只有一个朱砂红做强调；装饰极少但每一处都像手写的。

要的是：安静、克制、有呼吸感、东方但现代（参考：宋版书排版、印章、拓片、日式 sumi-e 的留白，再加上 iOS 级别的清晰度）。

**不要**：

- 水墨山水大图当背景、仙鹤祥云、毛笔字铺满屏幕、古风边框、卷轴动画。
- 紫色渐变、玻璃拟态、霓虹、重阴影、大圆角胶囊、彩色 emoji。
- 同一屏出现两种以上强调色。
- 只靠颜色表达状态（色弱 + 墨色本就接近）。
- 为装饰牺牲可读性：模糊、纹理、低对比只能用在非关键信息上。

### 4.2 色彩：墨分五色 + 一点朱砂

所有颜色定义为 token，**禁止在组件里写死十六进制**。

| Token | 浅色（宣纸） | 深色（夜墨） | 用途 |
|---|---|---|---|
| `paper` 纸 | `#F4F1EA` | `#151513` | 页面背景 |
| `paperRaised` 熟纸 | `#FAF8F3` | `#1D1C1A` | 卡片、面板、底部弹层 |
| `inkJiao` 焦墨 | `#1C1C1A` | `#ECE8DF` | 标题、主文字、主按钮底 |
| `inkNong` 浓墨 | `#33322E` | `#D4CFC4` | 正文 |
| `inkZhong` 重墨 | `#5E5B54` | `#A39E93` | 次要文字（对纸面约 6:1，可用于正文） |
| `inkDan` 淡墨 | `#8A867D` | `#75716A` | 仅用于大字号辅助、禁用态、时间轴刻度（约 3.2:1，**不得用于正文**） |
| `inkQing` 清墨 | `#C9C4B8` | `#3A3833` | 分隔、空状态笔触、保护时段斜线 |
| `line` 墨线 | `#DCD7CC` | `#2C2B28` | 1px 边线、网格 |
| `wash` 墨晕 | `#1C1C1A` @ 6% | `#ECE8DF` @ 6% | 焦点卡背后的晕染、选中态底 |
| `cinnabar` 朱砂 | `#B5402F` | `#D2614E` | **唯一强调色**：当前时刻线、印章、待问询提示、危险操作 |
| `cinnabarWash` | `#B5402F` @ 8% | `#D2614E` @ 12% | 待反馈卡片底 |

**项目色（淡彩）**：只用于左侧 2px 笔触竖线和小印章，**不做大面积填色**。

| 项目 | id | 名称 | 浅色 | 深色 |
|---|---|---|---|---|
| 毕业·实验代码 | `code` | 松烟青 | `#3F5E55` | `#7FA396` |
| 秋招·转行自学 | `learn` | 赭石 | `#9A6A3F` | `#C9A07A` |
| Fab·工艺实验 | `fab` | 花青 | `#46617A` | `#8DA6BE` |
| 个人安排 | `personal` | 藤黄灰 | `#857650` | `#BDAF8A` |

对比度要求：正文 ≥ 4.5:1，大字（≥ 18sp 或 14sp 粗）≥ 3:1。新增颜色必须自己算一遍对比度并写进 token 注释。

深色模式：跟随系统（ColorOS 深色模式常开）。第一阶段可以只做浅色，但**所有颜色必须走 token**，这样深色只是换一张表。

### 4.3 字体

| 角色 | 字体 | 说明 |
|---|---|---|
| 标题、日期、时间数字、印章字 | **霞鹜文楷 LXGW WenKai**（SIL OFL 1.1） | 有书写感但不浮夸，是「水墨」气质的主要来源 |
| 正文、按钮、表单 | 系统无衬线 | Android 用系统默认（ColorOS 为 OPPO Sans），Windows 用 `Microsoft YaHei UI`；不打包 |
| 倒计时数字 | 文楷 + `FontFeature.tabularFigures()` | 若文楷数字不等宽导致跳动，改为每位数字放在固定宽度 `SizedBox` 中 |

打包方式：

- 从 LXGW WenKai 官方 GitHub Release 下载 Regular（和可选 Medium），把 OFL 许可证原文放到 `docs/licenses/`。
- 用 `fonttools` 的 `pyftsubset` 子集化为《通用规范汉字表》一、二级字（约 6500 字）+ ASCII + 中文标点，输出 `.ttf`，目标每个字重 ≤ 4MB。子集脚本放 `tools/subset-fonts.py`，字表放 `tools/fonts/charset.txt`，可重复执行。
- `pubspec.yaml` 中注册 `family: WenKai`；`fontFamilyFallback` 设为系统字体，生僻字自动回落。
- 子集字体放 `apps/planner/assets/fonts/`。

字号（sp，逻辑像素）：

| 样式 | 字体 | 字号 / 行高 | 字重 | 用途 |
|---|---|---|---|---|
| `display` | 文楷 | 34 / 1.2 | Regular | 今日页日期「十月十九」 |
| `title` | 文楷 | 24 / 1.3 | Regular | 焦点卡任务名、页面标题 |
| `heading` | 文楷 | 18 / 1.4 | Regular | 区块标题「此刻」「今日诸事」 |
| `time` | 文楷 | 16 / 1.2 | Regular | 时间 `09:00 — 10:30` |
| `body` | 系统 | 15 / 1.65 | 400 | 正文、完成标准 |
| `label` | 系统 | 13 / 1.4 | 500 | 按钮、标签 |
| `caption` | 系统 | 12 / 1.4 | 400 | 辅助说明（颜色至少 `inkZhong`） |

标题**不要加粗**（文楷加粗会糊）。层级靠字号、墨色深浅和留白区分。

### 4.4 间距、形状、线条

- 8 的倍数间距：4 / 8 / 12 / 16 / 24 / 32 / 48。页面左右边距：手机 20，桌面 32–48。
- 圆角**小**：卡片 6，按钮 4，印章 2。水墨不适合胶囊大圆角。
- **没有阴影**。层次靠纸色差（`paper` vs `paperRaised`）+ 1px `line` 边线 + 墨晕。
- 分隔线两种：普通 1px `line`；重要分段用「笔触线」（§4.6，两端渐细），每屏最多 1 条。

### 4.5 质感

- **宣纸纹理**：用脚本生成一张 256×256 可平铺的噪点 + 少量纤维 PNG（≤ 40KB），`ImageRepeat.repeat`、5–8% 不透明度铺在 `paper` 上，并放在 `RepaintBoundary` 里。生成脚本放 `tools/gen-paper-texture.py`，用固定随机种子，保证可复现。深色模式用同一纹理反相、透明度更低。
- **墨晕**：焦点卡背后一团极淡的径向渐变（`wash`，半径约为卡片宽度的 0.7，中心偏左上），营造「墨落纸上微微化开」的感觉。只有焦点卡有。
- 纹理和墨晕都要能在「减少动画/省电」时关闭，且不能影响文字对比度。

### 4.6 标志性组件（这几样做好，整个界面就立住了）

1. **印章 `Seal`**：朱砂底、`paper` 色文楷字、1–2 个字、圆角 2、旋转 -3°，边缘做轻微不规则（用 `ClipPath`，路径在矩形上加 ±0.6px 抖动，固定种子）。用途和文字：
   - `今` 当前进行中、`定` 固定预约、`护` 保护时段、`候` 等待结果、`问` 待反馈、`毕` 已完成。
   - 必须同时提供 `Semantics(label: '已完成')` 一类完整说明；列表中印章旁边仍要有文字状态。
   - 印章是强调，每张卡最多一个。
2. **圆相计时环 `EnsoTimer`**：用一笔画成的「圆相」表示执行进度，取代普通进度条。实现：`CustomPainter` 把弧分成约 120 段，每段线宽 `base * (0.55 + 0.45 * sin(π * t))` 两头细中间粗，尾部透明度渐降；起笔处留约 8° 缺口。进度 = 已投入 / 计划时长。暂停时整环换为 `inkDan`；超时部分用 `cinnabar` 续画。环中心显示剩余时间（文楷）。
3. **笔触线 `BrushDivider`**：`CustomPainter` 画一条两端渐细的横线，中间粗 1.5px，长度 40–64px，用作区块标题下方的「起笔」装饰，而不是整行横线。
4. **墨点状态**：同步状态在页头用一个 6px 墨点（已同步 `inkZhong`、同步中呼吸动画、离线 `inkDan` 空心、冲突 `cinnabar`），点击展开说明。替代现在 AppBar 里的「已同步」文字按钮。
5. **项目笔触**：每张任务卡左侧 2px 竖线，用项目色，上下端渐细（不是直角矩形）。

### 4.7 动效

- 原则：像墨在纸上化开——**慢入快稳**，不弹跳。
- 时长：微交互 160ms，页面/卡片切换 240ms，墨晕扩散 400ms；曲线 `Curves.easeOutCubic`。
- 选中态：墨晕从点击点扩散（自定义 `InkFeature` 或简单的 `AnimatedContainer` + 径向渐变）；**关闭 Material 默认水波纹的高饱和色**，`splashColor` 用 `wash`。
- `MediaQuery.disableAnimationsOf(context)` 为真时，所有动画时长置 0，轮盘不做模糊。

### 4.8 图标

Material Icons 的 outlined 系列，尺寸 20–22，颜色 `inkZhong`，选中 `inkJiao`。不混用填充图标与线性图标。底部导航选中态不用色块胶囊，改为图标下方一个 4px 朱砂墨点。

### 4.9 文案语气

平静、具体、短。像一位不催人的师长，不鸡汤、不卖萌、不用感叹号。

- 导航：**今日 / 一周 / 诸事 / 回顾 / 助手**（设置放今日页右上角齿轮，桌面放侧栏底部）。
- 区块标题：「此刻」「接下来」「今日诸事」「待回话」「等候结果」。
- 空状态：「今日尚空。先落一笔有结果的事。」「一周未着墨。」
- 问询：「这一段，进展如何？」「还需要多久？」「下一步是什么？」
- 不出现「加油」「太棒了」「💪」。完成时只盖一枚「毕」印。

**改文案会影响测试**：`test/widget_test.dart` 和 `integration_test/desktop_workflow_test.dart` 用 `find.text('安排第一件事')`、`'保存安排'`、`'开始这一段'`、`'结束并反馈'`、`'等待结果'`、`'记录这一段'`、`'课表'` 等定位。改了就同步改测试；建议关键按钮加 `Key('action.start')` 之类，测试改用 `find.byKey`，以后改文案不再牵连测试。

### 4.10 布局断点

| 宽度 | 布局 |
|---|---|
| < 600（手机，Find X8s 约 390–412dp） | 底部导航 5 项；对话框一律改为底部弹层 `showModalBottomSheet`（顶部一条笔触线当把手） |
| 600–1000（平板/窄窗） | 底部导航；内容最大宽 680 居中 |
| ≥ 1000（桌面） | 左侧窄栏 88px（图标 + 两字标签 + 顶部一枚「日程」印章 logo）；今日页为两栏：左卡片轮盘，右当日时间轴 |

必须检查 360 / 390 / 412 / 1280 / 1920 宽度：无横向溢出、无文字截断错误、键盘弹出时表单仍可提交。

---

## 5. 页面规范

### 5.1 应用外壳

- 去掉 Material 的 `AppBar` 标题栏。每页自己的页头：左边文楷大标题，右边墨点同步状态 +（今日页）设置齿轮。
- 背景统一 `paper` + 纹理。`Scaffold.backgroundColor` 透明，纹理放最底层。
- 浮动按钮「安排一件事」：改为 56px 正方形、圆角 6、焦墨底、纸色「＋」，仅在今日/一周/诸事页出现。长按可直接打开助手输入框（快捷说一句话安排）。
- 冲突横幅：顶部一条 `cinnabarWash` 底的细条，文字 + 「处理」按钮，不用 `MaterialBanner` 默认样式。

### 5.2 主题实现

在 `lib/theme/` 下：

- `tokens.dart`：`InkPalette`（浅/深两套，**不要命名为 `Ink`，会和 Flutter 的 `Ink` 组件冲突**）、项目色、间距、圆角、时长常量。
- `ink_theme.dart`：`ThemeData buildInkTheme(Brightness b)`，统一配置 `colorScheme`、`textTheme`、`filledButtonTheme`、`outlinedButtonTheme`、`textButtonTheme`、`inputDecorationTheme`（下划线式输入框，聚焦时线变焦墨，不要填充白框）、`bottomSheetTheme`、`navigationBarTheme`、`chipTheme`、`dialogTheme`、`snackBarTheme`（焦墨底纸色字，直角 4）、`splashFactory`（`InkSparkle` 不要，用 `InkRipple` + `wash`）。
- 用 `ThemeExtension<InkTokens>` 暴露非 Material 的 token（纸纹开关、墨晕色、项目色），组件里通过 `Theme.of(context).extension<InkTokens>()!` 取。

示例骨架：

```dart
@immutable
class InkPalette {
  const InkPalette({required this.paper, required this.paperRaised, required this.inkJiao,
      required this.inkNong, required this.inkZhong, required this.inkDan, required this.inkQing,
      required this.line, required this.cinnabar});
  final Color paper, paperRaised, inkJiao, inkNong, inkZhong, inkDan, inkQing, line, cinnabar;

  static const light = InkPalette(
    paper: Color(0xFFF4F1EA), paperRaised: Color(0xFFFAF8F3),
    inkJiao: Color(0xFF1C1C1A), inkNong: Color(0xFF33322E),
    inkZhong: Color(0xFF5E5B54), // ≈6.0:1 on paper
    inkDan: Color(0xFF8A867D),   // ≈3.2:1 — never for body text
    inkQing: Color(0xFFC9C4B8), line: Color(0xFFDCD7CC),
    cinnabar: Color(0xFFB5402F), // ≈5.0:1 on paper
  );
  static const dark = InkPalette(
    paper: Color(0xFF151513), paperRaised: Color(0xFF1D1C1A),
    inkJiao: Color(0xFFECE8DF), inkNong: Color(0xFFD4CFC4),
    inkZhong: Color(0xFFA39E93), inkDan: Color(0xFF75716A),
    inkQing: Color(0xFF3A3833), line: Color(0xFF2C2B28),
    cinnabar: Color(0xFFD2614E),
  );
}
```

### 5.3 通用组件清单（`lib/widgets/`）

| 组件 | 说明 |
|---|---|
| `PaperBackground` | 纸色 + 纹理 + 可选墨晕 |
| `InkCard` | `paperRaised` 底、1px `line`、圆角 6、可选左侧项目笔触、可选右上印章 |
| `Seal` | §4.6 印章 |
| `EnsoTimer` | §4.6 圆相计时环 |
| `BrushDivider` | §4.6 笔触线 |
| `SyncDot` | §4.6 同步墨点 |
| `SectionTitle` | 文楷标题 + 下方短笔触线 |
| `InkSheet` | 统一的底部弹层外壳（标题、内容、底部主次按钮），桌面上自动变为居中对话框 |
| `ChoiceSeals` | 反馈四选一：大号可点区域（≥ 56px 高），选中时左侧出现朱砂印 |
| `CardWheel` | §5.5 卡片轮盘 |
| `InkTimeline` | §5.5 今日时间轴（细竖线 + 时间刻度 + 朱砂「此刻」点） |

### 5.4 状态到视觉的映射（全局统一）

| 状态 | 卡片底 | 印章 | 文字 |
|---|---|---|---|
| 未来、可执行 | `paperRaised` | 无 | 「09:00 开始」 |
| 已到点未开始（宽限 10 分钟内） | `paperRaised` + 朱砂细左线 | 无 | 「该开始了」 |
| 迟到（> 10 分钟未开始） | `cinnabarWash` | `问` | 「已过 25 分钟，现在开始？」 |
| 进行中 | `paperRaised` + 墨晕 | `今` | 圆相计时 |
| 暂停 | `paperRaised` | 无 | 「已暂停」，圆相变淡 |
| 待反馈 | `cinnabarWash` | `问` | 「这一段，进展如何？」 |
| 等待结果 | `paperRaised`，文字 `inkZhong` | `候` | 「10/20 14:00 检查」 |
| 已完成 | 透明，文字 `inkDan` + 删除线可选 | `毕` | 结果说明一行 |
| 跳过/未开始 | 透明，`inkDan` | 无 | 「未开始」 |
| 固定预约 | 不变 | `定`（小号，不与状态印章同时出现时才显示） | |
| 保护时段（吃饭/休息） | 透明 + 清墨 45° 细斜线 | `护` | 标题 |

### 5.5 今日页（主页）——卡片轮盘

**结构（手机）**：

```
十月十九 · 周一                         ● ⚙
—— (笔触)
[待回话 2 段 · 点此逐一回答]            ← 有未反馈时才出现，朱砂淡底细条

        (上方：已过去的卡片，缩小、变淡、模糊)
   ┌──────────────────────────────┐
   │ 松烟青笔触  09:00 — 10:30  [今]│   ← 焦点卡：清晰、全不透明、背后墨晕
   │ 参数扫描脚本重构                │
   │ 求一个结果：输出可复现的 CSV    │
   │      ◯ 圆相 42:10               │
   │ [暂停]  [结束并反馈]            │
   └──────────────────────────────┘
        (下方：未来的卡片，缩小、变淡、模糊)

[轮盘 | 列表]  切换
```

**卡片轮盘 `CardWheel` 行为**：

- 竖向 `PageView`（`viewportFraction ≈ 0.42–0.5`，根据屏高调），按开始时间排序，**过去在上、未来在下**。
- 初始定位：进行中/待反馈的段 > 下一个未开始的段 > 最后一段。
- 根据与中心的距离 `d = |index - page|`（0..3）计算：
  - 缩放 `1 - 0.07·d`；
  - 不透明度 `clamp(1 - 0.32·d, 0.12, 1)`；
  - 模糊 `sigma = clamp(1.4·d, 0, 3.5)`，`d < 0.15` 时不加 `ImageFiltered`（省性能）；
  - 过去的卡额外降为 `inkDan` 文字色（「已成往事」），未来的保持原色只靠模糊变淡。这就是「根据时间远近、前后逐渐虚化」。
- 只有中心卡的按钮可交互；点非中心卡 → `animateToPage` 把它转到中心。
- 每张卡都要有完整 `Semantics(label: '09:00 至 10:30，参数扫描脚本重构，进行中')`，模糊不影响读屏。
- 键盘/桌面：上下方向键切换，`Enter` 触发主操作。
- 减少动画时：不模糊、不缩放，只保留不透明度差。
- 性能：只对可见的 ±2 张做模糊；整个轮盘外套 `RepaintBoundary`；在 Find X8s 上用 profile 模式确认滑动无掉帧（`flutter run --profile`，看性能浮层）。

骨架代码：

```dart
class CardWheel extends StatefulWidget {
  const CardWheel({super.key, required this.count, required this.initial,
      required this.builder, this.onFocus});
  final int count, initial;
  final Widget Function(BuildContext, int index, bool focused) builder;
  final ValueChanged<int>? onFocus;
  @override
  State<CardWheel> createState() => _CardWheelState();
}

class _CardWheelState extends State<CardWheel> {
  late final controller = PageController(viewportFraction: .46, initialPage: widget.initial);
  @override
  void dispose() { controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: PageView.builder(
        controller: controller,
        scrollDirection: Axis.vertical,
        itemCount: widget.count,
        onPageChanged: widget.onFocus,
        itemBuilder: (context, i) => AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final page = controller.hasClients && controller.position.haveDimensions
                ? controller.page! : widget.initial.toDouble();
            final d = (i - page).abs().clamp(0.0, 3.0);
            final focused = d < .5;
            Widget card = widget.builder(context, i, focused);
            if (!still) {
              card = Transform.scale(scale: 1 - .07 * d, child: card);
              final sigma = (1.4 * d).clamp(0.0, 3.5);
              if (sigma > .2) {
                card = ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: card);
              }
            }
            return Opacity(
              opacity: (1 - .32 * d).clamp(.12, 1.0),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: focused ? null : () => controller.animateToPage(i,
                    duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic),
                child: AbsorbPointer(absorbing: !focused, child: card),
              ),
            );
          },
        ),
      ),
    );
  }
}
```

**列表模式**：同样的数据，用简洁的一列：左侧文楷时间、中间标题与完成标准一行、右侧状态文字/印章，行间 1px `line`。保留，作为可访问性与快速浏览的替代。

**桌面两栏**：左 5/12 是轮盘，右 7/12 是 `InkTimeline` 当日时间轴（每小时一格，60px/小时，时间块为 `InkCard` 缩略样式，朱砂横线标「此刻」，每分钟刷新一次位置）。

**日期切换**：页头下方一行七个日期（周一…周日，文楷数字），选中日下方一个朱砂墨点；左右滑动切周。比现在实心绿底块轻得多。

### 5.6 一周页（课表）

- **桌面**：7 列同屏，左侧时间轴 52px，列头「周一 19」，今天列头下有朱砂点、整列底色 `wash`。每小时 56–64px 高。
- **手机**：横向可滚动的 7 日网格，**左侧时间列与顶部日期行固定**（`TwoDimensionalScrollView` 或两个联动 `ScrollController`），列宽 = `(屏宽 - 44) / 3.2`，一屏看到约 3 天，滑动看其余；右上角切换「单日 / 三日 / 七日」密度（七日模式列宽缩到能放下，只显示标题首字和颜色笔触）。这满足「一周七天可以滑动选择」。
- 时间块：`paperRaised` 底 + 左侧项目笔触 + 标题（最多 2 行）+ 开始时间；固定块右上小 `定` 印；保护块为清墨斜线底；已完成块变淡加 `毕`。
- 「此刻」：朱砂 1px 横线 + 左端 6px 朱砂点，只在今天列。
- 交互：
  - 点块 → 详情弹层（完成标准、状态、执行记录、操作：开始 / 改期 / 弹性重排）。
  - 长按空白格 → 在该时刻预填新建弹层（15 分钟吸附）。
  - 长按弹性块并拖动 → 改期（15 分钟吸附，松手后调用 `block.move`；固定/保护块不可拖，抖动提示）。**需要先在客户端 `_optimistic()` 实现 `block.move`**。拖动之外必须有表单改期（可访问性）。
- 夏令时周的提示保留（用户时区默认 `America/Los_Angeles`，有夏令时），用 `caption` 样式。

### 5.7 诸事页（任务）

- 顶部「等候结果」区：每个未解决检查点一张卡（`候` 印、检查时间、按钮「结果回来了」）。
- 按项目分组（四个项目各一个 `SectionTitle`，组内按状态排序：进行中 > 可执行 > 等待 > 已完成折叠）。
- 任务卡：标题（文楷 18）、「求一个结果：」+ 完成标准、剩余投入「余 90 分」、已投入合计、下一次安排时间。操作：安排下一段 / 弹性重排 / 编辑。
- 已完成与已取消默认折叠成一行「已毕 12 件 ›」。

### 5.8 问询流（需求 2 的核心体验）

所有「问结果」的入口——结束提醒、补问提醒、焦点卡「结束并反馈」、今日页「待回话」条、日终——都进入**同一个** `InquirySheet`：

1. 顶部：任务名 + 计划时段 + 实际投入（如「计划 90 分，实际 74 分」）+ 完成标准。
2. 四个大选项（`ChoiceSeals`）：**完成了 / 做了一部分 / 在等结果 / 被打断了**；外加次要文字按钮「没有开始」。
3. 按选项展开追问：
   - 完成了 → 「留下了什么？」（结果说明，选填，但给提示：链接、文件名、数据）。
   - 做了一部分 → 「还需要多久？」15/30/45/60/90/120 + 自定义；「下一步是什么？」；提交后自动生成重排提案（已有逻辑）。
   - 在等结果 → 「什么时候去看？」快捷：2 小时后 / 今晚 / 明早 9 点 / 自定义。
   - 被打断了 → 「还需要多久？」+ 原因（选填）；提交后更新剩余时间并给重排提案（已实现）。
4. 底部一个输入框「或者直接说一句」——发给助手解析（§7.5），返回填好的选项让用户确认。
5. 多段待回话时，顶部显示「1 / 3」，提交后自动进入下一段；「稍后」把这一段放回队列（补问提醒最多一次，已有逻辑）。

### 5.9 回顾页

- 上：今日数字摘要（安排 N 段、执行 M 段、实际投入 X 小时、完成 / 部分 / 等待 / 未开始各几段），文楷数字、无图表。
- 中：「你的两三句」输入框（已有）。
- 下：「助手的看法」——日终 AI 分析（§7.6）；未配置模型时显示确定性统计与提示。
- 底部：归档状态「已存入电脑：archives/2026-10-19.md」。
- 可选：往日回顾列表，按周折叠。

### 5.10 助手页

- 像一本信笺而不是聊天软件：**不用气泡**。用户的话右对齐、`inkNong`；助手的话左对齐、左侧 1px `line` 竖线、文楷首字。时间戳 `caption`。
- 助手返回的修改建议显示为「拟办」卡：`InkCard` + 虚线边框，列出将要发生的变化（新增「参数扫描 周二 14:00–15:30」、顺延「投递整理 → 16:00」），按钮「照此办理」「不必」。确认后卡片盖「已办」印。
- 输入区：底部固定，多行输入 + 发送；上方快捷短语：「安排明天」「我迟到了 20 分钟」「今天就到这」「帮我看看这周」。
- 未配置模型：显示说明与「去电脑端设置」，不要显示一个假的可用输入框。
- 手机离线时：输入框可写但发送按钮禁用并说明「助手需要连接电脑」。

### 5.11 设置页

分组：连接（地址、配对、同步、设备列表与撤销）/ 提醒（开关、测试、准时提醒权限、ColorOS 后台设置引导）/ 作息（时区、日程开始结束、日终时间、自动微调开关）/ 助手（仅电脑端可编辑：服务地址、模型名、Key 状态「已设置 ····a1b2」、测试连接、每日调用上限）/ 关于（版本、数据目录、导出备份）。

---

## 6. 弹性机制：状态机与规则

### 6.1 现有三层状态（后台已实现，保持不变）

- **任务 Task**：`ready → in_progress → (ready | waiting | done)`，`waiting → (done | ready)`，任意 → `cancelled`（显式），`done/cancelled → ready` 仅显式重开。
- **执行段 Session**：`running ⇄ paused → awaiting_feedback → closed`；到 `expected_end_at` 由后台维护循环自动 `running → awaiting_feedback`（`ended_by: timer`），迟到的离线暂停/结束事件按真实时间重建。
- **时间块 Block（存储状态）**：`scheduled → completed | skipped | cancelled | superseded`。

### 6.2 新增：时间块的派生显示状态（只在客户端和提醒里计算，不存库）

```
upcoming ──(到开始时间)──> due ──(宽限 10 分钟内开始)──> running
   │                        │
   │                        └─(超过宽限仍未开始)──> late ──(开始)──> running(迟到)
   │                                                 └─(到结束时间仍未开始)──> missed
running ──(到点)──> awaiting_feedback ──(反馈)──> closed
running ──(续时)──> running(extended)
```

`late` 和 `missed` 都会进入「待回话」队列（§5.8），`missed` 的问询直接给「没有开始 / 其实做了（补录）/ 改到…」三选。

### 6.3 事件 → 调整 规则表

| 事件 | 判定 | 自动行为 | 给用户的选择 |
|---|---|---|---|
| 迟到开始 | 开始时间晚于计划 > 5 分钟 | 无 | 开始时弹出：「按原时长（结束延后到 10:55）」/「按原结束（压缩为 65 分）」。选前者且与后续弹性块重叠 → 触发顺延规则 |
| 到点未开始 | `late` | 推送一次「该开始了」 | 现在开始 / 推迟 15 分钟 / 跳过并重排 |
| 整段错过 | `missed` | 进入待回话 | 没有开始（→ 剩余时间不变，生成重排提案）/ 补录 / 改期 |
| 时间到还没做完 | 计时到点 | 段转为待反馈（已有） | 「再给我 15/30 分钟」（`session.extend`，已实现）→ 按约束顺延；或「做了一部分」→ 重排 |
| 部分完成 | 反馈 partial | 更新剩余（已有） | 自动打开重排提案（已有） |
| 被打断 | 反馈 interrupted | 要求填剩余时间（已实现） | 同部分完成 |
| 等待结果 | 反馈 waiting | 建检查点（已有） | 回来了（完成/还要投入）/ 还没回来（再约时间，`waiting.snooze` 已实现） |
| 当天结束仍有未确认 | 日终时间 | 日终提醒（已有） | 逐一问询；未回答的保持「未确认」，绝不推定完成 |
| 过载 | 提案中有 `unscheduled_items` | 无 | 显示「装不下 120 分钟」，建议：延到下周 / 降优先级 / 拆小 / 放弃 |

### 6.4 自动程度分级

- **零级：只记录**——所有事实（实际开始、结束、暂停）照实保存。
- **一级：自动微调（默认开，可在设置里关）**——确定性规则，不经过模型：仅当
  1. 受影响的只有**同一天紧随其后**的**弹性**块；
  2. 每块位移 ≤ 30 分钟；
  3. 不跨越固定/保护块、不超出 `day_end`、不违反截止时间和依赖；
  才自动顺延，并显示 10 秒「已顺延 2 段 · 撤销」提示（撤销调用已有 `plan.undo`）。实现方式：服务端内部生成提案并立即 `apply`，记录 `auto: true`。
- **二级：提案确认**——其余所有情况都生成提案（已有 `plan/proposals`），用户确认后应用。

### 6.5 弹性操作实现约定

下表前四项已实现；`block.move` 的客户端仍待补。详细边界、离线保护及最新证据见 `elastic-operations.md`。

| kind | payload | 规则 |
|---|---|---|
| `session.extend` | `{id, minutes: 5..120, occurred_at}` | 仅 `running/paused`，或 `awaiting_feedback` 且 `ended_by == timer` 且结束后 ≤ 30 分钟（重新打开为 running）；顺延 `expected_end_at`；之后尝试一级微调 |
| `waiting.snooze` | `{id, check_at}` | 未解决检查点改约时间，必须是未来 |
| `session.start` 增字段 | `mode: "keep_duration" \| "keep_end"` | 默认 `keep_duration`（与现行为一致）；`keep_end` 时 `expected_end_at = block.end_at`，若已过则拒绝 |
| `feedback.create` 修改 | `interrupted` 也要求 `remaining_minutes` | 同步改 `models.py` 校验、客户端表单与 `_optimistic()` |
| `block.move`（客户端） | 已有后台 | 补客户端乐观更新 |

每个新操作：Pydantic 模型 + `domain.apply` + `_optimistic` + 后台 pytest（正常、越界、重复、版本冲突、离线迟到重放）+ 客户端 controller 测试。

---

## 7. AI 助手

### 7.1 原则

- 只在**电脑后台**调用模型；手机经后台转发。
- 兼容 **OpenAI Chat Completions 格式**的任何服务：OpenAI 中转站、DeepSeek（`https://api.deepseek.com`，OpenAI 兼容）。`base_url`、`model`、`api_key` 全部可配置；**模型名不要写死**，开工时查对方当前文档确认可用模型名。
- 不依赖函数调用（各中转站对 `tools` 支持参差）：要求模型输出**严格 JSON**（`response_format: {"type": "json_object"}`，不支持时靠提示词 + 解析重试），后台用 Pydantic 校验。校验失败把错误回喂重试 1 次，再失败就只显示文字回复、不产生拟办。
- 模型产出的修改只能是「拟办」，经用户确认后转为普通操作，写入同样的操作日志。
- 提醒推送本身**不依赖模型**（已有确定性本地通知），模型只负责理解自然语言、提出安排、写总结。

### 7.2 配置与密钥

- 文件：`<数据目录>\assistant.json`：`{"base_url": "...", "model": "...", "daily_call_limit": 200, "timeout_seconds": 30}`。
- Key：优先环境变量 `PLANNER_LLM_API_KEY`；否则 `<数据目录>\secrets\llm-key`。默认数据目录是 `%LOCALAPPDATA%\TimePlanner\data`，在仓库之外；若用 `PLANNER_DATA_DIR` 指到仓库内，`.gitignore` 的 `data/` 规则会兜底，但仍要用 `git status` 确认 Key 文件不会被提交。
- 电脑端设置页可以填 Key：`POST /api/v1/assistant/config`（仅 `desktop` 角色），后台写文件；`GET` 只返回 `{configured, base_url, model, key_hint: "····a1b2"}`。
- 日志里对 Authorization 头和 Key 做脱敏；异常信息不得包含请求头。
- **不要在聊天里向用户索要 Key 再替他写入**；在设置页让用户自己粘贴。

### 7.3 后台模块（新建 `server/app/assistant/`）

| 文件 | 内容 |
|---|---|
| `config.py` | 读写配置与 Key |
| `client.py` | `httpx.AsyncClient` 调 `{base_url}/chat/completions`；超时、2 次指数退避重试（仅 429/5xx/超时）、每日调用计数 |
| `context.py` | 把状态压缩成模型上下文（见 7.4），并维护短 id ↔ 真实 id 映射 |
| `drafts.py` | 拟办的 Pydantic 模型、校验、应用（复用 `domain.apply`） |
| `prompts.py` | 系统提示词模板（中文） |
| `summary.py` | 日终分析作业 |

存储：在 SQLite 新增表 `assistant_messages(id, role, text, drafts_json, created_at)` 和 `assistant_usage(day, calls)`；**不要**塞进整份状态 JSON（会让每次快照变大）。

依赖：`httpx` 已随 FastAPI 测试客户端存在，正式加入 `pyproject.toml` 与 `requirements.lock.txt`。

### 7.4 上下文（每次调用时构造）

- 现在时间（用户时区的本地时间 + 星期）、时区、作息（day_start/day_end）。
- 今天到 7 天后的时间块：`b1 周一 09:00-10:30 [弹性] 参数扫描（代码）状态：已完成`。
- 未完成任务：`t3 参数扫描 | 结果：输出可复现CSV | 余 90 分 | 可执行 | 截止 10/25`。
- 未解决等待检查点、待反馈的段。
- 最近 10 条对话。
- 真实 UUID 不给模型，用 `t1/b1/w1` 短 id，后台映射回去，防止模型编造 id。
- 控制总长度（例如 ≤ 6k token），超出时先删最远的已完成块。

### 7.5 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/assistant/status` | 是否已配置、模型名、今日已用次数 |
| POST | `/api/v1/assistant/messages` | `{text, context?: {inquiry_block_id}}` → `{message, drafts[]}` |
| GET | `/api/v1/assistant/messages?before=&limit=` | 历史 |
| POST | `/api/v1/assistant/drafts/{id}/apply` | 在一个事务里依次执行拟办中的操作；任一失败整体回滚并返回原因 |
| POST | `/api/v1/assistant/drafts/{id}/dismiss` | 放弃 |
| POST | `/api/v1/assistant/config` | 仅电脑端 |

模型输出 JSON 结构：

```json
{
  "reply": "给用户看的简短中文回复（≤120字）",
  "drafts": [
    {
      "summary": "周二 14:00–15:30 安排「参数扫描」",
      "actions": [
        {"type": "schedule_new", "title": "参数扫描", "outcome_criteria": "输出可复现CSV",
         "project": "code", "start_local": "2026-10-20 14:00", "minutes": 90, "kind": "flexible"},
        {"type": "move_block", "block": "b4", "start_local": "2026-10-20 16:00"},
        {"type": "feedback", "block": "b2", "choice": "partial", "remaining_minutes": 60, "outcome_text": "..."},
        {"type": "replan", "task": "t3"},
        {"type": "waiting_check", "check": "w1", "resolution": "done", "outcome_text": "..."}
      ]
    }
  ]
}
```

允许的 `type` 只有上面五种，后台映射为 `task.create + block.create`、`block.move`、`feedback.create`、规划器提案、`waiting.resolve`。本地时间由后台按用户时区转换（处理夏令时的不存在/重复时间，复用前端同等逻辑的 Python 版本）。拟办在应用前再完整校验一次（冲突、固定块、截止、依赖）。

系统提示词要点（写在 `prompts.py`）：

- 你是用户的时间管理助手，用户在准备秋招转行自学、毕业实验代码、Fab 工艺实验。
- 每件事都要有「可检验的结果」；用户没给时追问一句，而不是编一个。
- 不要安排到固定/保护时段，不超出作息范围，给休息留空。
- 用户描述现实变化（迟到、没做完、在等结果）时，先确认事实再提调整。
- 绝不声称已经修改了日程，只能说「拟办如下，确认后生效」。
- 语气平静简短，不说教不鸡汤，不用 emoji。
- 只输出符合给定 JSON 结构的内容。

### 7.6 日终分析与存档

- 触发：用户保存日终回顾后；或到 `daily_review_time + 90 分钟` 仍未保存时也生成一份（标明「用户未回顾」）。用后台作业表实现，幂等键 `summary:<date>:<review_version>`，失败重试 3 次。
- 输入：当天时间块与反馈、实际投入、等待项、用户原文、过去 7 天的简要统计。
- 输出（JSON → Markdown）：今日完成了什么（只列用户确认的）/ 偏差（计划 vs 实际，迟到、未开始、超时）/ 一个最值得注意的模式 / 明天的第一件事建议（作为拟办，可在 App 里一键安排）。
- 写入 `archives/YYYY-MM-DD.md` 追加「## 助手分析」小节，同时写 `.json`；这就是「传到电脑上存档」。
- 未配置模型时：只写确定性统计（已有 `report_for` 扩展），不报错。
- 可选：每周日生成周报 `archives/weekly/YYYY-Www.md`。

### 7.7 与问询流的结合

问询弹层的「直接说一句」→ `POST /assistant/messages`，带 `context.inquiry_block_id`。提示词要求只针对这一段输出 `feedback`（以及可选 `replan`）拟办。前端把拟办回填到四选一和表单里让用户点确认，而不是显示一段聊天。

### 7.8 测试

- 用 `httpx.MockTransport` 模拟模型：正常 JSON、非法 JSON、重试后成功、超时、429、引用不存在的短 id、拟办与固定块冲突、日调用上限。
- 拟办应用的原子性：第二个动作失败时第一个不生效。
- Key 不出现在任何 API 响应、异常信息、日志中（写测试断言）。
- **测试中绝不调用真实模型**。

---

## 8. 手机连接电脑

用户情况：有一个自己的域名（有效期一年）、电脑不休眠、一般不用 VPN。

**推荐：Cloudflare Tunnel**

- 不需要公网 IP、不需要路由器端口映射，自动 HTTPS；手机在任何网络都能连。
- 需要用户自己操作的部分（列成清单交给用户，**不要代替用户登录或改 DNS**）：把域名的 DNS 托管到 Cloudflare（免费套餐）、在电脑安装 `cloudflared` 并登录授权。
- 配置：`plan.<域名>` → `http://127.0.0.1:8787`；`cloudflared` 以 Windows 服务运行。
- 后台只监听 `127.0.0.1`，不要监听 `0.0.0.0`。
- 配对接口的限流按 `request.client.host` 计，走隧道后全部变成 127.0.0.1：改为在请求来自本机回环且带 `CF-Connecting-IP` 时用该头的值，否则用连接地址。
- 不要再套 Cloudflare Access 登录页（App 的 HTTP 客户端过不了网页登录）；安全依靠现有的设备令牌认证 + 5 分钟一次性配对码 + 限流，以及设置页里的设备撤销。
- 手机端「服务地址」填 `https://plan.<域名>`。

**备选：同一 Wi-Fi 局域网** `http://<电脑局域网IP>:8787`。Android 9+ 默认禁止明文 HTTP，需要 `network_security_config.xml` 只对私有网段放行，并让后台监听局域网地址——安全性更差，只作为调试手段。

**电脑端常驻**：

- 后台：Windows 任务计划程序「登录时」启动 `server\.venv\Scripts\pythonw.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8787`（工作目录 `server`），失败自动重启。写成 `tools/install-server-task.ps1`，**执行前告诉用户会创建计划任务**。
- 客户端：可选系统托盘（`tray_manager` 或 `system_tray` 插件），关窗口最小化到托盘。

---

## 9. Android 构建与 ColorOS 适配

1. 应用标识 `dev.personal.time_planner`，名称「日程之间」。
2. 图标：自适应图标，前景是一枚朱砂方印「日程」（或「之间」）白文，背景 `paper` 色；通知小图标 `ic_notification.xml` 已存在（单色），检查是否与新印章一致。启动页背景改为 `paper` 色。
3. 签名：生成个人 release keystore，放在仓库外（如 `%USERPROFILE%\.keys\time_planner.jks`），`android/key.properties` 引用且加入 `.gitignore`。**密钥口令由用户自己设置和保管，不要写入任何文件或日志**；需要时请用户在终端自己输入。
4. 构建：在 ASCII 联接路径下 `flutter build apk --release --split-per-abi`，Find X8s 用 `app-arm64-v8a-release.apk`。
5. 权限：`INTERNET`、`POST_NOTIFICATIONS`（运行时申请）、`SCHEDULE_EXACT_ALARM`（引导到系统「闹钟和提醒」开关）、`RECEIVE_BOOT_COMPLETED`。**不要**申请无障碍、使用情况访问、悬浮窗等（黑名单功能已删）。
6. 通知：渠道分三类「开始提醒」「结果问询」「日终回顾」；问询通知加操作按钮「完成了 / 做了一部分 / 稍后」（`flutter_local_notifications` 的 `AndroidNotificationAction`），点「做了一部分」打开 App 进入问询弹层。
7. ColorOS 后台存活（真机必测）：设置页提供引导文字与跳转——允许通知（横幅、锁屏）、应用耗电管理设为「允许后台运行」、允许自启动、关闭「睡眠待机优化」对本应用的影响。用真机验证：锁屏 30 分钟后定时提醒是否准时到达，记录结果到 `STATUS.md`。
8. 安装到手机：用户开启开发者模式与 USB 调试后 `adb install -r <apk>`；或把 APK 传到手机手动安装。

---

## 10. 代码组织（拆分 `planner_app.dart`）

```
apps/planner/lib/
  main.dart
  app.dart                     # MaterialApp、主题、路由外壳
  controller.dart              # 保持；新增 block.move / session.extend 等乐观更新
  reminders.dart  calendar.dart  bootstrap*.dart
  assistant_client.dart        # 助手接口封装（新）
  theme/      tokens.dart  ink_theme.dart
  widgets/    paper_background.dart ink_card.dart seal.dart enso_timer.dart
              brush_divider.dart sync_dot.dart section_title.dart
              card_wheel.dart ink_timeline.dart choice_seals.dart ink_sheet.dart
  pages/      today_page.dart week_page.dart tasks_page.dart
              review_page.dart assistant_page.dart settings_page.dart
  sheets/     task_sheet.dart inquiry_sheet.dart replan_sheet.dart
              waiting_sheet.dart block_detail_sheet.dart pair_sheet.dart
  copy.dart                    # 可选：集中放界面文案常量
```

约定：

- 页面只读 `PlannerController` 并调用其方法；不要在 widget 里拼操作 payload 的业务规则，把它们收进 controller 的具名方法（如 `startBlock(block, mode)`、`submitFeedback(...)`）。
- 单文件不超过 ~400 行。
- 时间一律 `tz.TZDateTime` + 用户时区；存储和传输 UTC ISO8601。
- `flutter analyze` 零警告；`dart format`。
- Python：保持现有风格（紧凑、类型标注、中文错误信息、`DomainError`）。

---

## 11. 验证命令（每个里程碑都要跑）

```powershell
# 从项目根目录执行；先恢复固定环境
./tools/setup-dev.ps1
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

Android release 待个人签名配置后再验证。只有相关改动才重复相应检查；只改文档不重新运行整套构建。

界面验收：`flutter run -d chrome` 或 `flutter build web` 后用浏览器在 360/390/412/1280 宽度截图，存 `artifacts/`（已被忽略提交），在 `STATUS.md` 里列出文件名。检查清单：

- [ ] 符合当前「墨晕白纸」黑白近中性色规范，状态同时有文字或形状说明。
- [ ] 正文对比度 ≥ 4.5:1（抽查 `inkZhong` 文本）。
- [ ] 轮盘：焦点卡清晰；过去卡在上且偏淡；未来卡在下；模糊随距离递增；减少动画模式下无模糊。
- [ ] 无 Material 默认紫/蓝色残留（检查 Switch、Checkbox、DatePicker、TimePicker、SnackBar、ProgressIndicator 的主题）。
- [ ] 日期/时间选择器也换成纸墨配色（`datePickerTheme`、`timePickerTheme`）。
- [ ] 360dp 宽无溢出；键盘弹起时底部弹层可提交。
- [ ] 所有可点目标 ≥ 44px；焦点可见；读屏能读出卡片时间、标题、状态。
- [ ] 深色模式（若已做）同样通过以上检查。

---

## 12. 里程碑与验收

| 里程碑 | 当前状态 | 未完成的验收或实现 |
|---|---|---|
| M0 环境 | 已修复共享工具链，doctor、测试、分析和双端构建通过；代码已推送 | 日常通过 setup-dev 维护，不重新安装 |
| M1 设计系统 | 文楷、墨晕白纸、主题与页面拆分已实现 | 深色真机、完整可访问性走查 |
| M2 今日页 | 轮盘、列表、圆相、桌面时间轴已有实现和测试 | OPPO profile 流畅度 |
| M3 一周页 | 多日显示、点选/圈选新建已有 | 表单/拖动已有块、离线改期 |
| M4 问询与弹性 | 快捷反馈、等待改约、迟到模式、续时、规则重排、自动微调及撤销已实现 | 统一问询队列、自然语言回复、完整双端试用 |
| M5 助手 | 兼容 API、对话、拟办确认与 Mock 测试已有 | 真实 Key/模型验收、问询联动、完整场景 |
| M6 日终分析 | 原文和确定性归档已有，版本重复已修复 | 自动 AI 分析；材料与知识回忆依已确认设计实现 |
| M7 连接与 APK | Android debug 构建通过 | 正式签名、移动网络配对、OPPO 锁屏提醒 |
| M8 电脑端 | Windows release 和置顶挂件已有 | 托盘、开机自启、备份恢复及完整运行验收 |
| M9 总体验收 | 尚未完成 | 按范围表逐条补真实证据与一周试用 |

后续实现按用户当前任务推进；具体待办与已知缺陷以 `docs/STATUS.md` 和 `vibe-blueprint/08-implementation-plan.md` 为准。

---

## 13. 需要用户本人做的事（不要代劳）

- 提供 / 粘贴 AI 服务的 `base_url`、模型名与 API Key（在电脑端设置页填写）。
- Cloudflare 账号、域名 DNS 迁移、`cloudflared` 登录授权。
- 手机开启 USB 调试、允许安装、授予通知与准时提醒权限、ColorOS 后台设置。
- release 签名口令。
- 涉及修改系统（VS 组件安装、计划任务创建）前先征得同意。

---

## 14. 已知坑

- 旧目录与 AppData 重定向：见 §2.3；统一运行共享环境入口。
- `flutter_secure_storage` Windows 需要 ATL。
- Web 端令牌只存内存（刷新需重新连接），这是有意的。
- 时区默认 `America/Los_Angeles`（用户当前所在），有夏令时；所有时间计算走 `tz` 库，已有夏令时测试，不要用 `DateTime.now()` 的本地时区代替用户时区。
- 后台维护循环每 5 秒运行，测试里用注入的 `clock`，不要 `sleep`。
- 分类由用户建立、改名和归档；任务可不归类。不要恢复四个硬编码分类。
- 本地通知 id 由 key 哈希得到，改 key 格式会导致旧通知取消不掉——改之前先全部取消再重排。
