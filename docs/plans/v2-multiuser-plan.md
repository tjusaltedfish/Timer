# 瞬时 v2：多用户托管版实现方案

- 状态：**待拍板**（未改任何代码）
- 日期：2026-10-22
- 修订（2026-10-22，用户拍板 `m00671`）：**服务就装在你自己的电脑**（zx 即开发者本人）；**公众号为主通道**，QQ 只留给你个人/后续可选；**DeepSeek 每人自带 key**，不带站长的；**新用户助手默认直接执行**（保留一键撤销，可切回先确认）。
- 修订（2026-10-22，用户拍板 `m00616`）：**整体调轻**——面向 2–4 个熟人、不做威胁模型/审计/邀请码等防御性设计；部署位置二选一（自己的电脑或 zx 的电脑），运维从「搭一套托管平台」降为「一台常开电脑 + 备份」。
- 修订（2026-10-22，用户拍板 `m00541`）：托管形态从「云 VPS」改为**家里电脑常开 + Tailscale 尾网**，数据库从 Postgres 改为**本机 SQLite（WAL）**；本文以下已按此改，云方案只作为备选保留。
- 基线：`main@029c0e2`（后端 pytest 171 passed / Flutter test 77 passed / analyze 干净）
- 对应需求：把「只在我电脑上跑的个人助手」改成「师弟也能用的、手机优先、电脑可同步查看」的托管版，同时修掉审查发现的缺陷。

---

## 0. 一页结论

| 问题 | 推荐做法 |
| --- | --- |
| 要不要用户登录？ | **要**（多设备同步必需）。用户名密码登录 + 设备长期令牌；账号由站长 CLI 开通，没有注册页/邀请码；不做手机号验证码 |
| 真正的后端/数据库 | **本机 SQLite（WAL）+ 家里电脑常开**；每用户一行 `user_state.body` 文档（沿用现有 domain 引擎）+ 规范化认证/设备/操作日志/事件/发件箱/密钥表。不引入 Docker、Postgres |
| 手机、电脑都要开吗？ | **都不用**。手机是主客户端，电脑是同机/第二客户端；外网设备通过 **Cloudflare Tunnel 子域**访问（Tailscale 仅作内网直连备选） |
| 服务装在哪台电脑 | **你自己的电脑**（zx 本人就是开发者，机器本来常开）；以后要搬家 = 恢复备份 + 客户端改地址（§15.1） |
| 外网入口 | **Cloudflare Tunnel 子域必须开**（公众号回调要求公网 HTTPS，客户端也走它）；Tailscale 只作内网直连备选 |
| 多用户怎么隔离 | 请求上下文强制 `user_id`；仓储层不接受无主查询；文件、通道身份、助手记忆/密钥/人设按用户分域；抽查两账号交叉 404 就够 |
| 通道 | **微信公众号为主**（一个号服务所有人，openid→用户绑定）；QQ 只保留给你个人使用，不做多租户 |
| DeepSeek key | **每人自带 key**、加密入库、只回显尾号；站长不提供共享 key，只给每人设每日调用上限防刷 |
| 新用户引导 | 服务端记录进度的 10 步高亮教程（可跳过、可重看、换设备续上），其中包含 DeepSeek 配置测试、公众号绑定（QQ 可选）、人格卡选择、第一个任务 |
| 手机周视图 | 从「7 列小地图 + 详细课表」双模式改为「周条 + 周热图 + 选中日议程」三层结构，点击目标 ≥44dp，空闲/负荷统计常驻 |
| 助手更智能 | 意图路由（确定性快路 + LLM 工具调用）+ 上下文接地 + 反问澄清 + 实体指代 + 记忆检索 + 人格卡；新用户默认**直接执行**（一键撤销、可在设置里切回先确认） |
| 周期 | 约 **3–3.5 周**（业余、AI 辅助；省掉云环境搭建与防御性工程，公众号回调配置略增），分 5 个阶段，每阶段可独立验收 |
| 成本 | **托管 ¥0**（电脑本来常开、域名已有）；B2 备份可选 ¥10/月；DeepSeek 按人自付 |

---

## 1. 需求映射

| 用户需求 | 方案章节 |
| --- | --- |
| 1. 真后端/数据库、通用化、手机为主、电脑同步、是否要登录 | §2 现状差距、§3 目标架构、§4 D1/D2、§5 数据模型、§6 认证 |
| 2. 首次进入逐步高亮教程，含 DeepSeek API、公众号绑定；QQ 可暂不绑（只给你个人） | §9 新手引导、§8 通道 |
| 3. 多用户怎么用、怎么隔离 | §7 多租户隔离 |
| 4. 一个公众号一对多，每用户独立配对码，消息/记忆不串台 | §8 通道（含绑定时序） |
| 5. 用户可自设助手人格卡或默认 | §9.5 人格卡 |
| 6. 交互与意图识别更智能 | §9 助手 2.0（含评测集） |
| 7. 手机每周时间段展示优化 | §10 手机周视图 |
| 顺带修 bug | §11 缺陷清单并入排期 |

> 注意：`docs/HANDOFF.md` §0 的「铁律」里有三条会被本方案取代——「纯自用/不做多用户登录」「AI 只拟办不自动改」「API key 只存本机」。§12 会同步改写这三条及 STATUS。

---

## 2. 现状与差距（为什么不能只加一个登录框）

现在的系统其实已经是一个真实后端（FastAPI + SQLite），但每个设计点都绑死在「唯一用户 + 我的电脑」上：

| 现状 | 位置 | 多用户下的问题 |
| --- | --- | --- |
| 单行 `document` 存整份状态 | `server/app/store.py:59-72`、`initial_state()` | 一个库只能有一个用户；所有查询没有 user 维度 |
| 设备令牌由桌面启动器写入 `desktop-token` 文件后换取 | `store.py` 设备引导；`tools/Start-Timer.ps1` | 新用户没有「注册」入口；令牌即身份，无法按人吊销 |
| 数据目录固定 `%USERPROFILE%\TimePlanner` | `store.py` 初始化 | 只能一台机、一个人 |
| 后台任务跑在 API 进程里（5s/60s/3s 循环） | `server/app/main.py:36-80` | 进程一重启全断；无法水平扩展；多进程会重复触发 |
| 对外只靠临时 `cloudflared` 隧道 + watchdog，且只服务一个人 | `docs/STATUS.md:52-62`、`tools/tunnel-watchdog.ps1` | 电脑常开本身不是问题（用户已决定不关机）；缺的是身份、设备管理和按用户隔离，不是「换个地方托管」 |
| QQ/微信通道绑定是单例 | `server/app/qq.py`、`wechat.py`、`store.py` 中 bind 表 | 只能记一个 openid；换人即串台 |
| 助手设定/记忆/人格写死在提示词与 `assistant_messages` | `server/app/assistant.py`、`assistant_service.py` | 「主人/大肥鱼」是作者个人口味，无法给师弟换人格 |
| 版本与 APK 由本机静态目录提供 | `server/app/releases.py`、`main.py` `/app/download` | 可以复用；HTTPS 由尾网/隧道提供，签名与 keystore 管理不变 |
| 个人常量散落 | 默认时区 `America/Los_Angeles`（`store.py:28`）、`desktop-token`、个人表情库 | 通用版要改成「首次登录由设备时区初始化 + 用户可改」 |

另外，上一轮审查已确认的一批缺陷（P0/P1 见 §11）必须在改造期间一起修，否则多用户会把单机 bug 放大成「数据串台/数据丢失」。

