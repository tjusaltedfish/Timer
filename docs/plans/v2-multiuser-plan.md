# 瞬时 v2：多用户托管版实现方案

- 状态：**待拍板**（未改任何代码）
- 日期：2026-10-22
- 基线：`main@7c005e4`（后端 pytest 167 passed / Flutter test 77 passed / analyze 干净）
- 对应需求：把「只在我电脑上跑的个人助手」改成「师弟也能用的、手机优先、电脑可同步查看」的托管版，同时修掉审查发现的缺陷。

---

## 0. 一页结论

| 问题 | 推荐做法 |
| --- | --- |
| 要不要用户登录？ | **要**。邀请码注册 + 用户名密码登录 + 设备长期令牌；不做手机号验证码（无短信成本、无合规负担） |
| 真正的后端/数据库 | **Postgres 16 + 常驻云服务器**（Docker Compose）；每用户一个 JSONB 文档（沿用现有 domain 引擎）+ 规范化认证/设备/操作日志/事件/发件箱/密钥表 |
| 手机、电脑都要开吗？ | **都不用**。服务在云上常开；手机是主客户端，电脑只是可选的第二客户端；原来的 Cloudflare Tunnel + watchdog 退居「本地开发/备用」 |
| 多用户怎么隔离 | 请求上下文强制 `user_id`；仓储层不接受无主查询；文件、通道身份、助手记忆/密钥/人设全部按用户分域；跨租户测试进 CI |
| 通道二选一 | **QQ 机器人优先**（WebSocket 长连接，不要公网回调/域名/备案）；微信公众号作为可选的第二通道（一个号服务所有用户，openid→用户绑定） |
| DeepSeek key | 默认**每人自带**、加密入库、只回显尾号；可切换「用站长的共享额度 + 每日限额」 |
| 新用户引导 | 服务端记录进度的 10 步高亮教程（可跳过、可重看、换设备续上），其中包含 DeepSeek 配置测试、QQ/微信绑定、人格卡选择、第一个任务 |
| 手机周视图 | 从「7 列小地图 + 详细课表」双模式改为「周条 + 周热图 + 选中日议程」三层结构，点击目标 ≥44dp，空闲/负荷统计常驻 |
| 助手更智能 | 意图路由（确定性快路 + LLM 工具调用）+ 上下文接地 + 反问澄清 + 实体指代 + 记忆检索 + 人格卡；破坏性操作永远要确认 |
| 周期 | 约 4–5 周（业余、AI 辅助；全职可压到 3 周），分 5 个阶段，每阶段可独立验收 |
| 成本 | VPS 2C4G 约 ¥60/月 + 备份 ¥10/月 + 域名已有 + DeepSeek 按人自付；公众号/QQ 机器人本身免费 |

---

## 1. 需求映射

| 用户需求 | 方案章节 |
| --- | --- |
| 1. 真后端/数据库、通用化、手机为主、电脑同步、是否要登录 | §2 现状差距、§3 目标架构、§4 D1/D2、§5 数据模型、§6 认证 |
| 2. 首次进入逐步高亮教程，含 DeepSeek API、QQ 绑定；微信可暂不绑；QQ/微信二选一 | §9 新手引导、§8 通道 |
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
| 对外靠家里电脑 + `cloudflared` + watchdog | `docs/STATUS.md:52-62`、`tools/tunnel-watchdog.ps1` | 电脑必须常开——正好违背需求 1「手机与电脑不用都开着」 |
| QQ/微信通道绑定是单例 | `server/app/qq.py`、`wechat.py`、`store.py` 中 bind 表 | 只能记一个 openid；换人即串台 |
| 助手设定/记忆/人格写死在提示词与 `assistant_messages` | `server/app/assistant.py`、`assistant_service.py` | 「主人/大肥鱼」是作者个人口味，无法给师弟换人格 |
| 版本与 APK 由本机静态目录提供 | `server/app/releases.py`、`main.py` `/app/download` | 可以复用，但需要 HTTPS 域名与签名管理 |
| 个人常量散落 | 默认时区 `America/Los_Angeles`（`store.py:28`）、`desktop-token`、个人表情库 | 通用版要改成「首次登录由设备时区初始化 + 用户可改」 |

