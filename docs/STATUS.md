# 当前状态

## v2 修：设置能跳过、睡眠备注点得到、周视图能回今天（2026-10-22，1.2.11+21）

- 收（USER 手机体验反馈）：「跳过」之后设置页像被向导卡住没有跳过；睡眠表单的文字完全点不开；一周页没有回到今天的入口。
- 做法：
  - 首次设置页新增 **「先跳过，稍后在设置里改」**（`Key('setup.skip')` → `OnboardingController.skipSetup()`，`apps/planner/lib/onboarding/basic_setup_page.dart`），跳过保留设备时区与现有设置，直接进十步教程，之后可在设置里补；不再把新用户困在表单里。
  - 睡眠弹层把 **备注输入框移到最上面**（`apps/planner/lib/sheets/sleep_sheet.dart`，`Key('sleep.note')`）：原来备注在两个滚轮下面，手机上要越过滚轮才能碰到，手指一拖就被滚轮吃掉，看起来就是「文字点不开」。
  - 手机「详细课表」头部新增 **「今天」**（`Key('week.today')`，`apps/planner/lib/week/mobile_week_view.dart`）：翻到别的周之后一点回到本周今天，仍在详细课表里。
- 测试：`test/onboarding_test.dart` 新增「不想填设置也能先跳过」、`test/week_mobile_test.dart` 新增「详细课表里有今天、离开本周一点就回来」、`test/categories_sleep_test.dart` 新增「备注框一打开就在屏幕内且能输入」；`dart analyze` 干净，`flutter test` **120 passed**。
- 未做/未复现：手机端「助手回应慢」与「电脑端同步偶尔显示连接中断」仍需现场信息（慢是模型往返，还是排队；桌面 last_seen 一直有新记录，未见持续断开）；未做捏合缩放。

## v2 P2：助手会看图，而不是假装看见（2026-10-22，1.2.10+20）

- 收（USER：「他能看见图片但是不知道是什么」）：不论模型支不支持视觉，服务端都把图塞进请求；文本模型只能顺着「有图」往下瞎猜，用户看起来就是「收到了、但没看懂」。
- 做法：助手配置新增 **`vision`（这个模型能看图）** 开关（`server/app/assistant.py`，老库由 `ensure_schema` 自动补列；`assistant_configs.vision` 默认 0）。
  - 关着时收到图：直接用文字回「这个模型看不了图（或者还没打开「能看图」）……把图里的关键内容打字发我」，**不调模型、不烧 token、不装懂**。
  - 打开后照旧把图 base64 作为 `image_url` 发过去；模型侧仍拒绝图片时，回复改成「模型那边没接住这张图（原因）」，不再伪装成功。
  - 客户端「助手」设置新增同名开关（`Key('assistant.vision')`，`apps/planner/lib/pages/assistant_settings.dart`），保存后即时生效。
- 测试：新增 `server/tests/test_assistant_vision.py` 3 例（关着时零模型请求且回复「看不了图」、打开后请求里带 `image_url`/`base64`、开关能存取往返）；后端全量 **218 passed**。
- 未做：真机发图验证（等用户装 1.2.10+20 后发一张）；没有自动探测模型是否支持视觉（靠用户开关，省得猜错）；表情包/图片混合消息未单独覆盖。

## v2 P2：助手的反问（澄清队列）（2026-10-22）

- 为什么做：计划 §9.2 的「反问」一直缺实现——`assistant_questions` 表建了却从没写过，模型信息不足时只能硬猜或连着追问，微信里来回几轮还容易答非所问。
- 做法（`server/app/assistant.py`、`server/app/assistant_service.py`）：
  - 模型输出新增可选 `question: {text, options[2–4]}`；提示词补上「只在信息不足且猜错代价大时问，一次一个问题，给具体选项；能合理推断（时长、时段、结果标准）就别问」。
  - 服务端把问题写进 `assistant_pending_questions`（10 分钟有效），回复正文直接给「问题 + 1. 2. 3.」；下一轮把问题和选项带进上下文，并注明「他这回的话很可能就是回答，别再问一遍」，同时把旧问题标记为已回答（新一轮对话自动关闭）。
  - 空白回复的兜底重试不再吞掉「只提问、不干活」的合法回复（否则问题会被第二轮的「收到」覆盖，这正是自测发现的问题）。
- 测试：`server/tests/test_assistant_question.py` 3 例（问题落库并带选项、下一轮带上问题上下文并关闭旧问题、过期问题不再注入上下文）；后端全量 **214 passed**。
- 未做：客户端没有单独展示「待回答问题」（直接读 assistant 消息文本里的选项，够用）；微信/QQ 侧未真机走一遍问答（等用户有空调）。
## v2 修：手机弹层限高，保存按钮不再落到屏幕外（2026-10-22，1.2.9+19）

- 收（USER m03935「还有还有超多bug」+ 本轮手机冒烟）：手机上新建待办、记睡眠时点「保存安排/记下」没反应——按键其实被挤出屏幕。
- 根因：`AlertDialog` 自己不限高，内容再高也照原样布局。390×844 的手机上新建待办弹层高 967，`action.save-task` 的矩形落在 y=915（屏幕高 844 之外）；手指点不到的位置，用户感受就是「按了没反应、这软件是坏的」。
- 修法：`apps/planner/lib/dialogs.dart` 新增 `sheetBodyConstraints(context)`（正文最多占可见高度 82%）+ `task_sheet.dart`、`sleep_sheet.dart`、`inquiry_sheet.dart` 的正文外层包 `ConstrainedBox`，正文超出时在弹层内部滚动，动作按钮永远留在屏幕内。
- 测试：新增 `test/phone_smoke_test.dart`（真实 390×844 尺寸、真实 `PlannerApp`）：① 登录→首次设置→跳过教程→排第一件事→切「一周」→切「助手」整链；② 打开睡眠弹层，断言「记下」按钮 bottom ≤ 844。两条都先红后绿（红的时候正是按钮在屏幕外）。
- 验证：`dart analyze` No issues found!；`flutter test --no-pub` → **116 passed**。
- 未做：真机肉眼复核（本轮手机 USB 已拔，需要用户装 1.2.9+19 后截图）；「等待事项」「澄清问题」两个弹层没有逐个量高度，若同样顶出屏幕按同一修法处理。

## v2 修：引导蒙层不再吞点击，手机输入法回归（2026-10-22，1.2.8+18）

- 收（USER m03935「无法调动起输入法」+ m03935 后反馈）：手机端新建待办/助手输入框点不开键盘。
- 根因一（真 bug）：`apps/planner/lib/onboarding/coach_overlay.dart` 的蒙层是 `Positioned.fill` + `HitTestBehavior.opaque` 的 `GestureDetector`，教程没走完时整屏吞掉点击；可教程文案又写着「点这个按钮写下想做的事」，用户照做时按钮没反应、点输入框也不弹键盘。现在蒙层只挡高亮区域以外的四块，高亮处的真实控件可直接点（`_blockers()`），暗色仍由 `IgnorePointer` 的 `CustomPaint` 画。
- 根因二（无从复现）：真机 1.2.8 前没复现到「键盘不出」，先用回归测试锁住焦点→IME 链：`test/phone_ime_test.dart`（首次设置页 `setup.name`、助手页 `assistant.input`，点后 `tester.testTextInput.hasAnyClients` 必须为 true）；`test/onboarding_test.dart` 加「教程高亮处的按钮能真的点开」（点 FAB 后 `action.save-task` 出现）。
- 验证：`dart analyze` No issues found!；`flutter test --no-pub` → **111 passed**；两个新测试先红后绿（红的时候正是蒙层挡点击这个原因，测试直接定位到了真 bug）。
- 地址规范化（同版）：`AuthSession.normalizeBaseUrl` 把公网 `http://` 自动升级成 `https://`（Cloudflare 对 http 返回 301，POST 被重定向后丢 body，客户端只能报「连不上」）；本机/局域网地址保持原样。`test/session_url_test.dart` 3 例。测试总数 **114 passed**。
- 未做：真机肉眼验证（手机 USB 已拔）；「键盘盖住输入框」这类遮挡若仍存在，需要具体页面截图定位。

## v2 修：手机配助手、公众号绑定教程与键盘焦点（2026-10-22）

- 收（USER m03935）：手机上没法配置助手 API；没有绑定公众号的教程；还有输入法调不出来之类的 bug。
- 手机配助手：`apps/planner/lib/pages/assistant_settings.dart` 整张表单原来被 `desktop`（`device.role`）门禁，手机上只显示「在电脑上配」。现在人人可见：服务地址、Key、模型、每日上限都能填，保存仍走 `/api/v1/assistant/config`（v2 已是每用户自己的助手，Key 只写不读、`key_hint` 只露尾号）。
- 公众号绑定教程：`apps/planner/lib/pages/wechat_settings.dart` 原来只有「站长」视角的 AppID/Token 配置，成员没有绑定入口。现在页首是 3 步教程（关注测试号 → 发 6 位绑定码 → 绑定成功），成员可一键生成本人的码（`controller.channelBindCode('wechat')` → `/api/v1/channels/wechat/bind-code`），可看已绑定账号并解绑（`/api/v1/channels/bindings`、`DELETE /api/v1/channels/wechat/binding`）；旧的站长接口保留给管理员配应用凭证。
- 输入法：给「新建待办弹层」加了回归测试——360dp、键盘弹起时点名字输入框，`testTextInput.hasAnyClients` 必须为 true（框架层真正连上 IME）。真机没复现到「调不出输入法」的具体页面，先用测试兜住焦点→IME 这条链；已排查 `CoachOverlay` 引导层是全屏 `GestureDetector`，教程没走完时它确实会吞点击（不影响输入法），走完自动消失。
- 验证：`dart analyze lib test` → No issues found!；`flutter test --no-pub` → **107 passed**（新增 `test/phone_member_settings_test.dart` 2 例：手机成员配助手并生成绑定码、待办弹层点输入框连上 IME）。
- 未做：iOS/桌面没有单独回归；测试号二维码没内置进 App（教程里写了「微信后台 → 测试号二维码」路径）；如果输入法问题是「键盘盖住输入框」这种遮挡，得拿到具体页面截图才能定位。