---

## 3. 目标架构

```
   ┌───────────────┐   ┌────────────────┐        ┌────────────────────┐
   │ Android 手机   │   │ Windows 桌面    │        │ 公众号（主通道）     │
   │ (主客户端)     │   │ (同机/第二端)   │        │ QQ（私人/后续可选）  │
   └───────┬───────┘   └───────┬────────┘        └────┬──────────┬────┘
           │ 公网 HTTPS（Tunnel）或 Tailscale          │ 微信回调  │ 出站长连接
           ▼                   ▼                       ▼          ▲
        ┌──────────────────────────────────────────────────────────┐
        │            你的电脑（zx 的开发机，不关机，常驻服务）        │
        │  cloudflared(TLS) ── uvicorn api(FastAPI，单进程)          │
        │        │ 同进程后台循环：超时结算/提醒/周报/归档            │
        │        │                                                  │
        │   SQLite（WAL，单文件）                                    │
        │   users / devices / user_state(body JSON) /                │
        │   operations_log / events / outbox / jobs /                │
        │   channel_identities / channel_bind_codes / app_config /   │
        │   assistant_configs / assistant_messages /                 │
        │   assistant_drafts / assistant_memories /                  │
        │   materials / schema_version                               │
        │   文件：%USERPROFILE%\TimePlanner\users\<uuid>\materials…   │
        └──────────────────────────────────────────────────────────┘
                    │ 每日 sqlite .backup + robocopy
                    ▼
        第二块硬盘 / OneDrive / B2（可选）+ 每月恢复演练
```

关键点：

- **手机与电脑都只是客户端**，服务器就是这台不关机的家用电脑；任一客户端离线不影响另一个，也不影响后台（按时段提醒、超时结算、周报）。
- **单进程足够**：3 个用户、SQLite 单写者，一个 uvicorn 进程 + 同进程后台循环；重启后靠 `jobs`/`outbox`/事件游标续跑，不需要 worker 容器、Redis、Docker。
- **服务就跑在你自己的电脑**（zx 本人开发机，不关机）；手机/电脑只是客户端，谁开着都不影响另一个。
- 数据同步：保留现有 `/operations`（幂等、按设备）+ `/snapshot`，增加 `ETag`/`gzip` 和 `/sync?since=revision` 轻量增量提示；客户端仍只渲染服务端状态（业务逻辑继续只写在 `domain.py`，客户端不做第二套规则）。
- **公网入口必须开**：公众号回调要求公网 HTTPS → Cloudflare Tunnel 子域（`tools/tunnel-watchdog.ps1` 已有）；客户端也走同一地址；Tailscale 仅作不想走公网时的直连备选。除微信回调（带签名/AES 校验）外，所有接口仍要密码/设备令牌/绑定码。
- **公众号的硬限制绕不过**：被动回复 5 秒、客服消息 48 小时窗口、个人订阅号不能异步推送（§8.3）——按账号类型降级，不硬做。
- 通道与助手都通过「用户上下文」工作：IM 消息先解析 `channel + external_id` → 用户，再走同一个助手管线。

---

## 4. 关键决策（推荐 + 备选）

### D1 登录形式：用户名密码 + 设备令牌（账号由站长开通）

- 开通：站长在本机执行 `python -m app.admin user add --name 师弟` 建账号并给初始密码。就 2–4 个熟人，不做注册接口/邀请码，微信上说一声即可。
- 登录：用户名 + 密码 → 返回长期设备令牌（30–90 天滚动，可随时在 App 里吊销）。手机第一次登录后不再输密码；桌面同理。
- **不做**手机号验证码（要短信服务商、要费用、要实名/合规）；**不做**微信扫码登录（公众号未认证时拿不到稳定网页授权，且师弟不一定愿意授权）。后续可加 passkey/邮箱找回。
- 桌面端不再依赖 `desktop-token` 文件引导；保留 `local` 模式仅用于开发与应急（`PLANNER_AUTH=local`）。

**为什么不是「免登录、只靠配对码」**：订阅式 IM 绑定可以作为第二身份，但 App 本身必须有账号——否则换手机、清数据、多设备同步、助手记忆归属都无解。

### D2 数据库：SQLite（WAL），每用户一行 JSON 状态 + 规范化周边表

- 3 个用户、单台电脑、单进程写：SQLite 足够且最省心——数据库就是一个文件，备份=复制，不需要 Docker/WSL2、不需要调 Postgres 参数、也不用为 3 个人维护一个数据库服务。WAL 下多读单写，写事务 `BEGIN IMMEDIATE` 排队（现有 `busy_timeout=15s` 保留），3 人峰值远低于瓶颈。
- 继续复用 `domain.py / planning.py / adjustments.py`（纯字符串状态机，171 个测试保护），只把 `store.py` 换成 `repo.py`：`state_for(conn, user_id)` 读写 `user_state.body`（TEXT 存 JSON，用 SQLite 的 `json_*` 函数做少量查询）。
- 认证、设备、操作日志、事件、发件箱、任务队列、通道身份、助手配置、记忆、素材**全部规范化成表**（这些需要索引、按人查询、并发安全）。
- 迁移用轻量版本化（`schema_version` 表 + 有序 SQL 脚本），不引入 Alembic——测试与生产同一个引擎，避免两套行为分叉。
- **不做**全表化（tasks/blocks 每行一条）：改造量是 2–4 周且高风险，3 人规模收益为负；先用「JSON + 定期归档」把单文档控制在 1 MB 内（§5.5），真要跨机多写再迁 Postgres（迁移面已隔离在 `repo.py`）。

### D3 进程形态：单进程 uvicorn + 同进程后台循环

- 一个 `uvicorn` 进程服务 FastAPI；`main.py` 现有三个循环（5s 超时结算、3s 通道/主动提醒、60s 素材/周报）保留，加一次 SQLite 写冲突重试即可。
- 单实例：SQLite 单写者，本机没有多进程争抢问题，省掉 jobs 抢占、重复触发的复杂度；进程崩溃由计划任务/`Start-Timer.ps1` 拉起，`jobs` 表保证重启后把没做完的活续上。
- 以后真要上多进程（用户涨到 10+ 或要独立升级 API），再按 §5.1 的 `jobs` 表拆出 `worker.py` 子进程；表结构已预留，不用重构。
- 不引入 Redis/Celery/Docker：3 个人一个进程就是最优解，少一个组件少一处故障。

### D4 通道：微信公众号为主，QQ 保留为私人/后续通道

- 公众号：**一个公众号服务所有用户**；微信服务器配置 URL → Cloudflare Tunnel 子域，GET 校验 + POST 加密 XML（AES 解密）；`openid` → `channel_identities` → 用户。
- **账号类型决定能不能做（必须先确认）**：
  - 个人订阅号：只能「收到消息后 5 秒内被动回复一次」，**不能异步发消息、没有模板消息**；助手回答超过 5 秒就发不出去。
  - 认证服务号（个体工商户/企业主体，每年约 ¥300 认证）：可发 48 小时客服消息 + 模板消息，能做异步回答和提醒。
  - 公众号回调使用的域名一般要求 **ICP 备案**；开发期可先用微信「测试号」（无备案要求、免认证）验证回调链路。
- 设计按「快慢两条路」：
  - 确定性命令（绑定、完成、撤销、今天、总结、早开始）→ 5 秒内被动回复，订阅号也能用；
  - LLM 长回答/异步任务 → 服务号走客服消息；只有订阅号时，回复「这个要一会儿，去 App 里看完整回答」并把结果写进 App 对话（不假装能推）。