另外，上一轮审查已确认的一批缺陷（P0/P1 见 §11）必须在改造期间一起修，否则多用户会把单机 bug 放大成「数据串台/数据丢失」。

---

## 3. 目标架构

```
            ┌───────────────┐   ┌────────────────┐   ┌──────────────┐
            │ Android 手机   │   │ Windows 桌面    │   │ QQ / 微信     │
            │ (主客户端)     │   │ (可选第二端)    │   │ (IM 通道)     │
            └───────┬───────┘   └───────┬────────┘   └──────┬───────┘
                    │ HTTPS + Bearer 设备令牌            │ 长连接/回调
                    ▼                   ▼                    ▼
        ┌──────────────────────────────────────────────────────────┐
        │                    云服务器（Docker Compose）              │
        │  Caddy(TLS) ── api(FastAPI, 无状态) ── worker(后台任务)     │
        │                      │                     │              │
        │                      └──────┬──────────────┘              │
        │                        Postgres 16                          │
        │   users / devices / user_state(jsonb) / operations_log /    │
        │   events / outbox / jobs / channel_identities /             │
        │   assistant_configs / memories / materials / audit_log      │
        │                      文件卷：users/<uuid>/materials|memes   │
        └──────────────────────────────────────────────────────────┘
                    │ 每日 pg_dump 加密 → 对象存储（B2/S3）
                    ▼
              备份 / 监控（自检 + 异常时用 QQ 机器人告警）
```

关键点：

- **手机与电脑都只是客户端**，服务器常开；任一客户端离线不影响另一个，也不影响后台（按时段提醒、超时结算、周报）。
- API 进程无状态（令牌在 DB），可重启；后台任务移到 `worker` 进程，用 `jobs` + `outbox` 表驱动，**同一任务只执行一次**。
- 数据同步：保留现有 `/operations`（幂等、按设备）+ `/snapshot`，增加 `ETag`/`gzip` 和 `/sync?since=revision` 轻量增量提示；客户端仍只渲染服务端状态（业务逻辑继续只写在 `domain.py`，客户端不做第二套规则）。
- 通道与助手都通过「用户上下文」工作：IM 消息先解析 `channel + external_id` → 用户，再走同一个助手管线。

---

## 4. 关键决策（推荐 + 备选）

### D1 登录形式：要登录，用「邀请码 + 用户名密码 + 设备令牌」

- 注册：`POST /auth/register {invite_code, username, password, device_name, platform}`；邀请码由你（admin）生成，一次性、7 天有效。这样公网暴露也不会被陌生人注册。
- 登录：用户名 + 密码 → 返回长期设备令牌（30–90 天滚动，可随时在 App 里吊销）。手机第一次登录后不再输密码；桌面同理。
- **不做**手机号验证码（要短信服务商、要费用、要实名/合规）；**不做**微信扫码登录（公众号未认证时拿不到稳定网页授权，且师弟不一定愿意授权）。后续可加 passkey/邮箱找回。
- 桌面端不再依赖 `desktop-token` 文件引导；保留 `local` 模式仅用于开发与应急（`PLANNER_AUTH=local`）。

**为什么不是「免登录、只靠配对码」**：订阅式 IM 绑定可以作为第二身份，但 App 本身必须有账号——否则换手机、清数据、多设备同步、助手记忆归属都无解。

### D2 数据库：Postgres 16，每用户一份 JSONB 状态 + 规范化周边表

- 继续复用 `domain.py / planning.py / adjustments.py`（纯字符串状态机，167 个测试保护），只把 `store.py` 换成 `repo.py`：`state_for(conn, user_id)` 读写 `user_state.body`。
- 认证、设备、操作日志、事件、发件箱、任务队列、通道身份、助手配置、记忆、素材**全部规范化成表**（这些需要索引、按人查询、并发安全）。
- 迁移用 Alembic；测试仍用临时 SQLite（同一套仓储接口），生产 Postgres——用 SQLAlchemy Core + JSON 类型抹平两边差异。
- **不做**全表化（tasks/blocks 每行一条）：改造量是 2–4 周且高风险，收益在 100 人以内不明显；先用「JSONB + 定期归档」把单文档控制在 1 MB 内（§5.5），真有性能问题再拆。