## v2 P4 修：登录成功却被判「连不上」——release 包插件类错位（2026-10-22）

- 收（USER m03722「已经注册好的登录不进去、没注册好的也无法连接」+ m03786「我已经跑好注册和登录了，就是你先帮我修复这个bug吧」）：真机复现到服务端已经建号/登录成功（`users.last_login_at` 有值、`devices` 有记录），客户端却显示「连不上服务器」。
- 取证：新增 `POST /api/v1/client-log`（客户端把真实异常回传到电脑端数据目录 `client_errors.log`，release 包不落 logcat 也能看），第一次真机复现就抓到根因：`java.lang.NoSuchMethodError: no non-static method "Lio/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar;.getAll(...)"`——release 包里 Dart 侧 Pigeon 代码与 Gradle 增量编译残留的 `shared_preferences_android` Java 类版本不一致（debug 包不受影响）。
- 修一（根因）：全量 `flutter clean` + `flutter pub get` 后重新出 release 包（插件类与 Dart 侧对齐），`tools/build-android.ps1 -Mode release`；新包重新发布为 1.2.6+16（sha256 `d0a8bc16…`，23,004,007 字节）。
- 修二（兜底）：`apps/planner/lib/storage.dart` 的 `DeviceStore` 不再让任何存储后端决定登录成败——安全存储失败退回 `SharedPreferences` 明文 token，明文也失败就只记内存（本次会话可用、重启后重新登录），`read`/`write` 同样吞掉异常；`controller.dart` 登录成功后 `_save()` 也包 try/catch，并新增 `reportAuthFailure` 把真实异常上报。
- 验证（真实跑过）：干净安装 1.2.6 后用测试账号在手机上登录 → 进入「先说说你想怎么用它」引导页（账号显示名正确、`client_errors.log` 无新报错）；再 `force-stop` 重启仍在登录态（会话持久化正常）。后端新增 `server/tests/test_client_log.py` 2 例，全量 `pytest` **211 passed**；客户端 `dart analyze` 无问题、`flutter test` **106 passed**。
- 未做：ColorOS 上安全存储偶发失败的具体原因没有单独定位（已由明文/内存兜底绕过）；`client_errors.log` 没有读取界面；release 包仍用 debug 签名。

## v2 P4 修：手机登录默认走公网地址、失败自动重试（2026-10-22）

- 收（USER m03620「把服务器的默认地址改掉」+ 之前「依旧登录不上」）：登录页原来默认写死 `http://127.0.0.1:8765`（本机电脑），手机上点登录直接连不上；而且这个默认值会被旧缓存的 `server_url` 覆盖，手机端一直显示本机地址。
- 默认值：`AuthSession.defaultBaseUrl` 改成 `https://timer.studydazi.top`；`initialize()` 里如果旧缓存还是 `127.0.0.1`/`localhost` 且没有 v2 登录记录，登录页直接换成公网地址，用户不用再手改。
- 传输健壮性：`AuthSession._send` 现在把「连不上」类异常重试一次（移动网络/隧道抖动时单次请求断掉很常见），仍失败才报错；异常类型与原样错误打进 debug 日志（`[auth] ... failed (attempt N)`）。这解释了一部分「服务端其实建号成功、客户端却提示连不上」——单次请求丢了响应。
- 明文兜底：`AndroidManifest.xml` 加 `android:usesCleartextTraffic="true"`，局域网 `http://192.168.x.x:8787` 也能连（公网仍建议 https）。用户名提示改成与服务端一致的「3–32 位字母、数字、下划线、点或横线」。
- 版本：`apps/planner/pubspec.yaml` → `1.2.5+15`；`tools/build-android.ps1 -Mode release` 出包（arm64 约 23MB），`app.releases publish` 到数据目录。
- 验证（真实跑过）：`flutter test` → **106 passed**、`dart analyze` 无问题；在 OPPO（Android 17，5G）上用 debug 1.2.5 真实点登录：`[auth] credentials adopted → token stored → persisting session` 后进入「先说说你想怎么用它」引导页（登录链路通）。事件日志里之前两次「注册成功但客户端报连不上」的账号（`zzx`/`zzxx`）和诊断号 `diag` 已清理，`users` 只剩 `me`、`shidi`。
- 未做：release 包仍用 debug 签名（换 keystore 才需要刻意升级）；`http://` 公网地址仍会被 Cloudflare 301 到 https（这是对的）。

## v2 账号：支持自助注册（2026-10-22）

- 收（USER m03096「我的账号密码呢，我想自己注册」）：v2 原来只能站长用 `python -m app.admin user add` 建号，客户端只有登录页。现在加自助注册，并把「开关 + 账号合并」一起做掉。
- 开关：新表 `app_config`（迁移 `server/app/migrations/0004_registration.sql`）。默认**关闭**；关闭时 `POST /api/v1/auth/register` 返回 403 `REGISTRATION_CLOSED`。站长用 `python -m app.admin config allow-registration on|off` 开关，命令会顺手打印当前状态。
- 注册规则：开关打开、或库里的用户数为 0（全新部署）才允许注册；**第一个注册的人自动成为 `admin`**，之后都是 `member`。用户名 3–32 位 `[A-Za-z0-9_.-]`、密码至少 10 位；注册成功直接返回 token/device/user，并给新账号写入自己的 `user_state`（时区取请求里的 `timezone`，缺省 `Asia/Shanghai`）。限流沿用登录那套（每 IP 每分钟 10 次）。
- 账号合并：`python -m app.admin user merge --from me --to <新用户名>`。把所有带 `user_id` 的表按 `UPDATE OR REPLACE` 迁到目标账号（users 表本身不动，避免 id 语义漂移），材料文件目录 `materials/<source>/` 整个挪到目标目录，然后禁用源账号、吊销其设备、把目标提成 admin。给「先用临时账号跑起来、后来自己注册」这种情况收尾用。
- 客户端：登录页加「注册」模式（`login.toggle-mode` 切换，无独立路由，避免登录门导航问题）：显示名、密码、确认密码三个字段（`login.display-name` / `login.password-confirm`），本地先校验两次密码一致，服务端 code 翻成「用户名已被占用」「注册开关没开，找站长开一下」「密码太短了，至少 10 位」「用户名只能用 3–32 位字母、数字、下划线、点或横线」。会话侧 `AuthSession.register` 与 `_adoptCredentials` 复用登录成功后的持久化路径（`controller.register`）。
- 验证（真实跑过）：后端 `server/tests/test_auth.py` 12 passed（新增开关默认关闭/打开后注册成功/第一个人是 admin/关掉后拒绝/密码不一致 409 等），全量 `PLANNER_DATA_DIR=.review-data ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **209 passed**；客户端 `flutter test` → **106 passed**（新增「可以自己注册」用例：切换模式、两次密码不一致被拦、一致后调 `/api/v1/auth/register` 进首页），`dart analyze` 无问题。
- 未做：没有「注册需要邀请码/站长审批」；没有改用户名；`app_config` 只有注册开关一个键；登录页在桌面端也露出注册入口（桌面本来就能自助开）；注册后没有自动登录微信绑定引导（绑定码流程不变，去设置里拿）。

## v2 P4 修：手机 release 包停在启动页（2026-10-22）

- 症状：`app.releases` 发布的 1.2.1+11 / 1.2.2+12 release 包装到 OPPO（Android 17）后，点开只停在系统启动页或闪退；`dumpsys gfxinfo` 显示 `Total frames rendered: 0`，logcat 里没有任何 Dart 日志；同一份代码的 debug 包能正常进登录页。
- 根因：`apps/planner/lib/main.dart` 启动链上 `await controller.initialize()`、`readDesktopToken()` 等几步没有兜底——release/AOT 下任一步抛错或挂起，`runApp` 就永不执行，表现出来的就是「启动页卡死」，而且 release 看不到日志，很难定位。
- 修：启动每一步都 `try/catch` 并打 `[boot]` 检查点（`debugPrint`，debug 包可 `adb logcat | grep boot`），任何一步失败都继续 `runApp`，登录门自己会处理未登录状态；同时挂上 `FlutterError.onError` 与平台 `onError`，避免以后再无声卡死。
- 版本：`apps/planner/pubspec.yaml` `1.2.2+12` → `1.2.3+13`；release 包重新用 `tools/build-android.ps1 -Mode release` 出（arm64 约 22MB）。
- 验证（真实跑过）：`adb install -r` 新 release 包到 OPPO 后启动，正常渲染登录页（截图确认）；debug 包启动日志 `[boot] start → desktop window ready → controller ready → token absent → runApp returned` 全通过。
- 未做：release 下具体是哪一步插件初始化失败没有单独确认（已被兜底，登录页可正常用）；`debugPrint` 在 release 不落 logcat，线上诊断要改成写文件；release 包仍用 debug 签名。

## v2 P2 补修：审查报告里的两个真 bug + 材料按账号分目录（2026-10-22）

- 客户端同步队列永久卡死（审查报告 P0）：`_synchronize()` 把电脑拒绝的操作留在队头，`onlineRequest` 又要求 `pending` 为空，于是一条 400/403/404/422 的永失败操作会让之后所有操作都同步不了。现在这四类状态视为永久拒绝：摘出队列、记入本地 `preservedConflicts`（`saved_at/operations/reason/status`，最多 20 条）、状态栏提示「『新建待办』电脑没有接受：……副本已保留，不影响后面的操作。」，队列继续；409 仍按冲突阻塞（需要人处理）。
- 周日周报可能永久丢失（审查报告 P2）：`WeeklyBrief._run_for` 先 `INSERT OR IGNORE INTO weekly_briefs` 占位再发送。模型摘要失败本来就已兜住，但写 outbox 失败或周事实构建失败时占位不释放，这一周的周报就再也不会发。现在失败会删占位并抛出，下一轮（60 秒）重试。
- 材料文件按账号分目录（审查报告 P2）：原来所有账号的 `.source`/`.txt` 都堆在 `<data>/materials/` 下，靠不可猜的 UUID 兜底。现在按 `<data>/materials/<user_id>/` 存放，启动时把老库的散落文件一次性搬进 owner 目录；读取也只走调用者自己的目录。
- 验证（真实跑过）：后端新增 `test_a_failed_send_does_not_swallow_the_week`、`test_material_files_live_under_the_uploaders_folder`，`test_daily_and_weekly.py` 5/5、`test_materials_multiuser.py` 5/5；客户端新增 `test/sync_quarantine_test.dart`（422 被隔离且队列继续、409 仍阻塞），`flutter analyze` 无问题、`flutter test` 105 全绿。
- 未做：后台保留 20 条上限是拍的；没有界面让用户查看/重放已被隔离的操作；材料删除后磁盘文件仍未清理。

## v2 P2 收尾：通道按账号并行，一个人算题不再卡住其他人（2026-10-22）

- 收（`m00732` 方案「两三个用户共用一台电脑，某个人发消息不能拖住别人」+ 审查报告的「通道串行阻塞」）：微信/QQ 的 `run_once` 原来是逐条处理 inbox，每条都要等完整个模型往返（超时 45s）。改成 **按账号分组**：先按 openid 解析出用户并把未绑定的直接答「去 App 绑定」；同一个账号内保持到达顺序，不同账号用 `asyncio.gather` 并行，上限 `CHAT_CONCURRENCY = 4`。
- 每处理一条消息一个 `ChatCommands` 实例（原来两条通道各持一个共享实例）：表情包类别、临时状态不再跨消息串味；`channel_worker` 里微信和 QQ 也改为并行跑。
- 验证（真实跑过）：新增 `server/tests/test_channel_concurrency.py`（2 个用例）：两个成员同轮各发一条，假模型的 `max_active == 2`（调用真的重叠）且两条都回「好」；未绑定的陌生人只收到说明、模型调用为 0。`PLANNER_DATA_DIR=.review-data ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **202 passed**（200 + 2）。
- 未做：同一账号连发多条仍是顺序处理（有意为之，避免同一个人两个操作抢 state revision）；通道并发上限按机器手调。