- 提醒：App 本地通知为主；公众号侧只在「48 小时窗口内」补发（服务号），个人订阅号不做主动提醒。
- QQ：现有机器人代码保留，**只服务你本人**（AppID 是你个人的），不做多租户；以后想让别人用再放开，绑定/发件箱与公众号共用同一套表。
- 引导里默认只推公众号；QQ 放在「高级/可选」。

### D5 DeepSeek：每人自带 key（站长不提供共享 key）

- `assistant_configs.api_key` 用 `MASTER_KEY`（Fernet）加密存 DB，接口只返回 `sk-…abcd`；解密只在调用瞬间发生，不写日志。
- 每个用户（含你自己）在引导第 5 步填自己的 key，带「测试连接」；**不提供「用站长的 key」**。
- 每人每日调用上限默认 100 次（防 key 被刷/误循环），可在管理 CLI 调；不做 token 计费/额度审计。
- 原「key 只存本机」的铁律作废（现在 key 就在你自己的机器上，但仍加密、只本人可读写、永不回显、不进日志）。

### D6 托管形态：装在你自己的电脑 + Cloudflare Tunnel（Tailscale 备用）

- 你的电脑就是服务器（你是开发者本人、机器常开）：不需要云 VPS、不需要域名备案以外的额外条件；Windows 计划任务 + 现有 `tools/Start-Timer.ps1`（含基础解释器兜底）负责自启与恢复。
- 公网入口：**Cloudflare Tunnel**（`cloudflared` + `tools/tunnel-watchdog.ps1` 已有）→ `https://timer.<你的域名>`；公众号回调、手机、桌面都走这个地址。**必须开，因为公众号回调只能公网访问**。
- 备用入口：Tailscale 内网直连（不想把客户端流量走公网时用）；QQ 机器人为出站长连接，不需要公网入口。
- 域名/证书：Cloudflare 管 TLS；公众号正式上线要求域名 **ICP 备案**（开发期用微信测试号绕过）。
- 开发/生产隔离：服务固定端口 8765 + 独立数据目录；测试一律 `PLANNER_DATA_DIR` 指向临时目录；开发时用「测试号 + 本地隧道」双开不冲突。
- 成本：托管 ¥0（电脑本来常开 + 已有域名）；B2 备份可选 ¥10/月；DeepSeek 每人自付。

### D7 客户端：手机优先，桌面精简为「查看 + 编辑」同构页面

- 同一套 Flutter 代码，Android 为主；Windows 保留现有宽屏布局，桌面端可直接连本机 `http://127.0.0.1:8765`，手机连 Tunnel 域名（或 Tailscale 地址）。
- 手机承担：登录、引导、通知、周视图、随手记录、助手对话；桌面承担：大屏周课表、批量整理、配置与备份导出。
- 服务地址在登录页可配置（本机地址 / Tunnel 域名 / Tailscale 地址），保存在设备上；换服务器或加设备不用重装 App。
- 更新：服务器托管 APK + `/api/v1/app/latest`（`releases.py` 已有），签名密钥离线保管。

### D8 数据与运维：一份 SQLite + 一个文件目录，靠备份保命

- 数据全在 `%USERPROFILE%\TimePlanner\data`：`planner.db`（WAL）、`secrets/`（Fernet master key、QQ/微信凭证）、`users/<uuid>/`（素材、表情包）、`assistant.json` 等；全部不进 Git（已有规矩）。
- 每日 03:00 计划任务：`sqlite3 planner.db ".backup"` 出在线一致快照 → `robocopy /MIR` 到第二块硬盘；可选 rclone 加密到 Backblaze B2。保留 14 日 + 8 周。
- `tools/host/restore.ps1` 一键恢复（停服务 → 还原 db/文件 → 起服务 → 校验 `/snapshot`）；**每月做一次恢复演练**并记录结果。
- 供电与自启：小 UPS（防瞬时断电）、BIOS 设「来电自启」、Windows 更新只允许在深夜并自动重启后拉起服务。
- 监控：`/healthz`（含 DB 可写检查）由本机 watchdog + 手机尾网探活；异常（连续失败/磁盘 <20%/备份失败/LLM 错误率 >20%）通过公众号/App 通知给你自己。

---

## 5. 数据模型

### 5.1 表清单（`server/app/migrations/`，轻量版本化；`schema_version` 记已应用版本）

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `users` | id TEXT(uuid), username TEXT COLLATE NOCASE unique, password_hash(Argon2id), display_name, role(admin/member), status, onboarding TEXT(JSON), timezone, created_at, last_login_at | 通用化核心 |
| `devices` | id TEXT(uuid), user_id, name, platform, token_hash, created_at, last_seen_at, revoked_at | 令牌只存 sha256 |
| `user_state` | user_id PK, body TEXT(JSON), revision INTEGER, size_bytes, updated_at | 业务状态（沿用现有 dict 结构） |
| `operations_log` | user_id, operation_id, device_id, request_hash, response TEXT(JSON), created_at, PK(user_id, operation_id) | 幂等重放，按人隔离 |
| `events` | user_id, revision, kind, payload TEXT(JSON), recorded_at, PK(user_id, revision) | 客户端拉取/通道通知 |
| `channel_identities` | id, channel(qq/wechat), external_id, user_id, display_name, bound_at, last_seen_at, unique(channel, external_id) | 一个 IM 账号映射一个用户 |
| `channel_bind_codes` | code_hash, user_id, channel, expires_at, used_at, attempts | 6 位数字/一次性/10 分钟 |
| `app_config` | key TEXT PK, value_cipher TEXT, updated_at | 站长级凭据：公众号 AppID/Secret/Token、QQ 凭据；Fernet 加密 |
| `outbox` | id, user_id, channel, kind, payload TEXT(JSON), status(pending/sending/sent/failed/dead/window_closed), attempts, next_at, msg_seq, error | 每用户发件箱（微信 48h 窗口、QQ 配额都靠它） |
| `jobs` | id, kind, user_id null, run_at, status, payload TEXT(JSON), attempts, last_error, unique(kind, key) | 后台任务（超时结算/复盘/归档/备份），重启后续跑 |
| `assistant_configs` | user_id PK, base_url, model, api_key_cipher, key_hint, daily_limit, confirm_first, persona_id, persona TEXT(JSON), updated_at | 含人格卡 |
| `assistant_messages` | user_id, role, text, image_path, status, created_at | 保留 90 天 |
| `assistant_drafts` | id, user_id, message_id, operations TEXT(JSON), status(pending/applied/dismissed/undone), expires_at, undolog TEXT(JSON) | 15 分钟过期 |
| `assistant_memories` | id, user_id, kind, text, tags TEXT(JSON), source_msg_id, created_at, last_used_at, pinned | 上限 200 条/人 |
| `assistant_usage` | user_id, day, calls, tokens, PK(user_id, day) | 每日限额 |
| `assistant_pending_questions` | id, user_id, question, options TEXT(JSON), expires_at | 澄清式追问 |
| `materials` | id, user_id, name, path, bytes, created_at | 文件落在 `users/<uuid>/materials/` |
| `app_releases` | version, platform, url, sha256, notes, created_at | APK 分发 |
| `schema_version` | version INTEGER, applied_at | 迁移版本，启动时先跑未应用的脚本 |

### 5.2 `user_state.body` 结构