### D3 进程形态：api + worker + postgres + caddy 四个容器

- `api`：只处理请求；写操作仍走 `BEGIN IMMEDIATE` 等价物（`SELECT ... FOR UPDATE` 锁 `user_state` 行）。
- `worker`：`jobs`/`outbox` 轮询（`FOR UPDATE SKIP LOCKED`），负责超时结算、归档、每日复盘、周报、通道重试、备份自检；`main.py` 里的三个后台循环删除。
- 暂不引入 Redis/Celery：给 2–20 人用纯 DB 队列足够，少一个组件少一处故障。

### D4 通道：QQ 机器人优先，微信公众号可选，二者都按「一个应用 + 多用户绑定」设计

- QQ：官方机器人 WebSocket 长连接，**不需要公网回调、域名、备案**（`docs/qqbot-c2c-api-spec.md:341` 已确认），部署到云上最省事；你已有的 AppID 直接服务所有用户。
- 微信：一个公众号/测试号，openid 众多；每用户独立绑定码。限制要写进设计：被动回复 5 秒、客服消息 48 小时窗口、个人订阅号接口权限有限。
- 引导里二选一：QQ（默认推荐）或微信（标注「需公众号可用，实验性」）；两者都支持 = 同一套 `channel_identities` 表，不写两套绑定逻辑。

### D5 DeepSeek：每用户自己的 key 为主，站长共享额度为辅

- `assistant_configs.api_key` 用 `MASTER_KEY`（Fernet）加密存 DB，接口只返回 `sk-…abcd`；解密只在调用瞬间发生，不写日志。
- 默认要求用户填自己的 key（引导第 5 步，带「测试连接」）；也允许切换「用站长的 key」并受每日调用上限约束。
- 原「key 只存本机、不进服务端」的铁律作废（托管版必然要进服务端），改为「加密 + 仅本人可读写 + 永不回显 + 不进日志」。

### D6 托管形态：云 VPS（香港/新加坡轻量 2C4G，Ubuntu 24.04）

- 域名复用已买的 `studydazi.top`（`plan2.` 子域），Caddy 自动 HTTPS。
- 大陆服务器需备案；微信「服务器配置」对域名备案也有实际要求，所以**先 QQ、后微信**能把合规不确定性隔离掉。
- 家里电脑保留「本地模式」自用与开发调试；`cloudflared` 只作为备用入口保留文档，不再作为主链路。

### D7 客户端：手机优先，桌面精简为「查看 + 编辑」同构页面

- 同一套 Flutter 代码，Android 为主；Windows 保留现有宽屏布局，但去掉开机自启/隧道/本地数据目录这些「单机时代」的耦合。
- 手机承担：登录、引导、通知、周视图、随手记录、助手对话；桌面承担：大屏周课表、批量整理、配置与备份导出。
- 更新：服务器托管 APK + `/api/v1/app/latest`（`releases.py` 已有），签名密钥离线保管。

---

## 5. 数据模型