## v2 P4 运维：每日备份/恢复演练 + Windows 桌面 1.2.0+10（2026-10-22）

- 备份计划任务：`tools/host/install-backup-task.ps1` 注册 `TimePlannerBackup`（每天 03:00，保留 14 天 + 8 周，错过会补跑）。真跑第一轮失败：本机宿主限制 venv 解释器写仓库外目录（`sqlite: unable to open database file`）；`tools/host/backup.ps1` 加「失败自动回退 `pyvenv.cfg` 基础解释器 + `PYTHONPATH=venv site-packages`」后，**计划任务真跑成功**：`integrity=ok tables=29`、700,416 字节，`latest.txt` 与 weekly 归档都更新。
- 恢复演练：`tools/host/restore.ps1 -BackupDir ...\backups\daily\latest.txt -DataDir %TEMP%\timer-restore-drill`（不碰真实数据）→ `integrity=ok tables=29`，并留下 `planner.db.pre-restore-*` 回滚点。
- Windows 桌面：`tools/build-windows.ps1`（release）产出 `artifacts/windows-preview-6a71cad1/`（35 MB，`time_planner.exe` + 插件 DLL + `data/`，版本 1.2.0+10）；尚未替换已安装的旧版（替换会中断正在使用的窗口），需要时用 `tools/install-timer.ps1` 更新。
- 未做：师弟真机安装/关注测试号/绑定微信（等他操作）、正式签名、多用户长跑观察。

## v2 多用户联调：真实公众号消息 + 第二个账号（2026-10-22）

- 真实微信消息跑通：主账号 openid `…3bTQ` 在 09:27:22 发「取消今晚的待办」，`wechat_inbox` 记为 done，助手按 auto 模式撤掉 18:30 的 vla 段，`wechat_outbox` 已 sent 回复「今晚 18:30 那段 vla 代码撤了……不对的话回复「撤销 6EAA」」。说明 v2 后端的 openid 路由、每人独立的助手上下文与默认直接执行在真实公众号上工作。
- 第二账号：本机 `python -m app.admin user add shidi` 建号（显示名「师弟」，Asia/Shanghai，密码另告本人），用 HTTP 探针在真实后端上验证了「生成绑定码 → 网页端推送码 → 绑定成功 → 只列自己的绑定 → 解绑」与「owner 数据一条不变」；探针是临时脚本，验证后已删除，不进仓库。
- 修多账号暴露的时区 bug：`admin user add` 建号时把文档时区写死成服务端 `America/Los_Angeles`，`PATCH /me` 也只改 `users` 表；现在 `initial_state(timezone)` / `store.state` 首次建文档读 `users.timezone`，`PATCH /me` 同步文档（revision+1 并记 `settings.update`）。`test_tenancy.py` 加 2 个用例，全量 **200 passed**。
- 未做：师弟真机安装 1.2.0+10、关注测试号并绑定、填他自己的 DeepSeek key（都在他那边操作，我只在文档里给了步骤）；Windows 桌面端重装 v2；QQ 通道真实消息联调。

## v2 多用户 P4：发布 1.2.0+10（2026-10-22）

- 版本：`apps/planner/pubspec.yaml` 由 `1.1.1+9` 升到 `1.2.0+10`（版本号是升级判断的唯一依据）。
- 手机包：v2 客户端（登录页 / 首次引导 / 手机周视图三段式）用 `tools/build-android.ps1 -Mode debug` 打出 arm64 包，通过 `app.releases publish` 的等价动作发布到 `<data>/releases/timer-1.2.0-10.apk`（97,163,935 字节，sha256 `354034d…2cb740`），`latest.json` 指向它；后端重启后 `/health` 与 `/api/v1/app/latest` 都报 `1.2.0+10`。
- 验证（真实跑过）：公网 `POST /api/v1/auth/login`（`me`）返回 200 与设备 token；带 token 的 `GET /api/v1/app/latest` 返回 `1.2.0+10`，`GET /api/v1/app/download` 200、下载 97,163,935 字节与 sha256 一致。
- 未做：Windows 桌面客户端仍是旧版（窗口开着，未重装 v2）；给第二个账号（师弟）建号与真实绑定联调；公众号测试号最多 20 个关注者，需他先关注再绑定。
- 注意：发布目录与 `latest.json` 在数据目录，不进 Git；正式签名尚未配置，当前是 debug 包（个人自用可接受，正式分发前需配置签名）。

日期：2026-10-22。总体目标：完成 Android + Windows 的个人日程管理初版。尚未达到完整交付条件。

## v2 多用户 P2：材料、复盘与周报按用户（2026-10-22）