沿用现有 `initial_state()`（projects/sleeps/tasks/blocks/sessions/feedbacks/waiting_checks/reviews/proposals/settings/memories 等），只做三处调整：

1. `settings` 里去掉个人默认时区，改为注册时用设备时区初始化，`timezone` 进 `users` 便于查询；
2. `memories` 仅保留「助手记忆」的轻量副本或直接迁到 `assistant_memories`（二选一，推荐后者，方便分页/删除）；
3. 新增 `state_version`（结构版本号，便于以后加字段），`body` 内不存任何密钥。

### 5.3 每用户状态读写

```
repo.read(conn, user_id) -> (state, revision)      # SELECT body FROM user_state WHERE user_id=?
repo.write(conn, user_id, state, expected_rev)     # UPDATE ... WHERE user_id=? AND revision=?（乐观锁）
repo.apply_operation(conn, user_id, device_id, op) # 事务内（BEGIN IMMEDIATE）：校验幂等 → domain.apply → revision+1 → 写 events/operations_log → 归档触发
```

并发：WAL 下多读单写，写事务用 `BEGIN IMMEDIATE` 排队（`busy_timeout=15s` 已配）；同一用户的写串行，不同用户只排队不丢。3 人规模下这就是最简单可靠的方案。客户端并发提交时，`expected_rev` 冲突返回 `REVISION_CONFLICT`，客户端重拉快照（现有行为，保留）。

### 5.4 迁移与初始化

- `tools/migrate-v1-to-v2.py`（**在本机跑**，先复制一份旧 DB 再操作，原库只读）：
  1. 创建 owner 用户（用户名/密码来自交互或环境变量）；
  2. 原样导入 `document.body` 为 `user_state`（revision 保留），`operations`/`events` 补 `user_id` 后导入；
  3. `devices`：把旧 `token_hash` 原样迁入，手机无需重新登录即可连新地址；
  4. 复制 `materials/`、`memes/` 到 `users/<id>/`，路径改相对；
  5. 旧 QQ/微信绑定 → `channel_identities`；旧 `wechat.json`/`qq.json`/`assistant.json` 的模型与 key → `assistant_configs`（加密）；
  6. 校验脚本：逐字段 diff 旧快照 vs 新快照（除时间戳/版本号），数量对不上就中止。
- 切换：新 schema 在同机新端口/新数据目录并行跑 2 周只读观察 → 手机改「服务地址」→ 旧库与旧隧道保留 30 天回滚 → 下线旧入口。

### 5.5 状态瘦身（避免整份 JSON 越滚越大）

- 每次写操作后触发 `compact()`（在事务内，纯内存裁剪）：
  - tasks/blocks：保留「未完成 + 最近 180 天完成」；
  - sessions/feedbacks：保留 180 天，更老的汇总进 `history_years`；
  - reviews：保留最近 60 篇，更老进 `archive_documents`；
  - proposals：只留最近 20 条 + 未过期草稿；`events` 表按 90 天清理（通道通知游标另存）。
- 监控 `size_bytes`，>2 MB 告警；`/snapshot` 加 `ETag`（revision）+ `Content-Encoding: gzip`。

---

## 6. 认证、账号与设备

### 6.1 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/v1/auth/login` | {username, password, device:{name,platform}} → token + user（账号由站长 CLI 开通，**没有注册接口**） |
| POST | `/api/v1/auth/logout` | 吊销当前设备 |
| GET | `/api/v1/me` | 用户信息 + onboarding 进度 |
| PATCH | `/api/v1/me` | 显示名、时区、onboarding 进度 |
| POST | `/api/v1/me/password` | 改密码（吊销其他设备） |
| GET/DELETE | `/api/v1/me/devices` | 设备列表 / 吊销 |
| ADMIN | `python -m app.admin user add --name 师弟` | 站长在本机开账号/重置密码/禁用；不做邀请码、不做注册页 |

### 6.2 安全基线（只留基本盘）

- 密码：Argon2id，10 位起；登录失败做简单限流就行（不搞分级锁定策略）。
- 令牌：32 字节随机，DB 只存 sha256；App 内可一键吊销本设备。
- 传输：只走 HTTPS（Cloudflare 自动证书）；明文 HTTP 只绑 `127.0.0.1`。
- 日志：不打密码/token/API key/消息正文；不做审计日志。
- 限额：LLM 每人每日调用上限，防止 key 被刷；上传单文件 20 MB。

### 6.3 客户端

- 登录页：服务地址（内置默认 `http://127.0.0.1:8765` 或尾网 `https://<host>.<tailnet>.ts.net`，可改）→ 用户名/密码（首次由站长给初始密码）→ 记住设备；**没有注册页**。
- 设置页：账号、设备管理、改密码、退出登录、导出全部数据（JSON+素材 zip，一项就够）。
- 桌面端首次运行同样走登录页；不再需要启动器写 `desktop-token`。

---

## 7. 多租户隔离

### 7.1 强制边界（代码层）

```
请求 → auth 依赖解析 token → AuthContext{user, device}
     → 路由函数只拿到 ctx 与 repo
     → repo.* 的第一个参数永远是 user_id（类型标注 UserId = NewType("UserId", str)）
     → 任何「查全部用户/按 id 直查」的接口只存在于 admin 模块，且默认不返回正文
```

- 删除旧 `store.state()`/`store.update()` 这类无主 API；代码评审红线：仓储之外不允许出现 `WHERE id =` 而不带 `user_id`。
- `channel_identities`：外部 id 只映射唯一 user；绑定码校验直接由 code_hash → user，不做「遍历所有用户试码」。
- 素材/表情文件：路径一律 `DATA_DIR/users/<uuid>/...`，读取前用 `resolve()` 校验仍在用户目录内（复用 `materials.resolve` 的既有做法）。
- 助手记忆/人设/API key/对话：全部 `user_id` 外键 + 查询带 user。
- 事件与通知：`events(user_id, revision)`，`outbox.user_id`；QQ 主动消息配额按用户统计，互相不挤占。

### 7.2 隔离测试（够用即可）

`server/tests/test_tenancy.py`，4 条：

1. 用户 A、B 各建任务；A 的 snapshot 不含 B 的任何 id；
2. A 拿 B 的 task/block/material/draft id 调几个主要接口 → 404；
3. 未认证/过期令牌 → 401；
4. 通道：B 的 openid 写不进 A 的对话；助手：B 改不了 A 的配置/记忆。

> 不追求攻击面覆盖，也不做「遍历所有路由断言鉴权」的脏检查（想要可以加一条便宜断言，不想要就靠评审）。

### 7.3 信任边界（不做威胁建模）

- 用户就是你和师弟 2–4 个熟人，**不做攻击者建模、不做严格攻击面测试**；上面 §7.1/§7.2 只保证「不串台」，不保证「防恶意用户」。
- 不做邀请码、不做审计日志、不做账号删除冷静期、不做越权模糊测试；密码/令牌/HTTPS 是顺手保留的基本盘（§6.2）。公众号回调必须对公网开放，但只接受微信签名/AES 校验过的 XML，其余接口照旧要令牌；不做 WAF/攻击面测试。
- 真正要防的是意外：备份、恢复演练、误删保护——这些在 §15/§16，属于运维，不属于安全。

---

## 8. 通道层（公众号为主，QQ 私人/可选）

### 8.1 统一抽象