### 5.1 表清单（`server/app/migrations/`，Alembic）

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `users` | id uuid, username citext unique, password_hash(Argon2id), display_name, role(admin/member), status, onboarding jsonb, timezone, created_at, last_login_at | 通用化核心 |
| `invites` | code_hash, note, created_by, expires_at, used_by, used_at | 邀请制注册 |
| `devices` | id uuid, user_id, name, platform, token_hash, created_at, last_seen_at, revoked_at | 令牌只存 sha256 |
| `user_state` | user_id pk, body jsonb, revision int, size_bytes, updated_at | 业务状态（沿用现有 dict 结构） |
| `operations_log` | user_id, operation_id, device_id, request_hash, response jsonb, created_at, PK(user_id, operation_id) | 幂等重放，按人隔离 |
| `events` | user_id, revision, kind, payload jsonb, recorded_at, PK(user_id, revision) | 客户端拉取/通道通知 |
| `channel_identities` | id, channel(qq/wechat), external_id, user_id, display_name, bound_at, last_seen_at, unique(channel, external_id) | 一个 IM 账号映射一个用户 |
| `channel_bind_codes` | code_hash, user_id, channel, expires_at, used_at, attempts | 6 位数字/一次性/10 分钟 |
| `outbox` | id, user_id, channel, kind, payload jsonb, status(pending/sending/sent/failed/dead), attempts, next_at, msg_seq, error | 每用户发件箱（QQ 主动消息配额、微信 48h 窗口都靠它） |
| `jobs` | id, kind, user_id null, run_at, status, payload, attempts, last_error, unique(kind, key) | 后台任务（超时结算/复盘/归档/备份） |
| `assistant_configs` | user_id pk, base_url, model, api_key_cipher, key_hint, daily_limit, confirm_first, persona_id, persona jsonb, updated_at | 含人格卡 |
| `assistant_messages` | user_id, role, text, image_path, status, created_at | 保留 90 天 |
| `assistant_drafts` | id, user_id, message_id, operations jsonb, status(pending/applied/dismissed/undone), expires_at, undolog jsonb | 15 分钟过期 |
| `assistant_memories` | id, user_id, kind, text, tags[], source_msg_id, created_at, last_used_at, pinned | 上限 200 条/人 |
| `assistant_usage` | user_id, day, calls, tokens_in, tokens_out, cost_micros, PK(user_id, day) | 限额与成本 |
| `assistant_pending_questions` | id, user_id, question, options jsonb, expires_at | 澄清式追问 |
| `materials` | id, user_id, name, path, bytes, created_at | 文件落在 `users/<uuid>/materials/` |
| `audit_log` | id, actor_user_id, action, target, detail jsonb, created_at | 管理操作留痕 |
| `app_releases` | version, platform, url, sha256, notes, created_at | APK 分发 |

### 5.2 `user_state.body` 结构

沿用现有 `initial_state()`（projects/sleeps/tasks/blocks/sessions/feedbacks/waiting_checks/reviews/proposals/settings/memories 等），只做三处调整：

1. `settings` 里去掉个人默认时区，改为注册时用设备时区初始化，`timezone` 进 `users` 便于查询；
2. `memories` 仅保留「助手记忆」的轻量副本或直接迁到 `assistant_memories`（二选一，推荐后者，方便分页/删除）；
3. 新增 `state_version`（结构版本号，便于以后加字段），`body` 内不存任何密钥。

### 5.3 每用户状态读写

```
repo.read(conn, user_id) -> (state, revision)      # SELECT body FROM user_state WHERE user_id=$1 FOR UPDATE
repo.write(conn, user_id, state, expected_rev)    # UPDATE ... WHERE revision=expected_rev（乐观锁）
repo.apply_operation(conn, user_id, device_id, op) # 事务内：校验幂等 → domain.apply → revision+1 → 写 events/operations_log → 归档触发
```

并发：同一用户的写操作串行（行锁）；不同用户互不阻塞。客户端并发提交时，`expected_rev` 冲突返回 `REVISION_CONFLICT`，客户端重拉快照（现有行为，保留）。

### 5.4 迁移与初始化

- `tools/migrate-v1-to-v2.py`（在 VPS 上跑，输入旧 SQLite 的只读副本）：
  1. 创建 owner 用户（用户名/密码来自交互或环境变量）；
  2. 原样导入 `document.body` 为 `user_state`（revision 保留），`operations`/`events` 补 `user_id` 后导入；
  3. `devices`：把旧 `token_hash` 原样迁入，手机无需重新登录即可连新域名；
  4. 复制 `materials/`、`memes/` 到 `users/<id>/`，路径改相对；
  5. 旧 QQ/微信绑定 → `channel_identities`；旧 `wechat.json`/`qwen.json`/`qq.json` 的模型与 key → `assistant_configs`（加密）；
  6. 校验脚本：逐字段 diff 旧快照 vs 新快照（除时间戳/版本号），数量对不上就中止。
- 切换：新域名并行跑 2 周只读观察 → 手机改「服务地址」→ 旧隧道保留回滚 → 下线 watchdog。

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
| POST | `/api/v1/auth/register` | {invite_code, username, password, device:{name,platform}} → token + user |
| POST | `/api/v1/auth/login` | {username, password, device} → token + user |
| POST | `/api/v1/auth/refresh` | （可省）令牌滚动：每次登录/周活跃延长有效期 |
| POST | `/api/v1/auth/logout` | 吊销当前设备 |
| GET | `/api/v1/me` | 用户信息 + onboarding 进度 |
| PATCH | `/api/v1/me` | 显示名、时区、onboarding 进度 |
| POST | `/api/v1/me/password` | 改密码（吊销其他设备） |
| GET/DELETE | `/api/v1/me/devices` | 设备列表 / 吊销 |
| ADMIN | `python -m app.admin invite --note 师弟` | 生成邀请码；也可 `/api/v1/admin/invites`（admin 角色） |