- 收（`m00732` 方案「材料/复盘/周报按用户」）：`materials` 的生成表 `review_generations` / `auto_review_attempts` 加 `user_id` 列并回填主账号（`ALTER TABLE` + 空值回填，旧行不丢）；行键改为 `${user_id}|${request_id}`，避免两个账号用同一个 request_id 互相覆盖；`operations.id` 有 100 字上限，复盘写入的 operation_id 改为「前缀 + sha256(user:request) 前 60 位」。
- 接口：`POST /materials/upload`、`POST /reviews/generate` 从 owner 门改为任意已登录设备，按 `tenancy.user_id(store, device)` 取人；材料、复盘原文与分析、素材摘要全部写进该用户自己的 `user_state`。
- 生成：素材摘要、复盘正文、自动复盘都按该用户的助手配置、密钥、额度和时区跑；自动复盘遍历 `users(status='active')`，每个账号各自计数与 15 分钟退避（attempts 行键带 user 前缀），一个账号的模型失败不影响另一个。
- 周报：`weekly_briefs` 主键改为 `(user_id, week)`，旧表自动迁到主账号；周日 20:00 后遍历「已绑定微信且账号启用」的用户，按各自时区算本周、按各自 `user_state` 取事实，用 `channel.enqueue_to(openid)` 只发本人微信；去重键 `weekly:{user_id}:{week}`，`RoutedChannel` 补了 `enqueue_to` 转发微信通道。
- 验证（真实跑过）：新增 `server/tests/test_materials_multiuser.py` 4 个用例（材料只进调用者、复盘只存请求者、同 request_id 跨账号不冲突、周报只发给各自 follower）；`PLANNER_DATA_DIR=.test-data ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **198 passed**（194 + 4）。修了两个只有多用户才暴露的问题：`review.analysis` 漏传 user_id 会写进主账号、operation_id 超长 100 字上限。
- 未做：真实公众号发消息联调（等用户下一次发微信）、客户端「材料/复盘」页按用户的真机核对、周报仍只走微信不路由到 QQ（有意为之）。

## v2 多用户 P2 通道：一个公众号多人用（2026-10-22）

- 收（`m00732` 方案「通道多账号」）：绑定不再只认主账号。`0003_channel_identity.sql` 建 `channel_identities`（微信/QQ 的 openid → 用户）与 `channel_bind_codes`（6 位码、10 分钟有效、一次性）；`server/app/channel_identity.py` 的 `IdentityStore` 负责绑定/解绑/换绑与旧文件绑定迁移。旧安装的 `wechat.json`/`qq.json` 里已有的 openid 第一次收消息时自动归给主账号，不用重绑。
- 绑定入口：App「账号」页 POST `/api/v1/channels/wechat/bind-code` 生成 6 位码（`GET /channels/bindings` 查绑定、`DELETE /channels/{channel}/binding` 解绑）。未绑定的微信号发消息只收到「打开瞬时 App → 账号 → 绑定微信」的引导；绑定码发错、过期、被用过都有具体说明；已绑定用户发 6 位码不会被误当成指令。
- 路由：`wechat.receive` 先按 openid 查用户，再以该用户身份跑 `ChatCommands`（`state(user_id=…)`、助手会话与草稿都按用户隔离）；`run_once` 逐条解析身份，未绑定的消息标记完成、不建助手消息。跨账号隔离测试覆盖：两个微信号各改各的日程、A 的绑定码不能绑到 B、解绑后回落到引导。
- 验证（真实跑过）：`PLANNER_DATA_DIR=.test-data ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **194 passed**（189 + 5：`test_channel_identity.py`）。原 `test_wechat.py` 三条断言按多人语义更新（陌生人收到引导而非静默、错误码文案、已用码不泄露主账号数据）。
- QQ 机器人同样按 openid 路由：`qq.py` 接 `IdentityStore`（6 位码绑定、未绑定收「打开 App → 账号 → 绑定 QQ」引导、旧 `qq.json` 绑定第一次收消息自动归主账号），`run_once` 逐条解析身份后以本人身份跑 `ChatCommands`，解绑时清掉身份记录；`test_qq.py` 38 个用例覆盖绑定/陌生人引导/按用户路由。
- 未做：材料/复盘/周报按用户、真实公众号联调（2026-10-22 已配好测试号 appid/appsecret，回调签名本地验证通过，待真实发消息确认）、QQ 旧文件码路径的文档化。

## v2 多用户 P3 客户端：手机周视图三段式与首次使用引导（2026-10-22）

- 手机周视图（`<600dp` 走 `MobileWeekView`）：整周 7 列色块总览（一色一事、长按看全名、今天高亮）→ 点某天进单天概览（计划/已投入/完成/中断四个数字 + 紧凑列表）→ 再进详细课表（`WeekCalendar`，缩放 75%–200%，换周回总览）；桌面 `≥600dp` 仍是原整周 hour 网格（`zoom=1.0` 默认路径零改动），`resolvePlannedTime` 的 DST 处理未动。新增 `lib/week/`，`WeekCalendar` 加可选 `zoom` 并导出新 widget。
- 首次使用引导：`GET /me` 返回 `onboarding` 字段的账号才会出现；先基础设置（显示名、时区、每天开始/结束、助手先问再做/直接执行）→ 10 步高亮教程（遮罩挖洞、下一步/上一步/跳过/进度点，支持重启续播与设置页「重新看教程」）；进度本地优先、`PATCH /api/v1/me` best-effort，断网待恢复后补推。无该字段的老账号视为已完成，不打扰。
- 验证（真实跑过）：`apps/planner` 下 `flutter analyze` → **No issues found!**；`flutter test` → **103 passed**（88 + 15：`week_mobile_test.dart` 6、`onboarding_test.dart` 9）；`pubspec.lock` 未变。
- 未做：真机与 Windows 桌面肉眼检查（遮罩圆角/避让、长按手感、360dp 触控）、捏合缩放手势、手机详细课表的单日网格形态、平板中间宽度/横屏/大字体、后端 `PATCH /me` 真实联调（客户端仅 MockClient 验证请求形状）。

## v2 多用户 P2：每人自己的助手（2026-10-22）