```
channels/base.py     # send_text/send_image/被动回复窗口/配额/去重键
channels/qq.py       # 现有 qq.py 基本保留：只服务你本人（私人通道），不做多租户
channels/wechat.py   # 主通道：公众号级凭据，openid 级身份，5s 被动回复/48h 客服消息
channels/binding.py  # 绑定码生成/校验/解绑；身份查询
channels/dispatch.py # 入站消息 → 用户 → 助手管线；出站统一写 outbox
```

- **凭据是站长级**（公众号 AppID/Secret/Token、QQ AppID/Secret），存 `app_config`（加密、只有你自己能改）；**用户级只有身份绑定**。
- 每人最多绑一个通道（可按需允许两个都绑，但提醒只走「主通道」避免重复；默认绑一个）。

### 8.2 绑定流程（两个通道同一套）

```
App 设置页「绑定公众号」→ POST /channels/bind-code {channel} →
   服务端生成 6 位码（10 分钟、仅本人、一次性），显示「在公众号对话框里发：绑定 123456」
→ 用户在公众号里发：绑定 123456
→ 通道入站 → dispatch 查 code_hash → 绑定 channel_identities → 回「绑好了，我是你的大肥鱼」
→ App 轮询/长连收到绑定成功 → 引导前进一步
```

- 未绑定用户发消息：回一句「先来 App 里拿绑定码」+ 公众号关注提示。
- 解绑：App 内一键解绑（同时清掉该通道的提醒发件箱）；旧 openid 再来消息按未绑定处理。
- 重复绑定：同一 openid 换绑到另一个账号需先解绑并二次确认（防止「师弟的号被绑到我这里」）。

### 8.3 一个公众号服务多用户（主通道，需求 4）

- 公众号只作为「出口/入口」，不做账号体系；`channel_identities(wechat, openid)` → 用户；每个用户的消息、记忆、日程、提醒按 `user_id` 落库，天然不串台。
- 公众号限制落到实现（按账号类型降级）：
  - **5 秒被动回复**：确定性命令（绑定/完成/撤销/今天/总结/早开始）走同步快路，5 秒内必回；
  - **长回答/异步**：认证服务号用 48h 客服消息补发；只有个人订阅号时，立刻被动回复「这个要一会儿，完成后去 App 对话里看」，结果写进 App；不假装能推；
  - **提醒**：服务号在 48h 窗口内补发 + 模板消息；个人订阅号只靠 App 本地通知，outbox 标记 `window_closed` 后不再重试；
  - **公众号测试号**（开发期）：无备案/认证要求，先把回调、绑定、命令链路跑通。
- `outbox` 统一处理「微信 48h 窗口 / QQ 每日配额」；失败重试与降级规则在 §8.4。

### 8.4 通知与提醒

- 来源：后台任务（session 预计结束、等待检查、每日复盘、周报）→ `outbox`。
- 每用户通知窗口（quiet hours）、通道、是否开启提醒都在设置里；App 本地通知仍是主力（手机离线可用），与通道消息用同一 `dedupe_key` 去重。
- 失败重试：指数退避 + 最大次数；耗尽或窗口关闭后写 App 内「未送达」列表，不静默丢。

---

## 9. 助手 2.0（需求 5、6）

### 9.1 处理管线（服务端唯一入口）

```
POST /assistant/chat {client_msg_id, text?, image?}
1. 幂等去重（user_id + client_msg_id）
2. 确定性快路：记住/忘记/帮助/今天/明天/继续/确认/撤销/绑定/教程 → 直接执行（不耗 token，LLM 挂时也能用）
3. 上下文构建：用户时区 now、运行中会话、今日块、逾期、等待检查、空闲时段、
   相关记忆≤12、最近 8 轮对话+滚动摘要、人格卡、待回答问题
4. LLM 调用（用户自己的 base_url/model/key；JSON Schema 输出；20s 超时、2 次重试）
5. 解析校验：reply / operations≤5 / question? / memory? / meme?（pydantic extra=forbid）
6. 接地校验：实体解析（「它/第二个/刚才那个」→ 上轮提到的 id）；
   每条操作在 deepcopy 状态上试运行，非法的丢弃并生成解释
7. 若 question：写 assistant_pending_questions（10 分钟），回复问题与选项
8. confirm 模式：落草稿（15 分钟）+ before/after diff；auto 模式：安全操作直接执行，
   破坏性操作仍要确认
9. 记忆抽取：只接受模型显式返回的 memory，去重、限长、上限 200
10. 回写消息/用量，返回 {message, applied[], drafts[], question?, revision}
```

### 9.2 更智能的具体抓手

| 能力 | 做法 |
| --- | --- |
| 多意图 | 一句话拆多个操作（≤5），按依赖排序；超过则先回计划请确认 |
| 时间表达 | 「明天下午三点前」「两天后」「下周一开始」统一在用户时区解析；DST 歧义沿用现有 `localTimeCandidates` 逻辑 |
| 指代 | 会话内 `last_entities`（任务/块 id），支持「它」「刚才那个」「第二个」 |
| 反问 | 信息不足时给 2–4 个选项，用户回「1」「第二个」或自由文本；下一轮带问题上下文 |
| 偏好记忆 | 「以后晚上别排任务」→ memory(kind=preference)，排程/建议时作为约束提示（不是硬规则，除非用户说「永远」） |
| 主动建议 | 「我该做什么」：基于当前块、逾期、deadline、精力时段给 1–3 条，可一键采纳 |
| 每日复盘 | 由 worker 生成，写入 reviews；内容带完成率、漂移、下一日建议 |
| 人格 | §9.5；风格层与硬规则分离，风格不能改安全性 |
| 失败兜底 | LLM 失败/超时/限额：快路能答就答，否则友好提示并保留「重试」按钮，同时记 `assistant_usage` 失败 |
| 可观测 | 每次调用记录 intent 命中、耗时、token、是否被校验拒绝；周报给站长看聚合 |

### 9.3 操作白名单与护栏

- 可自动执行：`schedule_new`、`schedule_task`、`move_block`、`protect`、反馈类（完成/部分完成/中断）、`remember`、`cancel_block`/`cancel_task`（仅限他自己点名取消的那一段/那个任务）。
- 仍要确认的：跨多日重排、一次改动 >3 段、删除记忆/素材、任何 `undo`、以及**你手动把某个用户切回「先确认」时**的所有动作。
- **新用户默认直接执行**（`confirm_first=false`）：助手直接落地，回复说明改了什么；24 小时内可一键撤销（`assistant_undo`），撤销失败要有明确提示。
- 你（老用户）迁移时保持现有设置（现在是直接执行）。
- 草稿预览仍保留给「先确认」模式：App 展示「将做什么」的 diff，确认后一次事务应用，15 分钟过期。

### 9.4 记忆

- 存储：`assistant_memories`（kind: preference/fact/routine/person，text，tags，source_msg_id，pinned）。
- 召回：pinned + 关键词/标签评分 + 最近使用时间，取 ≤12 条；不做向量库（规模小、成本低），预留 pgvector 升级位。
- 管理：App「助手记得什么」列表，可编辑/删除/清空；模型每轮最多写 2 条，去重（归一化后相同则更新 last_used）。
- 生命周期：非 pinned 的 fact 180 天未命中可归档；隐私设置里「不允许记忆」开关。

### 9.5 人格卡（需求 5）