### 6.2 安全基线

- 密码：Argon2id（`argon2-cffi`），最少 10 位；登录失败 5 次/10 分钟/IP+用户名 限流，10 次锁 15 分钟。
- 令牌：32 字节随机 base64url，DB 存 sha256；比较用 `hmac.compare_digest`；可疑时一键吊销全部设备。
- 传输：仅 HTTPS（Caddy 自动证书），HSTS；禁止明文 HTTP 端口对外。
- 响应头：`X-Content-Type-Options`、`Referrer-Policy`、严格 CORS（App 不需要浏览器跨域）。
- 日志：绝不打 token、密码、API key、消息正文；审计日志只记动作与目标 id。
- 限流：每用户 120 req/min（登录/LLM/上传单独更严），每 IP 600 req/min；上传单文件 20 MB、单用户每日 100 MB。
- 隐私：提供「导出我的全部数据」（JSON+素材 zip）与「删除账号」（30 天冷静期后硬删，含备份标记）；站长 CLI 默认只能看用户列表与用量，看不到日程正文（真要看需显式 `--with-content` 并写审计）。

### 6.3 客户端

- 登录页：服务地址（托管版内置默认，可改）→ 用户名/密码 → 记住设备；注册页填邀请码。
- 设置页：账号、设备管理、修改密码、退出登录、导出数据、删除账号。
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

### 7.2 隔离测试（进 CI，必须全绿）

`server/tests/test_tenancy.py`：

1. 用户 A、B 各建任务；A 的 snapshot 不含 B 的任何 id；
2. A 用 B 的 task_id / block_id / material_id / message_id / draft_id 调每个接口 → 一律 404（不是 403，避免探测）；
3. 未认证请求全部 401；过期/吊销令牌 401；
4. 通道：B 的 openid 发消息不会写进 A 的对话，也不会触发 A 的提醒；
5. 助手：B 无法读取/覆盖 A 的 `assistant_configs`、记忆、用量；
6. 文件：跨用户下载/删除素材 404；
7. 配对码：A 的码被 B 使用时绑定到 A 或直接失效（按设计：码只属于 A，B 使用无效）。
8. 并发：A、B 同时提交 operation，各自 revision 正确、互不串行。

> 建议加一条「脏检查」：测试里遍历所有路由，断言每个非 public 路由都声明了 `AuthContext`，防止以后新增接口忘记鉴权。

### 7.3 威胁模型（写进文档，不夸大）

| 威胁 | 处理 |
| --- | --- |
| 陌生人注册 | 邀请码 + 注册限流 |
| 猜绑码 | 6 位数字 + 10 分钟 + 3 次失败作废 + 只能绑定自己账号（码由服务端按 user 生成，不暴露是否有效） |
| 撞库 | Argon2id + 登录限流 + 密码策略 |
| 越权 | 上述仓储边界 + 交叉测试；前端不做隐式信任 |
| 密钥泄露 | Fernet 加密 + 权限最小化 + 不进日志 + 可一键轮换（MASTER_KEY 版本化） |
| 恶意图片 URL | 只允许 QQ CDN 域名白名单 + 限大小 + 只解析不执行；禁止内网/非 https |
| IM 消息伪造 | QQ/微信签名与回调校验沿用；未知 openid 一律走「请先绑定」 |
| 滥用 LLM | 每日限额 + 全局熔断 + 超时 + 用户级并发 1 |
| 数据丢失 | 每日备份 + 每月恢复演练 + 迁移前快照 |

---

## 8. 通道层（QQ / 公众号一对多）

### 8.1 统一抽象

```
channels/base.py     # send_text/send_image/被动回复窗口/配额/去重键
channels/qq.py       # 改造现有 qq.py：AppID 级凭据，openid 级身份
channels/wechat.py   # 改造现有 wechat.py：公众号级凭据，openid 级身份
channels/binding.py  # 绑定码生成/校验/解绑；身份查询
channels/dispatch.py # 入站消息 → 用户 → 助手管线；出站统一写 outbox
```