- 收（`m00732` 方案、`m00671` 拍板「每人自带 key、新用户默认直接执行」）：`assistant_messages/drafts/undo/memes` 五表加 `user_id`（旧库由 `assistant.ensure_schema` 补列并把 v1 行归给主账号，不重建表）；新增 `assistant_configs`、`assistant_keys`、`assistant_usage_by_user`、`assistant_questions`（`server/app/migrations/0002_assistant_multiuser.sql`）。主账号第一次读配置时，把 v1 的 `assistant.json` 与 `secrets/llm-key` 一次性导入数据库，旧安装不用重填。
- 钥匙只存密文：`AssistantConfigStore` 用 `secrets/llm-master`（32 字节，首次自动生成）派生两条子钥，以 HMAC-SHA256 计数器流加密、独立 HMAC 标签认证（encrypt-then-MAC）；API 只回 `key_hint`，`PLANNER_LLM_API_KEY` 仍只对主账号生效。测试断言数据库文件里没有明文 key。
- 隔离：`/api/v1/assistant/{config,test,models,messages}` 与 `drafts/{id}/{apply,dismiss,undo}` 从 `OWNER_ONLY` 改为任意登录设备，但只能读写自己的配置、历史、草稿与用量；别人的草稿 id → `404`。人设 `persona` ∈ 大肥鱼/老师/朋友/严格教练，`converse` 把它拼进系统提示。
- 仍属主账号：微信/QQ 通道、材料与复盘生成、周报仍是主账号数据（`service.user()` 默认落主账号）；公众号多账号绑定与聊天路由在 P2 通道阶段另做。
- 验证（真实跑过）：`PLANNER_DATA_DIR=.test-data ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **189 passed**（185 + 4：`test_assistant_multiuser.py` 覆盖两人各自配置/历史/用量隔离、成员草稿只改成员日程、他人草稿 404、人设校验、v1 文件一次性导入）。原 `test_assistant.py` 两条断言按新语义更新（钥匙存库内密文、手机可改本人配置）。
- 未做：通道多账号与路由、材料/复盘/周报按用户、澄清队列真正接进对话（表已建）、客户端人设与助手设置文案（随 P3 页面做）、真实模型联调。

## v2 多用户 P1：账号、租户隔离与过渡兼容（2026-10-22）

- 依据 [v2 多用户方案](plans/v2-multiuser-plan.md)（`m00732`：按方案开发，用已注册的公众号测试号）。分支 `v2`，不改动 `main` 的已发布行为；旧客户端、桌面 token、配对码三种入口都能继续用。
- 后端账号：新增 `server/app/auth.py`——注册/登录/登出、改密、设备列表与吊销；密码哈希自描述（`scrypt$n$r$p$salt$hash`，装了 `argon2-cffi` 时优先 argon2id，两种前缀都能验证），只存 token 的 sha256 不存明文；登录 10 次/分钟/IP（走 `cf-connecting-ip` 时按真实 IP）、密码 ≥10 位、用户名 2–24 位 `[A-Za-z0-9_-]`、停用账号登录回 `ACCOUNT_DISABLED`；密码或账号状态变了会吊销其它设备，保留当前设备。
- 租户隔离：新增 `server/app/tenancy.py`（`user_of` / `require_owner`）与 `server/app/repo.py`（按 `user_id` 读写 `user_state`、`user_events`）；`Store.state/save` 默认仍作用于主账号，旧 `document`/`events` 表继续同步，所以 `assistant_service`、通道层、维护任务原样工作。跨账号 id → `404 NOT_FOUND`（不泄露存在性），`operation_id` 跨账号重用 → `409 OPERATION_ID_REUSED`；助手/QQ/微信端点在 P2 前只允许主账号（`403 OWNER_ONLY`），成员账号看不到这些数据。
- 数据层：新增 `server/app/db.py` + `server/app/migrations/0001_multiuser.sql`（`users` / `user_state` / `user_events` / `schema_version`；`devices.user_id`、`operations.user_id` 由 `ensure-column` 在旧库上补列，不重建表）；`admin` 命令（`python -m app.admin user add|list|reset-password|disable|enable|promote`）用于本机开号，不暴露注册接口。
- API：`POST /api/v1/auth/login|logout`、`GET/PATCH /api/v1/me`、`POST /api/v1/me/password`、`GET/DELETE /api/v1/me/devices`；`/snapshot`、`/operations`、`/plan/*` 改为按设备所属用户读写；旧配对流程保留（手机用配对码拿 desktop-token 的路径等价于登录主账号）。
- 客户端 P1（teammate 交付，已复跑验证）：`lib/auth/session.dart`（token 走原 `FlutterSecureStorage` 槽，地址/用户/设备写 SharedPreferences）、登录页、启动门（`/me` 200 进首页 / 401 清会话回登录 / 网络失败离线放行）、设置页账号区块；`request()` 统一 401 → 清 token 和本地 state/pending（避免旧队列重放给下一个登录账号）；无 desktop-token 时走登录门，有 token 时旧桌面路径不变。
- 运维（teammate 交付）：`tools/host/backup.ps1`（SQLite 在线备份 + `users\` 素材 + 14 天/8 周保留 + 2MB 轮转日志）、`restore.ps1`（integrity 校验、端口守卫、先改名不删除）、`restore-drill.md`、`install-backup-task.ps1`；[运维手册](ops.md) 写 cloudflared 隧道/公众号测试号回调/计划任务/异地备份。
- 验证（真实跑过）：`PLANNER_DATA_DIR=.review-data ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **185 passed**（171 + 14：`test_auth.py` 8、`test_tenancy.py` 6）；`apps/planner` 里 `flutter analyze` → **No issues found!**、`flutter test` → **88 passed**（77 + 11）；ops 脚本 13 阶段真跑 0 失败（夹具在 `%TEMP%`，未碰真实数据）。
- 未做：P2 助手 2.0（每账号独立的助手配置/记忆/消息/草稿、画像与周报、待补问路由）、公众号多账号绑定与聊天路由（当前只有主账号）、onboarding 接口与客户端教程高亮、首页改版；真机 Android/桌面联调；`timer.yml` 与 `tools/tunnel-watchdog.ps1` 的 8787→8765 迁移、cloudflared/公众号真实回调联调。


## QQ 机器人「光收到不干活」：整条草稿连坐、空回复兜底、没有执行记录（2026-10-22）

- 成因（`m00262`：用户说「目前我和qq聊天，他光会收到不干活」）。真实数据复查：当天上午用户在 QQ 里说「结束网络训练，结果：网络已经成功启动训练；然后新建待办现在开始学习代码到吃晚饭前」，得到的回复只有「「网络训练」还没有可以反馈的执行记录」，隔一条又只回「收到。」；`assistant_drafts` 当天只有凌晨两条，之后 0 条。用真实模型把当天那几条消息各重放一遍（复制数据目录到临时目录、只打日志不落库），复现出三个叠在一起的原因：
  1. **整条草稿连坐**：模型把一个「记结果 + 撤掉旧段 + 新建待办」写成**同一个 draft 里的三个动作**；`converse` 的试运行用 `deepcopy(state)` 逐个 apply，错在「记结果」上就把整条草稿丢掉——合法的重排一起没了。模型输出是概率性的，所以同样的话有时能办成、有时办不成，用户看到的就是「光收到不干活」。
  2. **空动作被当成正常回合**：模型偶尔回一条合法 JSON、`reply` 和 `drafts` 都是空的；`_answer` 的兜底是 `said or "收到。"`，于是原样发给用户。
  3. **没点过开始就没有执行记录**：电脑关着、用户只在 QQ 里说「网络训练做完了」，这时没有 session；助手层的 `draft_operations` 要求 session 处于 `awaiting_feedback`，而 API 的 `FeedbackCreate` 比 domain 更严（只有 `not_started` 允许不带 session），于是这条反馈被降级成一句技术说明；`control_session` 的结束动作同样要求已有 session。
- 修：
  - `assistant.resolve_drafts` 拆成逐动作的 `resolve_action` / `note_for`：一条动作对不上只丢这一条（并给人话，例如「对应任务或安排不存在」「这个时刻已经过去了」），同一条消息里其余动作照常保留；`assistant_service.converse` 的试运行也改成逐动作校验，只把通过的动作存进草稿。提示词同时要求「一句话里有几件事就拆成几个 draft」，减少连坐概率。
  - 空回合（`reply` 与 `drafts` 都空）视为一次失败重试，追问一句「改日程必须给 drafts，闲聊就正常回」；重试仍空才回「刚才没接住，你再说一遍？」。`_answer` 在「没拟成 / 没动手」时补上「这次没拟成：」「这次没动手：」前缀，不再把失败伪装成成功。
  - 反馈允许落在「还没开始的段」上：`FeedbackCreate` 放宽为「有 `session_id`，或指明 `block_id`」即可（domain 本来支持对 `scheduled` 段直接记结果）；`draft_operations` 对没有 session 的 scheduled 段用 `block_id` 记结果，对已结束的段给出「这段已经记录过结果了」；`control_session` 找不到 session 时提示改用 feedback。提示词补上这几种情况的说明。
- 验证：`PLANNER_DATA_DIR=.review-data ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **171 passed**（167 + 4）。新增：一条草稿里坏动作不连坐（其余照做）、没点开始也能记结果（段 completed / 任务 done）、空回复重试后必须给出草稿、`test_qq.py` 端到端一条（QQ 收「明早十点学两小时算法」→ 假模型返回 `schedule_new` → 真的写进 `blocks` 且回复不是「收到。」）。
- 未做：真实 QQ + 真实模型复测（模型概率性，最好在机器人上把当天那几句话再发一遍）；已经应用错的旧数据不回改。

## 助手看图：在 QQ 里发图片，它能看懂（2026-10-22）

- 成因（`m01790`）：用户「我希望她能识别我发给她的图」。此前 `qq.py` 收到带附件的消息只会回一句「语音、视频和文件我暂时还看不了」，图片等于白丢。
- 收：`qq_inbox` 增 `media_url`/`media_type` 两列（老库按 `PRAGMA table_info` 补列，不重建表）。C2C 事件里取第一个 `content_type` 属于 jpg/png/gif/webp、`url` 是 https 的附件，记成 `kind='image'`；纯文字与图片进 `pending`，其余附件仍回那句提示。
- 传：`async def _fetch_image(url, mime)` 用 `httpx.AsyncClient(timeout=20)` 下载，非 https / 非 200 / 空 / 超 6MB / 格式不对分别抛 `QQ_IMAGE_URL`、`QQ_IMAGE_DOWNLOAD`、`QQ_IMAGE_TOO_BIG`（413）、`QQ_IMAGE_TYPE`（415），错误语直接当回复发回去，**图不往模型里塞**。腾讯的 CDN 有时把图片报成 `application/octet-stream`，这时回退到 QQ 声明的 `content_type`（`test_qq.py` 有专门用例）。
- 看：`assistant_service.converse(text, image=...)` 把 `{"type":"image_url","image_url":{"url":"data:<mime>;base64,..."}}` 拼在文字后面一起发；`assistant_messages` 里存 `[图片]` 占位，聊天记录不落 base64。图片消息**跳过指令正则**（发图不会被当成「完成了」），配文照常带上。
- 能力边界（实测过的）：当前模型 `deepseek-v4-flash`（`api.deepseek.com`，OpenAI 兼容）能读图——拿一张动漫截图试，能把气泡里的「已思考（用时 13 秒）> 好女孩」读出来；纯 8×8 的极小 PNG 它判「无效图片」，太小的图（头像/图标）不保证。
- 顺带修的：这个模型偶发「正文全花在思考上、`content` 只回空白」（实测 1/4 概率），`complete()` 现在把空白当一次可重试的失败，重试用尽回「模型这次没回到正题，再问一次试试？」而不是把空字符串当答复。
- 验证（真实跑过）：`PLANNER_DATA_DIR=<仓库内临时目录> ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **167 passed**（164 + 看图 2 条 + 空白回复 1 条）。`test_qq.py` 新增 6 条：模型确实收到图片、配文随图、太大、下载失败、格式打不开、`qq_inbox` 记下 `media_url` 且 `assistant_messages` 存 `[图片]`。
- 未做：语音、视频、文件（仍是那句明确提示）。

## 助手表情包：只留「大肥鱼」一套，且要跟回话对得上（2026-10-21）

- 成因（`m01502`）：上一版素材是混的——大肥鱼里掺了白毛、粉猫娘、猫图、人偶图，同一张图还被塞进了不同类别；而且只要模型填了类别就发图，连「这个安排还没开始，提前不动」这种带失败信息的回复也配了张表情包。用户要求：只发大肥鱼的表情包，且表情包要符合回复逻辑。
- 素材只留 [astrbot-deepseek-meme-pack](https://github.com/shirachino/astrbot-deepseek-meme-pack)（`deepseek-girl-pack`「大肥鱼表情包」，CC0）。仓库超 50MB，GitHub API 限流、codeload 传输截断、jsDelivr 拒绝大于 50MB 的包，最后改成按目录页解析 + `raw.githubusercontent.com` 单文件下载，49 张候选拼版人工筛。**最终 13 张 / 11 类，共 764K**：`server/assets/memes/<英文类别>/<n>.jpg`——`angry`（炸毛「哈！」、伸爪）、`baka`（碗里「不赖」）、`confused`（咕咕嘎嘎）、`fool`（呆滞大眼）、`happy`（大笑、献花）、`like`（已思考·好女孩）、`sad`、`sigh`（哦鲸鲸）、`sleep`（晚安）、`surprised`、`work`（老实写代码吧）。混进来的白毛/粉猫娘/猫/人偶全部剔除，旧的中文目录整体删除。
- 挑选逻辑：`server/app/memes.py` 的类别从 7 个元组改成 **11 类 dict，每类带「什么时候该用」**，由 `memes.hint()` 拼进系统提示词（`__MEMES__` 占位替换），模型只在回复里填 `meme` 字段、不再自己造类别名。挑图从「每类第一张」改成按钉住种子的 rng 随机，并用 `qq.json` 的 `recent_memes` 记住**最近发过的 2 张**优先避开，避免一套小素材反复刷同一张。
- 门禁：`assistant_service.py` 把插表情包挪到最后一个块——**只有回复成功且没有 `notes`**（未识别编号、安排还没开始、模型没配置等失败信息）**时才插**，否则连模型已经存下的那条也删掉；微信通道同样生效。
- 验证（真实跑过）：后台 `PLANNER_DATA_DIR=<仓库内临时目录> ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **159 passed**（154 + 5）；`test_memes.py` 8 项覆盖未知类别、确定性、`avoid` 行为、路径穿越、每种都已成包；`test_qq.py` 新增「回复带失败信息时不发图」。另用真实模型跑了五句（`artifacts/meme-preview.py`）：累→晚安、夸人→好女孩、拖延→哦鲸鲸、大笑→献花、排程→老实写代码，「提前半小时」遇安排未开始→**不出图**。
- 文档：`docs/design/assistant-voice.md` 第四节重写（单一套素材、CC0 出处、13 张 11 类、对不上就不发、换素材与 `tools/meme_sheet.py` 拼版审图的方法）。

## QQ 机器人接管聊天入口、助手人格改「大肥鱼」（2026-10-21）

- 起因：用户嫌公众号测试号「头像不能改、消息界面很难进、不能置顶、没有人格」，要求改成 **QQ 机器人**接管，并且「不仅是助手、更是朋友」。按用户批准（`m00179`：直接走 B、允许改后端）做的是 **Timer 原生 QQ 通道**，不是外挂 AstrBot；公众号那条路保留可用。
- **抽出指令大脑**：新增 `server/app/chat_commands.py`，把「一句话变成日程动作」的整段逻辑从 `wechat.py` 搬出来给两条通道共用（帮助、今天、拟办确认/撤销、提前、再给 15 分钟、今日总结、记忆、空闲兜底），`device` 只影响自称是「微信」还是「QQ」。`wechat.py` 从 583 行缩到 413 行，`/api/v1/wechat/*`、回调验签、六态投递全部不变。
- **新通道 `server/app/qq.py`**：QQ 官方机器人 WebSocket 长连接（只订 `C2C_MESSAGE_CREATE`，intent `33554432`；`Authorization: QQBot <token>`，token 提前 60 秒过期、401 自动换一次）；出站沿用六态队列（queued/sending/sent/failed/unknown/expired/cancelled），60 分钟被动窗口内借最近一条 `msg_id` 回复，过期自动转主动消息，`msg_seq` 撞车递增，限频与连不上按 30/120/600/1800 秒退避，`unknown`（超时）**永不自动重发**，崩溃重启把残留 `sending` 标 `unknown`。绑定沿用 6 位码机制（只存 sha256、10 分钟、一次性）；换 AppID 自动解绑，因为 `user_openid` 是每个机器人独有的。收发表独立成 `qq_inbox`/`qq_outbox`，不动微信的两张表。
- **通道选择**：新增 `server/app/channels.py` 的 `RoutedChannel`，按「已配置且已绑定」在 QQ 和微信之间挑一条当提醒投递目标（QQ 优先），`proactive.py`、`weekly.py` 一行未改；`main.py` 增加 `/api/v1/qq/{config,bind-code,unbind,test,outbox}`，形状与微信那组一致，配置接口额外带 `connected`（网关长连接是否就绪）。
- **人格**：`server/app/assistant.py` 的身份段改成「大肥鱼」——闲时能正常聊两句（`drafts` 留空、reply ≤80 字、不追问、闲聊不写 `remember`），一涉及日程立刻收敛成干活模式（reply ≤40 字）；动作清单、时间规则和 JSON 输出契约一字未动，见 [助手机制](design/assistant-behavior.md)。
- **验证（真实跑过的）**：后台 `PLANNER_DATA_DIR=<仓库内临时目录> ./server/.venv/Scripts/python.exe -m pytest server/tests -q` → **146 passed**（原 119 + 新增 `test_qq.py` 27 项）；`flutter test` → **72 passed**；`flutter analyze` → **No issues found**。`test_qq.py` 覆盖：`QQBot` 鉴权头与 token 复用、重推去重、陌生号静默丢弃、绑定码一次性且跨重启有效、刚聊过天走被动回复、无近期互动走主动消息、长回复分片按 `msg_seq` 递增、超时记 `unknown` 不重发、连不上与限频按退避重排、被动凭证失效转主动、解绑后旧提醒失效。公网侧实测过真实 `/gateway` 与 token 接口响应（假 token 返回 401 / 11244）。
- **真实机器人验收（2026-10-21 21:26，用户提供的正式机器人 AppID `1905884176`）**：凭据落在 `%USERPROFILE%\TimePlanner\data\qq.json` 与 `secrets\qq-secret`（不进 Git）。后台取到 `access_token` 后网关长连接就绪（`connected: true`），用户在 QQ 里发 `547913` 完成绑定（openid 尾号 `2876`），随后三种投递方式全部真实送达：① 绑定欢迎语（`channel=passive`）② `POST /api/v1/qq/test` 测试消息（`passive`，借最近一条 `msg_id`）③ 把 `last_msg_at` 拨到 60 分钟前再测 → `channel=active` 主动消息成功（无 `40054013`，说明用户客户端「允许接收主动消息」是开着的）。用户问「你是谁」时按大肥鱼人格回了「大肥鱼啊，你的搭子兼助理…」并顺带提到 10:30 的安排。`qq_outbox` 四条全 `sent`、`attempts=1`。
- **绑定码用完即焚**：绑定成功时把 `bind_code_hash`/`bind_expires_at` 就地清空（原先只在解绑时清），`test_qq.py` 增加对应断言。
- **启动兜底（2026-10-21 晚）**：`tools/install-timer.ps1` 生成的 `Start-Timer.ps1` 先用 `server\.venv\Scripts\python.exe` 起后台；若 15 秒内 `/health` 不通，再用 `pyvenv.cfg` 里 `home` 指向的基础解释器（必须在仓库外）加 `PYTHONPATH=server\.venv\Lib\site-packages` 重试一次，仍失败写 `launcher.log`。起因是这台机器上出现了「按可执行文件路径限制写盘」的托管沙箱——venv 里的 python 能启动却写不了 `%USERPROFILE%\TimePlanner\data`（`store.py:63` 的 `PRAGMA journal_mode=WAL` 报 `unable to open database file`），基础解释器不受这条限制。实测：停掉后台后 `Start-ScheduledTask TimePlannerBackend` → 25 秒 `/health` 通、进程是基础解释器、`bound` 仍在、`connected` 自动恢复、测试消息 `sent`。
- **还没验证的**：「头像可改」「能置顶」是 QQ 客户端行为，要在手机上看；单聊界面是否显示机器人头像官方说法不一致；主动消息每天 1000 条配额未压测；`C2C` intent 是否需后台申请、同 AppID 多开是否互踢，也没有实测条件。

- **未做**：语音/视频/文件（图片已经能看懂，见上一节）；随机主动搭话（用户明确说不需要，只要有规律的提醒）；群聊。
- **文档**：接入步骤与限制 `docs/guides/qq-bot.md`，协议契约 `docs/qqbot-c2c-api-spec.md`，HANDOFF/README/助手机制已同步。

## 弹性执行：结束也顺延/提前，界面按实际时刻展示（2026-10-20）

- 此前的问题：顺延只在开始、续时、恢复时触发，最常见的「结束并反馈」不调整后续；提前结束从不把后面的安排往前挪；所有界面都只画计划时间，实际偏离后看不出来。
- 结束也参与调整：晚于计划结束时，超出部分走同一条顺延规则（同日、后续弹性段、每段 ≤30 分钟、无固定/保护/检查点阻挡时自动应用，否则出提案）；早于计划结束 15 分钟以上时，对紧接且可连成一片的后续弹性段生成 `kind=early` 草稿提案（最多前移到当前时刻），App 与公众号都可见，公众号回复「提前」即生效。执行段一旦有记录，校验新建/重排时以实际区间为准，不再被同一段的计划占位误判为冲突。
- 展示改为**实际为主、原定为辅**：`blockSpan` 统一取实际区间，今日卡片、列表、时间轴、周总览、周视图、桌面挂件、详情页和「接下来」判断全部随之；结束后显示真实起止并在小字标「原定 HH:MM–HH:MM」，详情页标「（实际）」。实际区间互相重叠时在周视图/时间轴/周总览里并排分道，不叠成一团。
- 公众号：晚结束提示「后面的安排已顺延 N 分钟」；早结束提示「早了 N 分钟…回复「提前」就改」；被固定安排挡住时提示打开瞬时查看。消息按执行段和提案去重，提案被确认或过期后旧消息失效。
- 验证：后台 **119 passed**；Flutter **70 passed**；analyze **No issues found**。另用一次性临时数据目录做端到端实测：09:00–10:00 的计划 09:12 开始、10:10 结束，后续两段自动后移 10 分钟，重启后台后实际结束时刻与顺延结果仍在；09:40 提前结束时生成前移 20 分钟的草稿，重启后确认，后续两段同时前移。真实公众号收信与手机通知仍待实机验收。
- 本轮改动已提交（`95f1422`）并推送到 GitHub。已发布 **1.1.0+8**（2026-10-20，`tools/release.ps1`）：电脑客户端已关闭并重新安装，后台 `/health` 报告 1.1.0+8；arm64 APK（97,055,719 字节，SHA-256 `ff08ec…f59e`）已发布到数据目录 releases 并复制到桌面 `瞬时-手机版.apk`，与发布文件校验一致。手机打开 App 会在检查更新后提示下载安装。

## 隧道守护：掉线后自动重启（2026-10-20）

- 现象：1.1.0+8 发布后几分钟，外网全部返回 **530**，手机同步和下载都失败。`cloudflared` 进程还在，但日志反复 `DialContext error: dial tcp 198.18.0.x:7844: i/o timeout`（本机代理 TUN 的假 IP），最后报 `no free edge addresses left`。进程检查发现不了这种「活着但不可用」，当时只能手动重启。
- 守护：新增 `tools/tunnel-watchdog.ps1`，每分钟检查一次：本机 `/health` 是否 200、公网 `https://timer.studydazi.top/api/v1/snapshot` 是否返回 401/200。进程不在直接重启；进程在但公网连续 3 次失败也重启；重启后 5 分钟内不重复重启，避免网络整体中断时反复拉起。本机后台不响应时先调用 `Start-Timer.ps1 -BackendOnly`。命名互斥量保证只有一个实例，日志写 `%USERPROFILE%\TimePlanner\logs\watchdog.log`（超过 1 MB 轮转）。`-Once` 用于单次检查，`-ProbeUrl` 可指定探测地址。
- 注册：`tools/install-autostart.ps1` 现在注册两个登录任务——`TimePlannerBackend`（30 秒后起后台与隧道）和 `TimePlannerWatchdog`（60 秒后启动守护，隐藏运行、不限时长、失败重启 3 次）。`-Remove` 删除两个任务，`-ValidateOnly` 检查两个。
- 实测：手动杀掉 `cloudflared` 后运行一次 `-Once`，**12.9 秒**恢复；把探测地址指向不可用端口时只记为 1/3 失败、不误重启（退出码 0）；常驻任务启动后在 5/15/30/60 秒检查均只有一个实例。让常驻守护处理一次真实掉线：停掉 `cloudflared` 后，下一次检查（约 48 秒）发现进程不在并重启，公网在停止后 **53 秒**恢复 401。进程仍在、只是公网连不上的情况走 3 次失败阈值，本轮用不可用探测地址验证了计数与不误重启。隧道若因代理长期不可用，守护仍会按冷却节奏重试并记录，不会静默。
- 说明：守护只能修复“进程掉了或连不上边缘”的情况，不能替代代理/网络的正常配置；`198.18.0.x` 来自本机代理，关掉代理或改规则后需重启隧道（守护会自动做）。

## 登录后自动启动后台与隧道（2026-10-20）

- 现象：电脑重启后手机连不上。原因是后台与 Cloudflare 隧道只由桌面「瞬时」快捷方式（`Start-Timer.ps1`）启动，没有任何开机入口；重启后 `127.0.0.1:8787` 无监听、`cloudflared` 不在运行，数据目录本身完好。
- 修复：`tools/install-autostart.ps1` 注册计划任务 `TimePlannerBackend`（当前用户登录后延迟 30 秒，以隐藏窗口运行 `Start-Timer.ps1 -BackendOnly`，不限运行时长，失败重试 3 次）。只起后台与隧道，不弹客户端窗口；与快捷方式同时触发也安全（脚本本身幂等）。`-Remove` 删除任务，`-ValidateOnly` 只查状态。
- 实测：先手动停掉后台与 `cloudflared`，再 `Start-ScheduledTask`；后台恢复为 1.1.0+7，隧道进程出现，外网 `/api/v1/snapshot` 无凭证 401、`/wechat/callback` 伪造签名 403、`/health` 404。任务动作可用；登录触发本身待下次重启验证。
- 注：隧道每次启动日志会先报一条 `Failed to initialize DNS local resolver ... i/o timeout`，随后仍能正常连上（外网返回后台自身的 401/403），暂按无害处理。

## 日终复盘只看今天、周日简报（2026-10-20）

- AI 日终复盘：此前把助手的完整上下文（所有未完成任务、前后一周安排、往日回顾和材料）一并交给模型，于是会汇报别的日子。现在只给当天记录、当天材料、用户当天原文和长期偏好；输出最多 4 行（做成了 / 学到了 / 卡在 / 下一步）、180 字以内，存储上限 600 字。真实模型（DeepSeek）隔离实测：约 90 字，只讲当天。
- 周日简报：每周日 20:00（设置时区）经公众号推送一次「本周简报」：专注时长与段数、确认完成件数、投入最多的三件事，再加模型写的不超过 120 字概括；模型不可用时只发数字和完成清单。按周去重（`weekly_briefs` 表，先占位再生成，不会重复发送或反复调用模型）；关闭「主动推送」或未绑定时不发。实现见 `server/app/weekly.py`。
- 验证：后台 **111 passed**（新增 4 项）。

## 数据目录迁出 AppData（2026-10-20）：修复手机与电脑连不上

- 现象：发布后手机、电脑都连不上，App 也收不到更新提示；隧道返回 Cloudflare 1033。
- 原因：Claude 桌面版是打包（MSIX）应用，从它的会话里启动的进程写 `AppData` 时被重定向到 `Packages\Claude_…\LocalCache\Local\TimePlanner`。此前由会话启动的后台一直读写这份副本（全部任务、配对、微信绑定、模型 Key、安装包都在那里），而电脑客户端和用户自己的快捷方式看到的是真正的 `AppData`。Claude 重启时，挂在会话下的后台被一起结束；隧道进程此前也已断开。
- 修复：数据与日志默认目录改为 **`%USERPROFILE%\TimePlanner\data` / `logs`**（后台、电脑客户端、发布脚本、启动器一致；`PLANNER_DATA_DIR` 仍可覆盖）。包缓存中的数据已原样复制过去（SQLite 完整性检查通过，10 个待办、4 台配对设备），原件保留作备份。`tools/restart-backend.ps1` 改用 WMI 启动启动器，后台与隧道不再属于调用者的进程树，关掉终端或 Claude 不会再把它们带走。
- 真正 `AppData\Local\TimePlanner\data` 里只有排查时误建的一个空库和凭证（10/20 7:44），没有用户数据，可忽略。

## 改名「瞬时」、周视图换样式、宣传页上线（2026-10-20）

- 产品对外名称改为 **瞬时**（不再叫 Timer / 日程之间）：App 标题、窗口与标题栏、安卓桌面名、通知、更新提示、助手自称、公众号消息与桌面快捷方式（安装时删除旧的 Timer.lnk）。代码标识、仓库名、安装目录与包名不变，避免影响升级与已有配对。
- 周视图：用户认为墨晕色块「颜色脏」。去掉不规则形状和渐变，改为**平涂浅底 + 左侧实色细线 + 墨色文字**；配色换成更干净的朱砂、石青、石绿、藤黄、胭脂、靛蓝、赭石、黛青。测试约束：墨色字对浅底 ≥ 7:1，色线对纸面 ≥ 3:1，两种纸面都覆盖。
- 宣传页：源码 `site/index.html`（与 App 同一套墨晕白纸风格），部署在 **studydazi.top 首页**：放在 study-dazi 仓库 `public/timer/index.html`，`next.config` 里把 `/` rewrite 到它，学习搭子其余页面（如 /login）照常；删掉这条 rewrite 即恢复学习搭子首页。Vercel 部署成功，线上已核对。
- 已发布 **1.1.0+6**：电脑客户端与后台已更新（`/health` 报告 1.1.0+6），桌面快捷方式为「瞬时」，手机包已发布并复制到桌面 `瞬时-手机版.apk`。

## 1.1 第二轮（Claude，2026-10-20）：助手直接执行，专注与周视图收尾

在 Codex 1.1.0+4 源码的基础上逐条复核七项要求，并修复/补全：

| 要求 | 本轮结果 |
|---|---|
| 1 首页以此刻为主体 | 复核手机尺寸：时钟为主体，日期条标「今天」与选中日；未改动 |
| 2 手机整周一眼可见、有艺术感 | 接上 Codex 未完成的「淡彩记事」：每件待办一种矿物色（青黛、赭石、藕紫…），墨晕形色块＋简称，长按看全名；浅色色值加深并修复对比度测试，底色加匀便于区分 |
| 3 助手笨、不干活 | 重写身份与性格提示；改为**直接执行＋一键撤销**（可在设置改回先确认）；新增撤下单段、整件不做、改期改时长；能把用户说出的习惯记成可删除的长期记忆；改动失败时不再谎称已办 |
| 4 开始后没有反馈 | 开始时整屏「入定」墨晕过场（任务名＋预计收尾，约 2 秒，可点掉）＋震动；专注卡换成随秒呼吸的墨环倒计时，笔触随时间走满 |
| 5 公众号主动推送 | 复核 Codex 的模板；到点追问改为「完成了 / 再给我15分钟 / 直接说推迟」，单段时不带编号；微信里助手改动不再重复推回执；微信支持「撤销」 |
| 6 文件＋文字复盘 | 复核已实现；回顾页按「添加材料 → 写两三句 → 生成 AI 复盘 / 只保存原文」重排 |
| 7 手机通知 | 复核已实现（开始、结束、10 分钟后追问、等待检查、日终）；需安装新版 APK 后在 OPPO 上开启通知权限实测 |

- 另修：吃饭等没有待办的保护时段此前在 App 和助手里都无法删除，现可「删除这一段」；助手改期保护时段此前必然失败。
- 验证：后台 **107 passed**；Flutter **67 passed**；analyze **No issues found**；网页版 375×812 预览实看首页、周视图、专注与回顾页（数据只在预览浏览器本地）。真实模型在隔离临时库实测通过，见 [助手机制](design/assistant-behavior.md)。
- 已发布 **1.1.0+5**（2026-10-20，`tools/release.ps1`）：电脑客户端已安装，后台 `/health` 报告 1.1.0+5，arm64 APK（97,042,963 字节）已发布到数据目录 releases 并复制到桌面 `Timer-手机版.apk`；外网未带凭证访问 API 为 401。
- 仍待实测：OPPO 安装与通知权限、正式公众号主动消息实收、助手在公众号里的直接执行与「撤销」。

## 1.1.0+3 更新：已完成源码与隔离验证，待正式激活

| 用户问题 | 本轮结果 |
|---|---|
| 首页杂、日期占地大 | 时钟成为主体；日期条压缩，今天与选中日分别标识；睡眠入口收窄 |
| 手机一周看不全 | 默认整周忙闲总览，七列与时间轴适配视口；选日看明细，可切回详细课表 |
| 助手啰嗦、现在被判过去 | 直接执行型身份；显式 now、截止上限、生成预检与确认校验；任务/执行版本和拟办 15 分钟时效 |
| 开始没有反馈 | 独立专注面板、倒计时、预计收尾、暂停/续时/结束；短反馈与手机触感 |
| 公众号需主动推送 | 后台新增事件与到点调度，复用持久 outbox；创建、专注、结果追问、检查点、日终和复盘完成模板 |
| 材料 + 原文总结 | 手动选文件上传、外发选项、提取与来源、AI 复盘、自动日终作业、电脑归档；回忆卡片仍待实现 |
| 手机通知不明显 | 首页启用入口、权限/准时提醒状态、15 秒后系统测试；OPPO 实机仍待验收 |
| 所有任务入口编辑/删除 | 卡片、详情、诸事与挂件提供操作；删除撤下未来安排和提醒，保留实际历史；编辑同步未结束安排标题 |
| 过去/当前/未来处理 | 已写入助手与领域规则并增加回归测试，完整矩阵见下方设计文档 |

- 行为、记忆分层、时间边界与消息模板见 [助手机制](design/assistant-behavior.md)。长期偏好由用户明确保存/删除；近期回顾、材料摘要和 AI 分析作为有界资料读取，不等同于全文检索或自动画像。
- 本轮验证：后台 **92 passed**；Flutter **59 passed**；analyze **No issues found**。Windows 原生隔离后台闭环 **1 passed**，含创建、专注、续时/顺延/撤销、等待改约、材料上传与复盘、删除；模型与微信均使用测试替身。手机尺寸截图已检查，见本地 `artifacts/v4-native-qa/`。
- 新依赖：file_picker 13.1.0（锁文件已更新）、pypdf 6.21.1、python-docx 1.2.0；共用 SDK 与缓存不变。原生构建使用既有脚本。
- 正在使用的后台核查仍为 **1.0.0+2**。Codex 进程的 AppData 被映射到包缓存；该目录的凭证无法认证当前后台，故没有用它替换生产数据、发布 APK 或重启正式服务。
- 安装将使用 `tools/release.ps1 -Prepared`，从普通终端校验并激活准备包，保留正式配对与数据。正式推送、真实模型在新提示下的效果、OPPO 通知与安装仍需要激活后的真实验收。
- 构建完成：Windows release 与三种 ABI 的 Android debug 均成功。准备包为 `artifacts/Timer-1.1.0+3-Windows.zip`、`artifacts/Timer-1.1.0+3-arm64-debug.apk`；arm64 包 97,017,599 字节，签名证书与桌面原有手机安装包相同；APK 编译清单包含通知、重启和准时提醒权限。
- `artifacts/prepared-release.json` 保存客户端逐文件与 APK 校验和；`tools/release.ps1 -Prepared -ValidateOnly` 实测通过，不改安装或数据。发布与安装脚本在 Windows PowerShell 解析通过。正式激活仍待用户在普通终端执行 `tools/release.ps1 -Prepared`，版本尚未上线，不能提前记为交付完成。
- 本轮日志：`artifacts/v4-backend-tests.log`、`v4-flutter-tests.log`、`v4-analyze.log`、`v4-native-test.log`、`v4-windows-build.log`、`v4-android-build.log`。

## 2026-10-21：QQ 接管聊天入口 + 「像朋友」的助手

- **QQ 官方机器人通道已端到端跑通**（真实 AppID `1905884176`，绑定真实 QQ）：WebSocket 收消息、被动回复（带 `msg_id`/`msg_seq`）、主动提醒（用户关掉主动开关前有效）、6 位绑定码用完即焚、发送队列六态与 `unknown` 不重发都对着实测验过。微信通道代码保留，`RoutedChannel` 优先走 QQ。
- **表情包能发了**：模型只填类别（开心/夸你/累了…十类），实际选图在 `server/app/memes.py`，素材在 `server/assets/memes/<类别>/`（22 张）。QQ 侧走 `/v2/users/{openid}/files` 上传再 `msg_type=7`，文字在前图在后；素材缺失时整段静默，聊天不会因为缺图失败。
- **助手语气改版**：删掉原来训人的说法（「不用假嗨/别汇报」）；改成熟人搭子，要求「夸要夸具体的事」；历史消息带 `[时:分]`、只带最近 45 分钟，不再把上午的事当刚发生；`meme` 字段可选。设计说明与可调旋钮见 `design/assistant-voice.md`。
- **弹性时间选项**：续时可以是 5–120 分钟任意值（之前只有 15/30）；已过点没开始的段可以「挪到之后」（今晚/明晚/明早/自己选，原时长不变）；一段结束后接着问「接下来做点什么」（立刻开始下一段／休息 10 分钟／先这样）；剩余时长改为 5–240 分钟滚轮；补上 `block.move` 的离线乐观实现。
- 验证：后台 `154 passed`（原 119 + QQ 27 + 表情包 8）；Flutter `analyze` 无问题、`test` 77 项全过。这两批改动分别提交在 `6b2ae3b`、`55b0f7c`。
- **已知问题（用户 2026-10-21 拍板：不改）**：app 设置里的时区是 `Asia/Shanghai`，而这台电脑是 `Pacific`。日程与「现在是几点」都按 `Asia/Shanghai` 算，所以助手会说「现在 12:54」而实际是 21:54——这也是「明晚其实是今晚」的根子。改时区会影响已排安排，用户决定就用上海时区，保持现状。
- 还没做：一段结束/过点后「按你的总结夸一句或问一句」的反应消息（用户后续说先不管）、群聊。

## 1.1.1+9 发版（2026-10-21）

- 内容：QQ 机器人聊天入口（可发 22 张表情包）、「像朋友」的助手语气与 `[时:分]` 历史时间轴、弹性时间菜单（续时 5–120 任意分钟、已过点「挪到之后」、结束后「接下来做点什么」、剩余时长 5–240）。设置页文案不再写「微信助手」：QQ 面板改叫「聊天助手（QQ）」，微信面板收成「微信（旧通道）」。
- 构建：`tools/release.ps1` 把 `apps/planner/pubspec.yaml` 抬到 `1.1.1+9`，Windows release 与三种 ABI 的 Android debug 均成功，电脑客户端已安装（`time_planner.exe` 文件版本 `1.1.1+9`），APK 实测 `versionName 1.1.1`、`versionCode 2009`（旧包 2008，可覆盖升级）。
- **踩到的坑**：`m.releases publish` 在发布最后一步被「按可执行文件路径限制写盘」的托管沙箱挡住——同一时刻 PowerShell 能往 `%USERPROFILE%\TimePlanner\data\releases` 拷 97 MB，`python.exe` 却 `PermissionError: [Errno 13]`；交给计划任务跑也一样（受管进程树受限）。最终用 PowerShell 完成发布（复制 APK → `Get-FileHash` 算 SHA-256 → 按 `releases.py` 的字段写 `latest.json`），版本号按失败回滚逻辑手动补回 pubspec，避免源码与已发版不一致。
- 结果：`%USERPROFILE%\TimePlanner\data\releases\timer-1.1.1-9.apk`（97,076,567 字节，SHA-256 `d30fd204…5733`），`latest.json` 指向 `1.1.1+9`；后台重启后 `/health` 返回 `{"version":"1.1.1+9","app_latest":"1.1.1+9"}`，带凭证 `GET /api/v1/app/latest` 与 `/api/v1/app/download`（Range 请求实测 206、`X-Timer-Version: 1.1.1+9`）均正常。
- 手机侧：打开 App 检查更新即可看到 1.1.1 的下载提示；若提示「无法安装」，需确认仍是同一调试签名覆盖安装。

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

## 微信助手：公众号测试号

- 当前采用用户在 W1 后确认的公众号测试号方案，手机大号关注并对话。此前小号 UIA/OCR 调研保留在 `design/wechat-personal-channel.md` 作为路线变更记录，不是当前接入方式。
- Claude 已实现签名回调、账号绑定、入站去重、助手对话与拟办、持久 outbox、设置页；绑定回执曾真实送达。官方 DeepSeek 和 Cloudflare 隧道已有前阶段真实连接证据；操作步骤见 `guides/wechat-test-account.md`。
- 1.1.0+3 源码增加主动消息、到点问询、明确回复的执行操作、偏好记忆及日终复盘。尚未据此宣称正式微信投递通过；激活与真机结果见本文最新记录。
- 后台与隧道的登录自启已配置，见本文最新记录；更完整的恢复验收（真实重启后自动恢复）继续待做。已实现的模板与已验证的实际投递要分开记录。

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
- 日终复盘与知识回忆设计见 `docs/design/daily-review.md`；材料/原文复盘第一阶段已实现，回忆卡片与间隔复习仍待实现。
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

此表为早期阶段记录；模型与隧道后续已由 Claude 接通。新版提示效果、正式主动消息、OPPO 通知/安装及其他实机场景仍按本文最新记录验收。

## 工具链入口

- Flutter、Android、ATL 和 Pub 缓存均从 `%USERPROFILE%/DevTools/Timer` 选取；版本和 revision 由 `tools/toolchain.json` 固定。
- 每次切换工具先运行 `tools/setup-dev.ps1`；仅在迁移或确认生成路径过期时加 `-Clean`。详细说明与命令见 `development-environment.md`。
- 最早的环境缺失记录及旧 AppData 路径保留在 Git 历史中，不再作为当前安装或构建指令。

## 下一步

以下功能仍需继续实现或验收：

1. 激活并实测本轮更新；在材料/原文复盘第一阶段之上继续回忆卡片与间隔复习。
2. 使用已配置的服务检查新版自然语言场景与复盘效果，不重置已有模型配置或账号绑定。
3. OPPO 真机：安装 APK、通知权限、ColorOS 后台；跨网络连接（Cloudflare Tunnel，需用户操作域名与账号）。
4. 统一问询队列与自然语言反馈、已有块的表单/拖动改期、托盘常驻及备份恢复。开机自启已配置，见本文最新记录。续时、迟到模式、检查点改约和一级微调已实现，见本文最新记录。