- 数据：`persona {preset_id, name, addressing, tone, humor, directness, catchphrases[], avoid[], custom_text}`。
- 预设：**大肥鱼（默认，保留现有灵魂）**、严谨教练、安静同桌、毒舌损友、自定义。
- 自定义：用户写 ≤600 字描述 + 三个滑杆（活泼度/玩笑密度/直接度）；保存前可「试一句」预览。
- 组装：`人格卡 → 风格段落`，与「硬规则（准、不越权、不说客服腔、必须给全时间/撤销信息）」分开拼接；风格再离谱也不能覆盖硬规则。
- 尊重原有设计：称呼「主人」是默认人格里可改的字段，不再是全局常量；`docs/design/assistant-voice.md` 降级为「默认人格卡的设计说明」。
- 换人格不影响历史记忆与草稿；表情包库按用户开关（默认开，可关）。

### 9.6 意图评测（可量化）

- `server/tests/fixtures/intent_eval.jsonl`：60 条真实说法 × 固定状态 fixture，标注期望操作与关键字段。
- 离线：MockLLM 回放（CI 必跑），断言「操作 kind + 关键 slot」完全匹配、且绝不产生非法写入。
- 在线：`python -m app.eval --live --user me` 用真 key 跑一遍，输出准确率/平均耗时/token；目标 ≥90%，低于则回到提示词/工具集迭代。
- 发布门槛：P0 缺陷清零 + 评测 ≥90% + 跨租户测试全绿。

---

## 10. 手机优先：新手引导与周视图（需求 2、7）

### 10.1 引导状态机

- 服务端 `users.onboarding`：`{version: 2, step: 5, done: [...], skipped: [...], updated_at}`；`PATCH /me/onboarding` 持久化，换设备续上；设置页「重看教程」重置。
- 10 步（每步：标题、正文、目标控件、动作、是否可跳过）：

| # | 步骤 | 目标/动作 | 完成条件 |
| --- | --- | --- | --- |
| 1 | 欢迎 | 全屏卡片 | 点「开始」 |
| 2 | 账号 | 已登录（登录页引导） | 有令牌 |
| 3 | 服务器 | 托管版默认地址，仅展示 | 自动 |
| 4 | 作息 | 高亮「起床/睡觉/每日复盘时间」 | 保存一次 |
| 5 | DeepSeek | 打开助手设置，填 key → 测试 | 测试成功 |
| 6 | 人格 | 高亮人格卡选择 | 选中或跳过 |
| 7 | 通道 | 高亮「绑定公众号」（QQ 在高级里） | 绑定成功或跳过 |
| 8 | 通知 | 高亮通知权限 + 电池白名单 | 授权或跳过 |
| 9 | 第一个任务 | 高亮「+」，输入「今晚 8 点写周报 1 小时」 | 任务生成且有块 |
| 10 | 完成 | 总结 + 「先逛逛」 | 关闭 |

- 实现：不引入依赖，自己写 `CoachOverlay`
  - `CoachTarget(key: CoachKeys.xxx)` 包住目标控件；`CoachKeys` 常量集中管理，避免字符串散落；
  - `OverlayEntry` 绘制半透明遮罩 + `Path.combine(PathOperation.difference)` 挖洞，高亮框带呼吸动画；
  - 卡片自动定位（上/下/左/右，空间不够翻转），自动滚动到目标（`Scrollable.ensureVisible`），`Semantics` 播报；
  - 每步「跳过/上一步/下一步」，进度点；第 5/7/8 步的动作可跳出引导去对应页面，完成事件回来再前进；
  - 首次启动只走一次（服务端标记）；老用户迁移默认 `done` 全部，不打扰。

### 10.2 手机周视图重做（需求 7）

现状问题（`apps/planner/lib/widgets/week_overview.dart`、`pages/week_page.dart`）：

- 360dp 宽度下 7 列各约 44dp，标题放不下，只能「长按看全名」；15 分钟块约 7dp 高，点不中（低于 44dp 触控标准）；
- 周概览与「详细课表」是两套模式，来回切换；详细课表 672 行网格在手机上要横向滚动；
- 颜色按任务身份（`ScheduleInk`）着色，任务一多就分不清；缺「本周负荷/空闲」汇总；
- 没有清晰的「今天在哪」锚点与空状态引导。

新结构（手机 `<600dp` 时；桌面保留 `WeekCalendar` 网格）：

```
┌────────────────────────────────────┐
│ ‹ 10月20日–26日 ›   本周已排 18h     │  WeekStrip（7 个日签，滑动切周）
│ 一 二 三 四 五 六 日（今天描边/忙点）│
├────────────────────────────────────┤
│ 08 ┤▍  ▍▍   ▍    ▍   (周热图，可捏合)│  WeekHeatmap（省掉文字，只表达时间占用）
│ 12 ┤▍▍ ▍    ▍▍ ▍▍   ▍              │
│ 18 ┤   ▍▍   ▍    ▍▍                │
├────────────────────────────────────┤
│ 周三 10/22 · 空闲 3.5h   [+ 加任务]  │  选中日议程（默认今天，可滑动切日）
│ 09:00–10:30 周报初稿   ▶ 进行中      │  每项：时间、标题、状态、任务色点
│ 11:00–12:00 算法题                  │  点击 → 详情；长按 → 快速改时间
│ 14:00–15:00 组会（保护块）           │
│ ……                                  │
└────────────────────────────────────┘
```

- 周条：显示日期/星期/今日描边/完成度小点；左右滑动切周；点日签选中；
- 热图：默认 `day_start..day_end`（现有设置），有超出时自动扩展；块最小 4dp、宽度按列自适应；捏合缩放时间范围；点击列选中日；色块按项目色 + 无标签，图例在下方可横向滚动；
- 议程：主要交互区（点击目标 ≥44dp），显示完整标题与状态；底部「空闲 x 小时」；空状态「这周还空着，点热图格子开始排」；
- 汇总条：已排/空闲/逾期三个数，点逾期跳任务页筛选；
- 去掉「整周总览/详细课表」双模式切换；桌面仍用大网格（保留「详细课表」入口给需要的人）；
- 性能：`daySlices` 只算一次、列表项 `RepaintBoundary`、`now` 每分钟刷新只重绘今日列；
- 文件：新增 `widgets/week_strip.dart`、`widgets/week_heatmap.dart`、`widgets/day_agenda.dart`；重写 `pages/week_page.dart`；补 widget 测试（选中日、空状态、点击命中、捏合边界）。

### 10.3 其它「手机优先」收尾

- 底部导航重构：今天 / 周 / 任务 / 助手 / 我的（现为悬浮轮盘，保留但可切换为底部栏，默认底部栏更适合新手）；
- 首次启动直接进登录页（而非「连不上服务器」错误）；
- 离线：无网时可看缓存快照、可排队操作（现有队列修复后保留）；顶部显示「离线，N 条待同步」；
- 错误文案统一：401 → 重新登录；revision 冲突 → 自动重拉；网络失败 → 重试。

---

## 11. 缺陷修复并入排期

按审查结论排优先级；带 ⚠ 的是多用户下会放大成事故的。