- **凭据是站长级**（QQ AppID/Secret、公众号 AppID/Secret/Token），存 `app_config`（加密、仅 admin 可改，或环境变量）；**用户级只有身份绑定**。
- 每人最多绑一个通道（可按需允许两个都绑，但提醒只走「主通道」避免重复；默认绑一个）。

### 8.2 绑定流程（两个通道同一套）

```
App 设置页「绑定 QQ」→ POST /channels/bind-code {channel} →
   服务端生成 6 位码（10 分钟、仅本人、一次性），显示「把 绑定 123456 发给机器人」
→ 用户在 QQ/微信里发：绑定 123456
→ 通道入站 → dispatch 查 code_hash → 绑定 channel_identities → 回「绑好了，我是你的大肥鱼」
→ App 轮询/长连收到绑定成功 → 引导前进一步
```

- 未绑定用户发消息：回一句「先来 App 里拿绑定码」+ 下载地址（QQ）/公众号关注提示（微信）。
- 解绑：App 内一键解绑（同时清掉该通道的提醒发件箱）；旧 openid 再来消息按未绑定处理。
- 重复绑定：同一 openid 换绑到另一个账号需先解绑并二次确认；防止「师弟的号被绑到我这里」。

### 8.3 一个公众号服务多用户（需求 4）

- 公众号只作为「出口/入口」，不做账号体系；`channel_identities(wechat, openid)` → 用户。
- 每个用户的消息、记忆、日程、提醒都按 `user_id` 落库，天然不串台。
- 公众号限制落到实现：
  - 被动回复必须 5s 内 → 助手异步处理后无法再被动回复，只能落 outbox 走客服消息；
  - 客服消息仅 48h 窗口 → 提醒超过窗口会失败，outbox 标记 `window_closed` 并降级到 App 本地通知；
  - 个人订阅号无客服消息权限时 → 明确提示「微信通道只能收不能主动推」，引导用 QQ 或 App 通知。
- 同一套 `outbox` 处理 QQ 主动消息的每日配额（现有 `qq.py` 的伪被动/主动回退逻辑保留，但按用户配额计数）。

### 8.4 通知与提醒

- 来源：后台任务（session 预计结束、等待检查、每日复盘、周报）→ `outbox`。
- 每用户通知窗口（quiet hours）、主通道、是否开启提醒都在设置里；App 本地通知仍保留（手机离线可用），但会与通道消息去重（同一 `dedupe_key`）。
- 失败重试：指数退避 + 最大次数；耗尽后写 App 内「未送达」列表，不静默丢。

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

- **可自动执行（auto 模式）**：`schedule_new`、`schedule_task`、`move_block`（≤60 分钟，且当天无冲突）、`protect`、`remember`、反馈类（完成/部分完成/中断）。
- **必须确认**：`cancel_task`、`cancel_block`、删除记忆/素材、跨多日重排、移动 >60 分钟、任何 `undo`。
- auto 模式对破坏性操作也不自动执行（需求 6 的「智能」不等于「危险」）。
- 草稿预览：App 展示「将做什么」的 diff（哪段、几点到几点、时长、可撤销），确认后一次事务应用；15 分钟过期。
- 每用户默认 `confirm_first=true`（新用户），老用户迁移保持原设定。

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
| 2 | 账号 | 已登录（注册/登录页引导） | 有令牌 |
| 3 | 服务器 | 托管版默认地址，仅展示 | 自动 |
| 4 | 作息 | 高亮「起床/睡觉/每日复盘时间」 | 保存一次 |
| 5 | DeepSeek | 打开助手设置，填 key → 测试 | 测试成功 |
| 6 | 人格 | 高亮人格卡选择 | 选中或跳过 |
| 7 | 通道 | 高亮「绑定 QQ / 绑定微信」二选一 | 绑定成功或跳过 |
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
    db.py            # SQLAlchemy engine/session/JSON 编解码
    auth.py          # users/invites/devices/tokens
    tenancy.py       # AuthContext、current_user 依赖
    repo.py          # 取代 store.py：state_for/apply_operation/events/outbox
    domain.py        # 不改（纯函数，加 user 无关注释）
    planning.py adjustments.py execution.py maintenance.py  # 不改
    channels/        # qq.py wechat.py binding.py dispatch.py base.py
    assistant/       # service.py persona.py intents.py memories.py eval.py
    routers/         # auth.py sync.py operations.py assistant.py channels.py admin.py
    worker.py        # jobs/outbox 处理循环
    admin.py         # CLI：invite/reset/disable/export
    migrations/      # Alembic
  tests/             # 现有 167 + tenancy/auth/sync/migration 新测试
apps/planner/lib/
  auth/              # login_page.dart session.dart
  onboarding/        # coach_overlay.dart steps.dart keys.dart
  assistant/persona_page.dart memories_page.dart
  week/              # week_strip.dart week_heatmap.dart day_agenda.dart
  settings/          # account/devices/channel_bind/onboarding 入口
tools/
  deploy/            # docker-compose.yml Caddyfile backup.ps1 restore-drill.md
  migrate-v1-to-v2.py
docs/plans/v2-multiuser-plan.md（本文件）
```

迁移顺序（每步可独立合并、保持测试全绿）：

1. **DB 骨架**：新增 `db.py/auth.py/repo.py` 与迁移；`store.py` 保留兼容层，旧接口照旧（测试仍绿）。
2. **每用户状态**：`user_state` 落地；`/operations`、`/snapshot` 走新仓储；引入 `PLANNER_AUTH=local` 兼容单机。
3. **认证**：注册/登录/设备/邀请码；手机端加登录页；旧 device token 迁入（重登即可）。
4. **通道多租户**：`channel_identities` + 绑定码；QQ 先改，微信后改；发件箱按用户。
5. **助手多租户**：config/key 加密、人格卡、记忆、澄清、评测集。
6. **worker**：把后台循环迁走；删 `main.py` 三个循环。
7. **客户端**：引导、周视图、账号设置、bug 修复。
8. **部署与迁移**：Compose、Caddy、备份、APK 分发；旧数据导入；灰度。

---

## 13. 阶段计划与验收

| 阶段 | 内容 | 工期（业余） | 验收 |
| --- | --- | --- | --- |
| P0 决策与地基 | 拍板 §16；买 VPS；域名子域；Compose 跑通；分支/备份策略 | 1–2 天 | 空环境 `curl /health` 200；备份可恢复 |
| P1 认证与多租户 | DB schema、repo、auth、invites、devices、每用户状态、迁移脚本、tenancy 测试、P0 后端修复 | 5–7 天 | 两账号交叉全 404；旧数据导入一致；pytest ≥190 |
| P2 助手与通道 | 通道身份/绑定/发件箱；助手 config/persona/memory/usage；澄清；评测集；P0/P1 通道修复 | 4–6 天 | 两用户 QQ/微信互不串台；评测 ≥90%；key 加密可验 |
| P3 客户端 | 登录/注册、引导 10 步、人格卡页、周视图重做、同步/提醒/跨午夜 bug、桌面精简 | 5–7 天 | 360dp 周视图可用；引导可跳过/续播；flutter test ≥100 |
| P4 上线 | 部署、监控、备份演练、APK 签名分发、邀请码给师弟、灰度两周 | 3–4 天 | 师弟独立注册使用一周无串台/丢数据；RTO ≤1h |

关键路径：P1 → P2（通道可并行）→ P3（周视图/引导可与 P2 并行）→ P4。总日历约 4–5 周。

---

## 14. 测试与验收清单

- 后端：现有 167 + 认证/租户/同步/迁移/评测 ≈ 220+；`pytest -q` 全绿。
- 客户端：`flutter test`（现有 77 + 周视图/引导/登录）；`flutter analyze` 零问题。
- 多租户：§7.2 八条 + 「所有非 public 路由都有鉴权」遍历断言。
- 迁移：快照 diff（忽略 revision/时间戳）+ 素材数量 + 令牌可用性。
- 通道：QQ 两账号真机（师弟号）各发一条，确认归属；微信同（若启用）。
- 助手：意图评测离线 100% 无非法写入、在线 ≥90%；破坏性操作一律要确认。
- 周视图：360dp/390dp/430dp 三档截图核对；点击命中；空状态；捏合边界。
- 备份：`pg_dump` → 新库恢复 → snapshot 对比一致；每月演练。
- 压测：20 用户 × 100 operations，p95 `/snapshot` < 300ms，无跨用户错乱。
- 安全：secret 扫描（git 无 key）、依赖审计、越权/限流/日志检查。
- 隐私：导出/删除账号可用；日志抽查无正文/密钥。

---

## 15. 部署与运维

- Compose 四容器：`postgres:16`、`api`（uvicorn 2 worker）、`worker`、`caddy`；卷 `pgdata`、`data`（用户文件）、`caddy`。
- 域名 `plan2.studydazi.top`；Caddy 自动证书；只开放 443。
- 备份：每日 03:00 `pg_dump -Fc` + `data/` 增量 → age 加密 → rclone 到 Backblaze B2；保留 14 日 + 8 周；恢复脚本 `tools/deploy/restore.ps1`。
- 监控：`/healthz`（含 DB 检查）由外部探活；异常（连续 3 次失败/磁盘 >80%/备份失败/LLM 错误率 >20%）通过 QQ 机器人给自己发消息；日志 journald 轮转。
- 发布：`tools/build-android.ps1` 产物 → 上传到 `/srv/timer/releases` → 更新 `app_releases`；APK 签名 keystore 离线两份备份（不入 Git）。
- 成本：VPS ¥60/月、B2 ¥10/月、域名已有、TLS 免费、deepseek 各付；2–20 人规模足够。
- 迁移期：旧隧道与 watchdog 保留只读；手机改地址后观察 2 周再下线。

---

## 16. 风险与回滚

| 风险 | 概率 | 应对 |
| --- | --- | --- |
| 公众号注册/认证/备案卡住 | 中 | QQ 先行；微信通道代码就绪但不作为默认；引导文案明说 |
| QQ 机器人对多用户/主动消息风控 | 中 | 按用户配额 + 被动优先 + 失败降级到 App 通知 |
| 数据迁移丢历史 | 低 | 双跑 2 周、快照 diff、旧数据保留 30 天、可回滚 |
| 云主机故障 | 低 | 每日备份 + 重建脚本；RTO ≤1h |
| DeepSeek 费用/滥用 | 中 | 每人 key 默认 + 每日限额 + 全局熔断 |
| 手机后台被杀导致提醒不准 | 中 | 服务端通道提醒 + 本地闹钟双路 + outbox 未送达列表 |
| 改造面过大延期 | 中 | 阶段化交付；P1 完成即可先让师弟用「无助手」基础版 |

回滚：v1 数据与隧道保留；DNS 切回即恢复；新库只读导出回 v1 格式脚本随迁移脚本提供（一次性）。

---

## 17. 待拍板（6 项，已给推荐）

1. **服务器地区**：香港/新加坡（推荐，免备案、QQ 直连；微信 48h 窗口仍受限于公众号权限）还是大陆（需备案）？
2. **公众号节奏**：先只做 QQ（推荐）还是同步申请公众号？公众号主体用个人订阅号可以吗（客服消息权限有限）？
3. **DeepSeek 归属**：每人自带 key（推荐，默认）还是站长统一 key + 限额？两者都支持是否要？
4. **登录**：邀请码 + 用户名密码（推荐）还是手机号验证码（需短信服务商）？
5. **数据保留**：消息 90 天、日程永久、已完成任务 180 天后归档（推荐）；是否需要「导出全部数据」按钮？
6. **自动执行默认值**：新用户默认「先确认」（推荐）还是「直接执行」？老用户迁移保持现有设置？

---

## 18. 下一步（你确认后我按这个顺序动手）

1. 按 §17 拍板 → 建 `v2` 分支、写 ADR（本文件转正）。
2. P0 阶段：VPS + Compose + 空库跑通 + 备份演练（半天）。
3. P1：认证/租户/迁移（先让自己旧数据在新系统跑起来，作为第一个真实用例）。
4. P2/P3 并行：通道多租户、助手 2.0、引导、周视图。
5. 修 §11 的 P0，再逐级清 P1。
6. 给师弟发邀请码，灰度两周，补文档（HANDOFF 铁律改写 + STATUS 进度 + 部署手册）。