| 级别 | 缺陷 | 位置 | 阶段 |
| --- | --- | --- | --- |
| P0 | `not_started` 反馈后 block 永久卡 `planned`（任务不再出现） | `server/app/domain.py:330-349` | P1 |
| P0 ⚠ | `task.update` 不带 version 时整包覆盖，并发丢数据 | `domain.py:204-210` | P1 |
| P0 | 撤销只校验 revision，别人改动后被静默覆盖 | `assistant_service.py:265-283` | P2 |
| P0 | 唯一密码凭据被删后锁死 + 唤醒锁不释放 | `domain.py:600-631`、`gateway.dart:213-224` | P1/P3 |
| P0 ⚠ | 同步队列遇 4xx 永久卡死；`preservedConflicts` 未恢复（数据丢失） | `apps/planner/lib/controller.dart:272-317` | P3 |
| P0 ⚠ | QQ 解绑/重绑错绑到旧身份（3 处独立问题） | `server/app/wechat.py:233-241`、`qq.py:185-365,445`、`chat_commands.py:90-102` | P2 |
| P0 | 后台三个循环任一次异常就永久停摆 | `server/app/main.py:36-80` | P1（随 worker 重写消除） |
| P1 | 部分完成时长仅算 running 段；`not_started` 不取消当日未来块；同分钟迟到误判 | `domain.py:253-314` | P1 |
| P1 ⚠ | 幽灵提醒：`events` 每 5 秒重播导致重复通知 | `main.py:359-389`、`proactive.py:184-193` | P2 |
| P1 | DST 日期加减用 Duration（北京时间 3 个日期已错） | `home_layout.dart:103-116`、`ink_wheel_picker.dart:368,419` | P3 |
| P1 | 提醒注册表损坏后永不恢复；`_shown` 无上限 | `apps/planner/lib/reminders.dart:299-303,456-460` | P3 |
| P1 | 跨午夜页面不换天、桌面引导 120 秒无法纠正 | `home.dart:137-150`、`widget_page.dart:8-10`、`gateway.dart:158-181` | P3 |
| P1 | 发件箱 delivered 失败不记错误；channel 串行阻塞 15–48s | `qq.py:428,482-484`、`main.py:48-56` | P2 |
| P1 | `/health` 无鉴权泄露版本；`assistant_test` 静默落盘 base_url；llm 失败无记录 | `main.py:119-122,260-271`、`assistant_service.py:138,165-169` | P2 |
| P1 ⚠ | 配对码「先消费后插入」可被并发废掉；pending 配对永不清理 | `main.py:149-169` | P1 |
| P1 ⚠ | `chat_commands` 删除记忆写错表/缺 `video_path`（多用户后更易触发） | `chat_commands.py:90-102,60-71` | P2 |
| P1 ⚠ | 图片/素材/归档目录无租户隔离 | `materials.py:19-45`、`archives.py` | P1/P2 |
| P2 | 记忆删除 `history` 不存在、截图路径不规范化、密码哈希可被覆盖 | `memory_commands`、`assistant.py:127`、`domain.py:79-89` | P2 |
| P2 | 整份文档无界增长（proposals/events/operations/记忆/反馈永久保留） | `store.py:39-41`、`assistant_service.py:244-283` | P1（§5.5 瘦身） |
| P2 | 重复扫码消费已有配对；微信 token 每消息刷新；QQ 已处理列表无界 | `store.py:226-228`、`wechat.py:79`、`qq.py:512-524` | P2 |
| P2 | 分钟级重复通知/抖动、快照全量下载、`/health` 探测耦合 | 多处 | P2/P4 |

> 完整清单与复现步骤在上一轮审查报告里（P0×8、P1×21、P2×20），修复时逐条加回归测试；每阶段结束跑 `pytest`（目标 ≥220）+ `flutter test` + `analyze`。

---

## 12. 代码结构与迁移步骤

```
server/
  app/
    db.py            # SQLite 连接/JSON 编解码/事务（BEGIN IMMEDIATE）
    auth.py          # users/devices/tokens
    tenancy.py       # AuthContext、current_user 依赖
    repo.py          # 取代 store.py：state_for/apply_operation/events/outbox
    domain.py        # 不改（纯函数，加 user 无关注释）
    planning.py adjustments.py execution.py maintenance.py  # 不改
    channels/        # qq.py wechat.py binding.py dispatch.py base.py
    assistant/       # service.py persona.py intents.py memories.py eval.py
    routers/         # auth.py sync.py operations.py assistant.py channels.py admin.py
    worker.py        # 后台循环（同进程启动，以后可拆进程）
    admin.py         # CLI：user add/reset/disable/export
    migrations/      # 轻量版本化 SQL（schema_version）
  tests/             # 现有 171 + tenancy/auth/sync/migration 新测试
apps/planner/lib/
  auth/              # login_page.dart session.dart
  onboarding/        # coach_overlay.dart steps.dart keys.dart
  assistant/persona_page.dart memories_page.dart
  week/              # week_strip.dart week_heatmap.dart day_agenda.dart
  settings/          # account/devices/channel_bind/onboarding 入口
tools/
  host/              # cloudflared.ps1 tunnel-watchdog.ps1 backup.ps1 restore.ps1 restore-drill.md
  migrate-v1-to-v2.py
docs/plans/v2-multiuser-plan.md（本文件）
```

迁移顺序（每步可独立合并、保持测试全绿）：

1. **DB 骨架**：新增 `db.py/auth.py/repo.py` 与迁移；`store.py` 保留兼容层，旧接口照旧（测试仍绿）。
2. **每用户状态**：`user_state` 落地；`/operations`、`/snapshot` 走新仓储；引入 `PLANNER_AUTH=local` 兼容单机。
3. **认证**：登录/设备/站长开账号；手机端加登录页；旧 device token 迁入（重登即可）。
4. **通道多租户**：`channel_identities` + 绑定码；公众号（主通道）先改，QQ 保留私人；发件箱按用户。
5. **助手多租户**：config/key 加密、人格卡、记忆、澄清、评测集。
6. **worker**：把 `main.py` 三个循环抽成 `worker.py` 模块（同进程启动，接口与线程模型不变），`main.py` 只负责装配；以后要拆子进程只改启动方式。
7. **客户端**：引导、周视图、账号设置、bug 修复。
8. **部署与迁移**：本机新数据目录、备份/恢复脚本、cloudflared 隧道 + 公众号回调配置、APK 分发；旧数据导入；灰度。

---

## 13. 阶段计划与验收

| 阶段 | 内容 | 工期（业余） | 验收 |
| --- | --- | --- | --- |
| P0 决策与地基 | 拍板 §17；建 v2 分支；本机新数据目录 + 备份/恢复脚本；cloudflared 隧道 + 公众号回调打通 | 0.5–1 天 | 公网 `curl /health` 200 且数据接口无令牌 401；公众号回调自检通过；备份恢复演练一次成功 |
| P1 认证与多租户 | DB schema、repo、auth/devices、每用户状态、迁移脚本、4 条 tenancy 测试、P0 后端修复 | 4–6 天 | 两账号交叉 404；旧数据导入一致；pytest ≥185 |
| P2 助手与通道 | 公众号回调/绑定/发件箱；助手 config/persona/memory/usage；澄清；评测集；P0/P1 通道修复 | 3–5 天 | 两用户公众号互不串台；评测 ≥90%；key 加密可验 |
| P3 客户端 | 登录/引导 10 步/人格卡页/周视图重做/同步提醒跨午夜 bug/桌面精简 | 4–6 天 | 360dp 周视图可用；引导可跳过/续播；flutter test ≥100 |
| P4 上线 | 数据迁移、备份/恢复演练、APK 分发、给师弟开账号 + 关注公众号绑定、灰度两周 | 1–2 天 | 师弟独立使用一周无串台/丢数据；RTO ≤1h |

关键路径：P1 → P2（通道可并行）→ P3（周视图/引导可与 P2 并行）→ P4。总日历约 **3 周**（家 PC + 只做基本盘安全，比云方案少 1–2 周）。

---

## 14. 测试与验收清单

- 后端：现有 171 + 认证/租户/同步/迁移/评测 ≈ 220+；`pytest -q` 全绿。
- 客户端：`flutter test`（现有 77 + 周视图/引导/登录）；`flutter analyze` 零问题。
- 多租户：§7.2 八条 + 「所有非 public 路由都有鉴权」遍历断言。
- 迁移：快照 diff（忽略 revision/时间戳）+ 素材数量 + 令牌可用性。
- 通道：公众号——你的微信和师弟的微信各发一条，确认归属与 5 秒内回复；提醒窗口关闭时降级到 App 通知。
- 助手：意图评测离线 100% 无非法写入、在线 ≥90%；破坏性操作一律要确认。
- 周视图：360dp/390dp/430dp 三档截图核对；点击命中；空状态；捏合边界。
- 备份：`sqlite3 .backup` → 新数据目录恢复 → `/snapshot` 对比一致；每月演练。
- 压测：3 用户 × 1000 operations 并发提交，p95 `/snapshot` < 300ms（gzip 后 < 100ms），无跨用户错乱、无 `database is locked`。
- 基本盘：git 里没有 key/token；日志里没有正文/密钥；两账号交叉抽查不串台。

---

## 15. 部署与运维（家用机常开）

### 15.1 服务装在你自己的电脑（zx 的开发机）

- 就装在你天天开的那台 Windows 上（你是开发者本人，排障最方便）；开发和生产共机，靠端口 + 独立数据目录隔离：生产 8765 / `%USERPROFILE%\TimePlanner\data`，开发用 `PLANNER_DATA_DIR` 指向临时目录。
- 电脑不关机；关机/重启由计划任务 + `Start-Timer.ps1` 拉起；家里断网时客户端离线队列先顶着，恢复后补同步。
- 以后真要搬机器（换电脑/换人托管）：停服务 → 最新备份 `restore.ps1` 起新机 → 手机/电脑改「服务地址」→ 新机跑 `cloudflared`。**不改代码、不用重新注册。**
- 备份：每日 03:00 → `sqlite3 .backup` + `robocopy` 到第二块盘；可选 rclone 加密到 B2；保留 14 日 + 8 周。

- 进程：Windows 计划任务 `TimePlannerBackend` 运行 `tools\Start-Timer.ps1`（已有；先 venv python，15 秒内 `/health` 不通则用基础解释器兜底）；服务固定端口 8765，只绑 `127.0.0.1`，由 `cloudflared` 命名隧道对外发布。
- 入口：`cloudflared` 命名隧道 → `https://timer.<你的域名>`（公众号回调、手机、桌面共用）；`tools/tunnel-watchdog.ps1` 保活；Tailscale 仅作内网直连备选。
- 数据目录：`%USERPROFILE%\TimePlanner\data`（`planner.db` + `secrets/` + `users/`）；从不进 Git（已有规矩）。
- 备份：每日 03:00 计划任务 → `sqlite3 planner.db ".backup"` 到 `%USERPROFILE%\TimePlanner\backups\daily\` + `robocopy` 到第二块盘（或 rclone 加密到 B2）；保留 14 日 + 8 周；`tools\host\restore.ps1` 一键恢复；每月演练一次并在 STATUS 记结果。
- 可靠性：小 UPS；BIOS 来电自启；Windows 更新设活动时间；`/health` 自检 + `Start-Timer.ps1` 兜底；磁盘剩余 <20% 告警。
- 监控：`/healthz`（含 DB 可写检查）由本机 watchdog + 手机探活；异常（连续失败/磁盘满/备份失败/LLM 错误率 >20%）通过公众号/App 通知给你；服务日志轮转保留 7 天。
- 发布：`tools/build-android.ps1` 产物 → 数据目录 `releases/` → 更新 `app_releases`；keystore 离线两份备份（不入 Git）。
- 成本：托管 ¥0；B2 可选 ¥10/月；域名已有（仅微信/兜底隧道需要）；DeepSeek 各付。
- 迁移期：现有 cloudflared 入口与新版并存两周；手机改地址后观察，再退役旧隧道。

---

## 16. 风险与回滚

| 风险 | 概率 | 应对 |
| --- | --- | --- |
| 家里断电/断网 | 中 | 客户端离线队列恢复后补同步；小 UPS；服务重启后 `jobs`/`outbox` 续跑；断网期间提醒延迟可接受 |
| 硬盘坏/误删 | 低 | 每日 `.backup` + 第二块盘/异地；每月恢复演练；旧库保留 30 天 |
| Windows 更新/崩溃重启 | 中 | 计划任务自启 + `Start-Timer.ps1` 兜底 + `/health`；更新设活动时间 |
| 换机器（自己 ↔ zx） | 低 | 恢复备份 + 改客户端地址即可；迁移前先演练一次 |
| 公众号只有个人订阅号 | **高** | 只能 5 秒被动回复、不能异步推送：命令走快路、长回答回 App；要完整能力需认证服务号（¥300/年 + 主体） |
| 回调域名未备案 | 中 | 开发期用微信测试号；正式上线前备案，或暂时接受「公众号仅测试号可用」 |
| 公网回调被扫/被刷 | 低 | 密码 + 设备令牌 + 绑定码；给回调接口加限流；不做 WAF |
| 改造面过大延期 | 中 | 阶段化交付；P1 完成即可先让师弟用「无助手」基础版 |

回滚：旧 SQLite 副本与旧入口保留；手机改回地址即恢复；新库可导出回 v1 格式（一次性脚本随迁移脚本提供）。

---

## 17. 已拍板与剩余待确认（2026-10-22）

已定（`m00671`）：

1. **服务装你自己电脑**（你就是 zx，开发者本人）；
2. **公众号为主通道**，QQ 只留给你个人；
3. **DeepSeek 每人自带 key**，不用站长的；
4. **新用户助手默认直接执行**（24h 一键撤销，可切回先确认）。

还需你确认（影响公众号能不能做到「完整版」，见 §8.3）：

1. **公众号账号类型**：现在有/能注册的是「个人订阅号」还是「认证服务号」？个人订阅号只能 5 秒内被动回复、不能异步推，长回答要回 App；认证服务号才能异步回答 + 主动提醒（需个体工商户/企业主体，约 ¥300/年认证）。
2. **域名是否已备案**：公众号正式回调一般要求 ICP 备案域名；没有的话先用微信「测试号」开发，备案后再切正式号。

> 其余按推荐直接定，不再问：数据保留（消息 90 天 / 日程永久 / 已完成任务 180 天归档）、忘记密码（站长 CLI 重置，不做邮箱找回）、没有注册页（站长开账号）、不做邀请码/审计/威胁模型。

## 18. 下一步（你确认后我按这个顺序动手）

1. 你确认 §17 的两项（公众号账号类型、域名备案）→ 建 `v2` 分支。
2. P0（半天到一天）：本机新数据目录 + 备份/恢复脚本 + `cloudflared` 隧道跑通 + 微信测试号回调验证。
3. P1：认证/租户/导入旧数据（先让你自己的数据在新系统跑起来）。
4. P2/P3：公众号通道（回调/绑定/5s 快路/48h 窗口）+ 助手 2.0/人格卡 + 引导 + 周视图。
5. 修 §11 的 P0 后端/通道缺陷，再逐级清 P1。
6. 按选定的机器部署（你这台）、给师弟开账号 + 关注公众号绑定，灰度两周；顺手把 HANDOFF 铁律改写、STATUS 与本文件同步。
