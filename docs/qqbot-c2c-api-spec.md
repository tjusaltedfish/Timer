# QQ 官方机器人（QQ Bot）私聊 C2C 接口契约 — Python 客户端实现规格

> 适用范围：单用户私聊（C2C）通道，HTTP OpenAPI + WebSocket 长连接。不含群聊 / 频道 Guild / QQ 频道机器人。
> 抓取时间：2026-10-21。文档站：<https://bot.q.qq.com/wiki/>
>
> **标记约定**
> - 📄 = 官方文档原文明确写了（附 URL）
> - ⚠️ = 社区说法 / 我的推断 / 文档自相矛盾处，**不确定，落地前需实测**
> - ❌ = 明确「未查到」

---

## A. 鉴权

### A1. 获取 AppAccessToken

- 📄 请求：`POST https://api.bot.qq.com/app/getAppAccessToken`，`Content-Type: application/json`。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html>
- 📄 请求体字段名是 **`appId` / `clientSecret`**（驼峰，不是 `app_id` / `app_secret` / `client_secret`）：
  ```json
  {"appId": "APPID", "clientSecret": "CLIENTSECRET"}
  ```
  <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html>
- 📄 返回：`access_token`（string）、`expires_in`（number，**单位秒，「目前是 7200 秒之内的值」**）；示例里 `expires_in` 实际是字符串 `"7200"`，解析时按 `int()` 容错。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html>
- 📄 该接口失败时 **HTTP 仍返回 200**，错误在响应体 `code` / `message`：「请优先依据 `code` 判断请求是否成功，不要只依赖 HTTP 返回码」。
  错误码：`100001` Too many requests、`100007` appid invalid（含被封禁/已删除）、`100016` invalid appid or secret、`10004` 机器人不存在。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html>
- 📄 有效期规则原文：「每次请求不会刷新新的 `access_token`，在有效期内重复获取会返回相同的值」「在上一个 `access_token` 接近过期时间 `60` 秒内，获取 `access_token` 时，会获得一个新的 `access_token`，老的 `access_token` 在这个 `60` 秒内仍然有效」。
  → 正确做法：本地缓存 token，留 ≥60s 余量再刷新；不要每个请求都去换 token（也不会变）。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html>
- 📄 `AppSecret` 定位：「用于在 `oauth` 场景进行请求签名的密钥」；老的 `Token` 鉴权方式「已废弃，请使用更安全的 `Access Token` 鉴权方式」。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/getting-started.html>

### A2. 业务接口的 Authorization 头

- 📄 确切格式：**`Authorization: QQBot ACCESS_TOKEN`**（原文「名称 Authorization，必填，格式值：`QQBot ACCESS_TOKEN`」，示例 `curl -H 'Authorization: QQBot ACCESS_TOKEN'`）。
  <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html> · <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>
- 📄 前缀就是 `QQBot`，**不是 `Bearer`**；前缀与 token 之间一个空格；`QQBot` 后没有冒号。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>
- ⚠️ 「`QQBot` 前缀大小写是否被服务端严格校验」文档未写；按文档示例原样写 `QQBot`（不是 `qqbot` / `QQBOT`）。
- 📄 发业务请求还要 `Content-Type: application/json; charset=utf-8`（curl 示例如此）。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>
- ❌ **未查到** v2 业务接口需要 `X-Union-Appid` 或 `X-Bot-Appid`。文档里 v2 OpenAPI 的必填头只有 `Authorization`（`X-Bot-Appid` 只出现在 Webhook 回调的**请求头**里，是腾讯发给你的，不是你要发的）。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/event-emit.html>
- 📄 统一域名 **`https://api.bot.qq.com`**；2026-08-10 起「所有接口调用域名统一为 `api.bot.qq.com`」，老的 `api.sgroup.qq.com` 写法已过时。<https://bot.q.qq.com/wiki/develop/api-v2/changelog.html>

### A3. 常见鉴权错误码

- 📄 `11241` ErrorWrongToken（缺 token）、`11243` ErrorCheckTokenNotPass（token 错/失效）、`11251`/`11261`/`11275` ErrorWrongAppid、`11253`「该机器人应用未获得调用该接口的权限，需要向平台申请」、`11265` 机器人被封禁。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>
- 📄 HTTP `401` = 认证失败（token 无效/过期）。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>
- ⚠️ WebSocket 的 Identify 用的是**同一个** AppAccessToken（格式 `QQBot {AccessToken}`），token 过期后长连接不会立即断，但下一次 HTTP 调用会 401/11243；社区经验是 token 过期还会导致 `create session error`。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html> · <https://bot.q.qq.com/wiki/bot_FAQ/>

---

## B. WebSocket 网关

### B1. 拿网关地址

- 📄 `GET https://api.bot.qq.com/gateway`（请求头带 `Authorization: QQBot {ACCESS_TOKEN}`），返回 `{"url": "wss://api.bot.qq.com/websocket/"}`。<https://bot.q.qq.com/wiki/develop/api-v2/openapi/wss/url_get.html>
- 📄 分片版：`GET https://api.bot.qq.com/gateway/bot`，返回 `url` / `shards` / `session_start_limit{total, remaining, reset_after, max_concurrency}`（示例 `total:1000, remaining:1000, reset_after:86400000, max_concurrency:1`）。<https://bot.q.qq.com/wiki/develop/api-v2/openapi/wss/shard_url_get.html> · <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/event-emit.html>
- 📄 单机器人只做 C2C：不要分片，`shard` 传 `[0, 1]`。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>

### B2. 各 opcode 载荷（字段名逐字）

- 📄 上下行统一信封：`{"id": "<event_id>", "op": 0, "d": {}, "s": 42, "t": "GATEWAY_EVENT_NAME"}`；`id` 事件 id、`s` 序列号、`t` 事件类型、`d` 事件体。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/payload.html>
- 📄 **op 10 Hello（服务端→客户端，连接后立刻收到）**：`{"op":10,"d":{"heartbeat_interval":45000}}`，**单位毫秒**。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 **op 2 Identify（客户端→服务端）**：
  ```json
  {"op":2,"d":{"token":"QQBot {AccessToken}","intents":33554432,"shard":[0,1],
   "properties":{"$os":"windows","$browser":"my_lib","$device":"my_lib"}}}
  ```
  字段说明：`token` 格式「`QQBot {AccessToken}`」；`intents` 见 payload 页；`shard` 两元素数组；`properties`「目前无实际作用」。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 **READY（鉴权成功）**：`{"op":0,"s":1,"t":"READY","d":{"version":1,"session_id":"...","user":{"id":"...","username":"...","bot":true},"shard":[0,0]}}`，`session_id` 要存下来给 Resume 用。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 **op 1 Heartbeat（客户端→服务端）**：`{"op":1,"d":251}`，**`d` 是客户端收到的最新 `s`（不是对象，是数字）**；首次连接（还没收到任何 dispatch）传 `null`。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 **op 11 Heartbeat ACK（服务端→客户端）**：`{"op":11}`，收到即认为心跳成功。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 **op 6 Resume（客户端→服务端，重连后）**：`{"op":6,"d":{"token":"QQBot {AccessToken}","session_id":"...","seq":1337}}`；`seq` 传最后收到的 `s`（原文「推荐开发者在处理过事件之后记录下 `s`」）。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 **RESUMED**：补发完毕后下发 `{"op":0,"s":2002,"t":"RESUMED","d":""}`。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 **op 7 Reconnect**：OpCode 表定义「服务端通知客户端重新连接」，`d` 无内容；收到后应「关掉当前连接 → 重新连 gateway → 发 op 6 Resume」。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/payload.html>
- 📄 **op 9 Invalid Session**：「当 identify 或 resume 的时候，如果参数有错，服务端会返回该消息」；收到后应丢弃 session 重新 Identify。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/payload.html>

### B3. 心跳间隔处理规则

- 📄 间隔**由服务端 Hello 的 `heartbeat_interval` 决定**（示例 45000ms），不要硬编码 41s/45s。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- ⚠️ 文档未写「多久没收到 op 11 判定为掉线」。社区/各 SDK 的通行做法：连续 1~2 个心跳周期没收到 ACK（或直接靠 TCP 断开 + ping 超时）就主动重连并发 Resume；这是推断，非文档规定。
- ⚠️ 文档未规定心跳要不要加随机抖动（jitter）；主流实现是固定间隔，不加抖动即可。

### B4. WebSocket 关闭码与处置

- 📄 完整表：`4001` 无效 opcode、`4002` 无效 payload、`4006` 无效 session id（可 identify）、`4007` seq 错误（可 identify）、`4008` 发送过快（可 resume）、`4009` 连接过期（可 resume）、`4010` 无效 shard、`4011` guild 过多、`4012` 无效 version、`4013` 无效 intent、`4014` intent 无权限、`4900`~`4913` 内部错误（重连）、`4914`「机器人已下架，只允许连接沙箱环境」（不可连）、`4915`「机器人已封禁」（不可连）。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 处置原则原文：「4009 重新 resume；4914/4915 不可连；其他重新 identify」。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- ⚠️ 不要对 4900~4913 做立即无限重试，要指数退避（文档只说「内部错误」，未规定退避策略）。

### B5. token 格式的文档矛盾（重要）

- 📄 新页 `websocket.html` 写 `token` 格式为 **`QQBot {AccessToken}`**。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- 📄 旧页 `reference.html` 写「`token` 是创建机器人的时候分配的，格式为 `Bot {appid}.{app_token}`」。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/reference.html>
- ⚠️ 结论：旧页是频道机器人时代遗留，**以 `QQBot {AccessToken}` 为准**（`access-token.html` 与 `api-call-guide.html` 的 HTTP 鉴权也是这个格式）。用 `Bot {appid}.{token}` 会直接 4006/401 类失败。

---

## C. 收消息

### C1. 事件名与 intent 位

- 📄 事件名（即外层 `t` 字段）：**`C2C_MESSAGE_CREATE`**，含义「用户单聊发消息给机器人时候」。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>
- 📄 对应 intent：**`GROUP_AND_C2C_EVENT (1 << 25)` = `33554432`**。这一位同时覆盖 `C2C_MESSAGE_CREATE`、`FRIEND_ADD`、`FRIEND_DEL`、`C2C_MSG_REJECT`、`C2C_MSG_RECEIVE`、`GROUP_AT_MESSAGE_CREATE`、`GROUP_ADD_ROBOT`、`GROUP_DEL_ROBOT`、`GROUP_MSG_REJECT`、`GROUP_MSG_RECEIVE`。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/payload.html>
- 📄 只要私聊消息，`intents = 33554432` 一位即可（不需要 513）。513 是示例里 `1<<9 | 1<<0`（GUILD_MESSAGES + GUILDS），**跟私聊无关，照抄示例会收不到 C2C 消息**。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html>
- ⚠️ 若想同时收「用户点了关闭主动消息」的开关事件，也只需这一位（`C2C_MSG_REJECT` / `C2C_MSG_RECEIVE` 同样在 1<<25 里），但收到后机器人**没有**主动消息权限——这是用户侧开关，不是你能申请的权限。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/payload.html>

### C2. 是否需要后台单独申请 intent

- 📄 文档原文：「除了 `GUILDS`，`PUBLIC_GUILD_MESSAGES`，`GUILD_MEMBERS` 事件是基础的事件，默认有权限订阅之外，其他的特殊事件，都需要经过申请才能够使用，如果在鉴权的时候传递了无权限的 `intents`，`websocket` 会报错，并直接关闭连接」。
  → 按字面，`1<<25` 属于「需要申请」那一类。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/event-emit.html>
- ⚠️ 但实测/社区普遍反馈：**`1<<25` 对普通机器人默认就是开着的**，不需要在管理端单独申请；申请不上时典型症状是连接被关（关闭码 `4014` intent 无权限）或收不到事件。官方文档没有针对「单聊/群聊事件」单独写申请入口，属**文档缺口**。
- ⚠️ 另一处权威口径（常见问题）写的「开发文档相关接口无权限 → 内邀接口暂未开放申请」，指的是内邀 API，不是消息 intent，别混淆。<https://bot.q.qq.com/wiki/bot_FAQ/>
- 📄 权限被取消后的表现：「在当前连接上不会报错，但是将不会收到对应的事件类型，如果重新连接，则报错」——所以「连得上但收不到私聊」要优先怀疑 intent 权限。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/event-emit.html>

### C3. C2C 事件体字段

事件 `d` 的字段（全部 📄，出处 <https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | **消息 ID。就是要拿去做被动回复的 `msg_id`**（没有单独的 `msg_id` 字段） |
| `author` | User | 发送者，见下表 |
| `content` | string | 文本内容（纯文本消息在此） |
| `timestamp` | string | RFC3339，如 `2026-07-21T10:00:00+08:00` |
| `message_type` | int | 0 普通文本 / 3 结构化卡片 / 101 并行消息 / 102 聊天记录 / 103 引用消息 |
| `message_scene` | object | `{source, ext[]}`，见下 |
| `attachments` | array | 图片/语音/视频/文件，见下 |
| `ark_data` / `msg_elements` | object/array | 卡片/结构化消息，纯文本场景可为空 |

- 📄 原文示例：
  ```json
  {"id":"ROBOT1.0_xxx",
   "author":{"id":"A1B2...","user_openid":"A1B2...","union_openid":"","username":"","bot":false},
   "content":"你好，今天有什么推荐的活动吗？",
   "message_type":0,
   "message_scene":{"source":"default","ext":["msg_idx=REFIDX_...=="]},
   "timestamp":"2026-07-21T10:00:00+08:00"}
  ```
  <https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>

**author（User 对象）**

- 📄 `id`：OpenID；`user_openid`：**单聊场景使用的 OpenID**（发消息的路径参数用它）；`union_openid`：跨应用统一 OpenID，**可能为空字符串**；`union_user_account` 可能为空；`member_openid`：群聊场景使用；`member_role`：member/admin/owner；另有 `username`、`bot`。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>
- 📄 `union_openid` 需要发邮件申请绑定（`qq_bot_api@tencent.com`，主题「申请Union_openid绑定」，要求同一注册主体），**不申请就是空**——所以不要依赖它做用户主键。<https://bot.q.qq.com/wiki/bot_FAQ/>
- ⚠️ 实践上 `author.id` 与 `author.user_openid` 在 C2C 事件里是同一个 OpenID（示例中相同）。稳妥写法：`user_openid = author.get("user_openid") or author.get("id")`。

**message_scene**

- 📄 `source`：`default` = 默认聊天窗口；`ext`：字符串数组，`key=value` 形式，目前有 `msg_idx=`、`ref_msg_idx=`、`auth_token=`，`msg_idx` 用于**去重**。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>

**attachments（收到的图片在这里）**

- 📄 每项：`url`、`filename`、`width`、`height`、`size`、`content_type`（`voice` / `image/jpeg` / `image/png` / `image/gif` / `video/mp4` / `file`）、`voice_wav_url`、`asr_refer_text`。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>
- ⚠️ 用户发表情包/图片时 `content` 通常为空，`message_type` 仍是 0，图片只在 `attachments` 里——文档没有明说「content 为空」，这是推断，实现时要按「content 为空 + attachments 非空」兜底。

### C4. 私聊 vs 群 @ 怎么区分

- 📄 私聊：`t = "C2C_MESSAGE_CREATE"`，有 `author.user_openid`，**没有** `group_openid`。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>
- 📄 群：`t = "GROUP_AT_MESSAGE_CREATE"`（同样是 1<<25 位），多出 `group_openid`、`mentions`，`author.member_openid` 有值，且 `content`「已自动去除@机器人的前缀」；另有 `GROUP_MESSAGE_CREATE`（群内全部消息，一般不推）。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/group_at_message_create.html>
- 📄 判定顺序建议：先看 `t`（最可靠），再用 `group_openid` 是否存在做双保险。同一位 intent 会同时收到两种事件，**必须按 `t` 分流**，否则会把群消息当私聊回。

### C5. 去重

- 📄 「相同 `msg_id` 可能重复推送，开发者需结合 `msg_seq` 做去重」；另有注「需结合 `message_scene.ext` 中的 `msg_idx` 做去重」。→ 用 `d.id`（或 `msg_idx`）做幂等键，重复到达直接丢弃。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/c2c_message_create.html>

---

## D. 发消息

### D1. 接口基础

- 📄 `POST https://api.bot.qq.com/v2/users/{user_openid}/messages`，`Content-Type: application/json; charset=utf-8`，头 `Authorization: QQBot {ACCESS_TOKEN}`。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 接口频率限制：**100 QPS**（主动 + 被动所有类型合计）。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 成功响应：`{"id":"ROBOT1.0_xxx","timestamp":"2026-07-21T10:30:00+08:00","ext_info":{"ref_idx":"REFIDX_xxx=="}}`（`ref_idx` 用于之后再引用这条机器人消息）。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 失败响应：`{"err_code":40034005,"message":"回复消息msg_id已过期","trace_id":"..."}`；「请不要依据 `message` 来判定一个请求是否失败」，用 `err_code`；`trace_id` 对排查有用（HTTP 头里叫 `X-Tps-trace-ID`）。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>
- 📄 HTTP 状态码语义：`200` 成功；`201/202` 表示异步受理成功但**响应体里仍可能是 error body**；`401` 认证失败；`429` 频率限制；`500`/`504` 服务端。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>

### D2. 请求体字段

（全部 📄，出处 <https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>）

| 字段 | 类型 | 说明 |
|---|---|---|
| `msg_type` | int | `0` 文本 / `2` Markdown / `6` 输入中状态 / `7` 富媒体 |
| `content` | string | 文本内容；**传了 `markdown` 后此字段必须为空** |
| `markdown` | object | `{content, ...}`；`template_id` / `custom_template_id` 已废弃；`force_verify_image_resource` 为新增校验开关 |
| `keyboard` | object | 消息按钮 `{id, content:{rows:[{buttons:[...]}]}}` |
| `msg_id` | string | **被动回复**用，取自 `C2C_MESSAGE_CREATE` 事件的 `d.id` |
| `event_id` | string | 与 `msg_id` 二选一；支持 `INTERACTION_CREATE` / `C2C_MSG_RECEIVE` / `FRIEND_ADD` 事件的 `id` |
| `msg_seq` | int | 回复序号，与 `msg_id` 联合；不填默认 `1`；**相同 `msg_id` + `msg_seq` 重复发送会失败** |
| `media` | object | `{file_info: "..."}`，配合 `msg_type=7` |
| `message_reference` | object | `{message_id}` 引用回复：引用用户消息用 `message_scene.ext` 的 `msg_idx`，引用机器人自己的消息用响应的 `ext_info.ref_idx` |
| `is_wakeup` | bool | 互动召回消息标记（见 D6） |
| `input_notify` | object | `{input_type:1, input_second:≤60}`，先发「正在输入」 |

- 📄 发送 `msg_type` 只有 `0/2/7`（另有 `6` 输入中）；接收侧的 `message_type` 才是 `0/3/103`。「图片、视频、语音、文件等附加内容通过 `attachments` 字段携带，不通过 `message_type` 单独表示」。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/type/overview.html>
- 📄 单聊场景能力支持：文本收发 ✅、Markdown **发 ✅ 收 ❌**、图片/视频/语音/文件 收发 ✅、结构化卡片 发 ❌ 收 ✅、Embed ❌、表情表态 ❌、引用 收 ✅。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/type/overview.html>

### D3. 被动回复规则（★ 文档自相矛盾，务必看）

- 📄 页首规则：「被动消息有效时间 **60 分钟**，每个消息最多回复 **4 次**」（单聊）。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 概述页同样写：单聊 **60 分钟 / 每条消息可回复 4 次**；群聊 5 分钟 / 5 次；频道 5 分钟。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html>
- 📄 **但是**同一页的字段表里 `msg_id` 写的是「从 `C2C_MESSAGE_CREATE` 等事件的 `d.id` 获取，**5 分钟内有效**」。→ 同一页面 60 分钟 与 5 分钟 冲突。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- ⚠️ 落地建议：**收到就立刻回**（秒级），永远不要依赖 60 分钟这个上限；超时错误码是 `40034005`（msg_id 已过期）/ `304027`（MSG_EXPIRE）/ `40034103`（消息ID已过期）。
- 📄 `msg_seq` 用法：同一条用户消息要回多条时，`msg_id` 不变、`msg_seq` 递增（1,2,3,4）；重复的 `msg_id`+`msg_seq` 会被拒（`40054005` 消息被去重）。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 超过 4 次 / 超时的错误码：`40034128`「被动回复时间或次数超限」。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- ⚠️ 「4 次」是**每条用户消息**的额度，不是每分钟；文档没有说「一批消息合并计算」。

### D4. 主动消息规则

- 📄 可以不带 `msg_id` 直接发（这就是主动消息），「主动消息：无任何条件」——但有下面这些限制。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html>
- 📄 **用户可以在客户端关掉「允许主动发送」开关，关闭后主动消息发送失败**；用户开关动作会通过 `C2C_MSG_REJECT` / `C2C_MSG_RECEIVE` 事件（同在 1<<25）通知你。失败错误码 `40054013`「用户拒收消息」。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html> · <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/payload.html>
- 📄 **配额（单聊 / HTTP 通道）**：
  - 企业认证：`10` 条/秒（bot 维度）、`20` 条/分钟（单用户关系维度）、`1000` 条/用户/天
  - 个人认证：同上
  - 未认证：`5` 条/秒、`30` 条/分钟、`1000` 条/用户/天
  <https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html> · <https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 超配额错误码：**`40034100`「主动消息发送超过频控限制」**；无权限：**`40034105`「主动消息发送失败，无权限」**；HTTP `429` 频率限制。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 还有一个隐藏前提：**`40054004`「无好友关系」→ 排查建议「请先添加好友后再发送私信」**。也就是说主动私信在部分情况下要求用户先把机器人加为好友/添加使用。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- ❌ **未查到**「主动消息需要在后台单独申请某个权限开关」的明确文档；文档只写认证等级决定配额（`40034105` 的存在说明确实有权限维度）。

### D5. 常见错误码（C2C 发送必背）

| 错误码 | 含义 | 处置 |
|---|---|---|
| `11243` | token 校验不通过 | 重新取 token |
| `40034005` / `304027` / `40034103` | `msg_id` 已过期 / 回复消息过期 | 降级成主动消息（若无权限则放弃） |
| `40034128` | 被动回复时间或次数超限 | 同上 |
| `40034100` | 主动消息超频控 | 退避，按 1000/天/人 预算 |
| `40034105` | 主动消息无权限 | 提示用户开启「允许主动发送」 |
| `40054004` | 无好友关系 | 让用户先添加机器人 |
| `40054005` | 消息被去重（msg_id+msg_seq/内容重复） | 换 `msg_seq` |
| `40054013` | 用户拒收消息 | 停止推送，等 `C2C_MSG_RECEIVE` |
| `40034006` | 消息内容违规 | 改内容 |
| `40054007` / `40054018` | 消息长度超限 / 消息过长或异常 | 分条 |
| `304080` | 文件信息无效（file_info 过期/错端点） | 重新上传 |
| `22006` | 类型与内容不匹配（如 `msg_type=2` 却没 `markdown`） | 修 body |
| `40034024` | `msg_id` 无效或越权 | 确认 `d.id` 与 `user_openid` 配对 |
| `1100100` / `1100101` / `1100103` | 安全打击：被限频 / 内容敏感请修改 / 安全打击 | 不要重试，改内容 |
| `1100308` | 触发频道内限频 | 退避 |
| `304023` / `304024` | 推送/回复「异步调用成功，等待人工审核」 | 不是失败，等 `MESSAGE_AUDIT` 事件 |
| `304018` | SESSION_NOT_EXIST，机器人没连上 gateway | 先建长连接 |
| `50055002` | 发送异常稍后重试 | 指数退避重试 |

出处：<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html> · <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>

### D6. 互动召回（想让「用户不说话也能推」时先看这个）

- 📄 带 `is_wakeup=true` 的召回消息：用户主动对话后 **30 天内**可下发，周期为「当天、1-3 天、3-7 天、7-30 天，合计 **4 个周期**」，**每周期 1 条**；`40034122` 召回已达区间上限、`40034123` 不支持召回。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html> · <https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>
- 📄 你的定时提醒场景：如果只是普通主动消息，走 D4 的 1000/天/人 配额即可；`is_wakeup` 是额外的一层「召回」营销能力，别混用。

### D7. 撤回

- 📄 `DELETE https://api.bot.qq.com/v2/users/{user_openid}/messages/{message_id}`；「发送超过 2 分钟不可撤回」。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html>

---

## E. 图片 / 富媒体

### E1. 发送图片的两条路

- 📄 **路线 1（推荐给表情包）**：先上传拿 `file_info`，再用 `msg_type=7` + `media.file_info` 发消息。两步。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>
- 📄 **路线 2（省一步）**：上传时带 `srv_send_msg=true`，平台直接发出去，返回里带消息 `id`；**代价是占主动消息频次**。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 **不能**直接把图片 URL 塞进 `/messages` 的 `content` 或某个 `image` 字段——发送侧没有这种字段，图片只能走 `media.file_info`。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>

### E2. 富媒体上传接口

- 📄 `POST https://api.bot.qq.com/v2/users/{user_openid}/files`，频率 **50 QPS**。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 请求体字段：
  - `file_type`（int，必填）
  - `url`（string，**必须 http 开头**；分片合并时可空）
  - `srv_send_msg`（bool，true = 上传同时发送并占主动频次）
  - `upload_id`（分片合并时带）
  - `file_name`（分片/二进制方式必填）
  - `file_data`（二进制，**≤5M**）
  <https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 响应：`file_uuid`、`file_info`、`ttl`（秒，**0 = 可长期使用**）、`id`（仅 `srv_send_msg=true` 时）、`raw_url`（仅分片合并且图片/视频/语音时返回）。
  示例：`{"file_uuid":"uuid_a1b2...","file_info":"AE86C5D3F0E14B238C656C0F6DD1D0479C","ttl":300}`。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 `file_info` 原文：「内部为序列化的二进制数据，开发者无需解析，直接透传」。→ 当作**不透明字符串**存，不要 JSON 解析。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 上传后的发送请求体：
  ```json
  {"msg_type":7, "media":{"file_info":"AE86C5D3F0E14B238C656C0F6DD1D0479C"}}
  ```
  被动回复再加 `msg_id`；主动发送不带 `msg_id`。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>

### E3. file_type 与大小限制

- 📄 `1` 图片（png/jpg）：软限 **20MB**，硬限 **200MB**
- 📄 `2` 视频（mp4）：软限 **30MB**，硬限 **200MB**
- 📄 `3` 语音（silk）：软限 **20MB**，硬限 **200MB**
- 📄 `4` 文件：软/硬均 **200MB**
- 📄 「超过软限制会降级为文件类型上传，超过硬限制会报错」。
  <https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html> · <https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 二进制直传（`file_data`）上限 **5M**，超过就得走 URL 或分片。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 图片格式：富媒概述页写支持 **jpg/png/gif/webp/bmp**；但上传接口的 `file_type` 表只写 **png/jpg**。→ 两处不一致。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>
- ⚠️ 落地建议：表情包统一转 **PNG/JPG**（GIF/WebP 能不能发**不确定**，别指望）；单图 >20MB 会变成「文件」卡片而不是图片。

### E4. 分片上传（大图/大文件才需要）

- 📄 四步：`upload_prepare` → 对每个分片 `PUT` 预签名 URL → 每片 `upload_part_finish` → 带 `upload_id` 调 `/files` 合并拿 `file_info`；分片默认 **5MB**。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>
- 📄 秒传：`md5_10m`（**前 10002432 字节**的 MD5）命中即秒传。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>
- 📄 上传超时建议 ≥5 秒；`file_info` 有 ttl。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>
- ⚠️ 未查到 `upload_prepare` / `upload_part_finish` 的精确路径与字段（文档只给了流程，未在抓到的页面里列出完整请求体）。表情包场景（<5MB）可以完全绕开分片。

### E5. 上传错误码

- 📄 `850019` 不支持的文件格式、`850026` 下载原始文件失败、`850031` 超过大小限制、`850027` 发送数据超时、`850018` 被禁言、`40093001` 文件上传失败请重试、`40093002` 超过今天发送文件容量上限、`10000` 不支持的操作。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_files.post.html>
- 📄 **单聊/群聊上传端点不互通**：单聊必须 `/v2/users/{user_openid}/files`，群聊是 `/v2/groups/{group_openid}/files`；「单聊/群聊上传接口不互通」。<https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>
- ⚠️ URL 方式依赖腾讯服务端去下载你的图，「服务端下载资源可能因网络等原因失败」（`850026`）。表情包建议直接 `file_data` 上传（≤5M）或自建可控公网 URL，不要用第三方图床。

---

## F. 其他会卡住实现的事实

### F1. 用户必须先「添加 / 私聊」机器人吗？

- 📄 是的。机器人被添加到「群聊/频道」内互动，或「QQ 用户也可以直接跟机器人**单独对话**」；服务范围受认证等级限制。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/getting-started.html>
- 📄 个人主体想给别人私聊用，官方路径是：新版管理端「**开发设置**」→ 添加「**开发体验用户号码**」，最多 **20 个**，配置后不受服务范围限制。<https://bot.q.qq.com/wiki/bot_FAQ/> · <https://bot.q.qq.com/wiki/>
- 📄 未认证/个人主体：只能加到「自己是群主/管理员的群」；个人认证「暂不支持公开使用」，企业认证才能公开。<https://bot.q.qq.com/wiki/>
- ⚠️ **入口位置**：手机 QQ 里通过机器人资料卡（扫码/搜索机器人名进入）点「发消息」即可打开单聊窗口；一旦用户发过一条消息，你就有 `user_openid` 可以主动推。文档没有给出确切的 UI 点击路径，以上为社区通行理解，**不确定**。
- ⚠️ 推论：**没有用户先发过消息，你拿不到他的 `user_openid`**，也就无法主动推。所以「定时提醒」必须建立在用户至少说过一次话（并且没关主动消息开关）之上。

### F2. 头像 / 昵称 / 简介

- 📄 创建机器人时「使用默认或上传头像，填写机器人昵称、简介即可创建机器人」，需避免冒充官方、侵权、低俗。<https://bot.q.qq.com/wiki/>
- 📄 可在管理端修改资料；手机端管理路径：机器人聊天界面右上角 → 资料页 → 右上角设置 →「机器人管理」→「高级设置」→「注销机器人」。<https://bot.q.qq.com/wiki/bot_FAQ/>
- 📄 已知限制：私聊聊天界面「不显示 Bot 头像」，官方解释是「目前为提升消息浏览体验…聊天界面使用宽屏消息展示」。→ 头像改了在私聊里也可能看不到，不是 bug。<https://bot.q.qq.com/wiki/bot_FAQ/>

### F3. 同一 AppID 能否本地多开连接（互踢？）

- ❌ **未查到**官方明确写「同一 AppID 多开会被踢」。
- 📄 能查到的相关事实：`/gateway/bot` 返回 `session_start_limit{total:1000, remaining:1000, reset_after:86400000, max_concurrency:1}`，且「每个机器人创建的连接数不能超过 `remaining` 剩余连接数」——说明连接数是有预算的，不是无限的。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/event-emit.html>
- ⚠️ 社区说法：同一 AppID 起两个 WebSocket 客户端会互相顶掉 / 事件被随机分走（[tencent-connect/openclaw-qqbot#90](https://github.com/tencent-connect/openclaw-qqbot/issues/90) 报告「单实例 WebSocket 连接」导致多机器人串台）。**不确定**，但工程上应按「单实例」设计：本地只跑一个连接（多进程用锁 / 单 worker），不要 uvicorn `--workers 4` 起 4 个连接。
- ⚠️ 另外 `304018` SESSION_NOT_EXIST「机器人没连上 gateway」说明「发消息」和「长连接」是解耦的两件事：HTTP 发消息不要求当前进程持有连接，但平台侧要求机器人有活跃连接。

### F4. 消息审核与延迟

- 📄 存在审核/安全打击：`40034006` 消息内容违规、`1100101`「安全打击：内容涉及敏感，请返回修改」、`1100100`/`1100103` 安全打击；`MESSAGE_AUDIT_PASS` / `MESSAGE_AUDIT_REJECT` 事件（intent `1<<27`）会带 `MessageAudited`。<https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html> · <https://bot.q.qq.com/wiki/develop/api-v2/server-inter/channel/message/event.html>
- 📄 异步受理：`304023` / `304024` 返回「异步调用成功，等待人工审核」，并在 `data.message_audit.audit_id` 里给审核单号。<https://bot.q.qq.com/wiki/develop/api-v2/openapi/error/data/model.html>
- ⚠️ **C2C 私聊消息是否每条都前置审核，未查到明确表述**。从错误码推断：普通被动回复基本即时到达，命中敏感内容才被拦（同步 40034006 或异步 304023）。
- ⚠️ 表现：命中时要么直接返回错误码，要么「返回成功但用户看不到」，需要靠 `MESSAGE_AUDIT_REJECT` 事件兜底（想严谨就订阅 `1<<27`，即 `intents = 33554432 | 134217728`）。注意 payload 页说非基础 intent 需申请，**订阅 1<<27 有 4014 风险**。

### F5. IP 白名单 / 回调地址

- 📄 用 WebSocket 模式**不需要公网回调地址、不需要 HTTPS 域名**：「WebSocket：不依赖公网服务器部署，适合个人单机使用，需维护长连接」；反之 Webhook 才需要配 HTTPS。两者在管理端「事件订阅与回调地址」切换，切换后立刻生效。<https://bot.q.qq.com/wiki/>
- 📄 但 **IP 白名单仍然生效**（作用于 OpenAPI HTTP 调用）：「仅支持单个 IPv4，暂不支持 CIDR 网段」「未设置 IP 白名单时，所有请求来源 IP 都会被允许调用」「设置白名单后，仅白名单地址允许调通机器人 OpenAPI，支持最多 50 个 IP 地址」。→ 家里宽带 IP 会变，**建议不设白名单**或准备好随时改。<https://bot.q.qq.com/wiki/>
- ⚠️ 白名单是否也拦 WebSocket 建连，文档没说（白名单说的是「调用 OpenAPI」）；保守假设它只管 HTTP。

### F6. 沙箱 / 上下架

- 📄 关闭码 `4914`「机器人已下架，只允许连接沙箱环境」、`4915`「机器人已封禁」；`11265` 机器人被封禁；`40054016` 机器人已下线。<https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/websocket.html> · <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/api-call-guide.html>
- ⚠️ 开发期建议用「沙箱环境」配置调试，正式环境的事件不会推到沙箱配置。这条是社区常识，文档未在抓到的页面里明确写。

---

## 最容易踩的 5 个坑

1. **`intents` 照抄示例 513 → 收不到任何私聊消息。**
   示例里 `513` 是 `1<<9|1<<0`（频道消息 + 频道），跟 C2C 无关。私聊必须用 **`GROUP_AND_C2C_EVENT = 1<<25 = 33554432`**。症状是连接正常、READY 正常、就是没有 `C2C_MESSAGE_CREATE`；若权限缺失则是关闭码 `4014` / 连上即断。→ <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/event-emit/payload.html>

2. **Authorization 前缀写成 `Bearer`，或以为每次请求都会换新 token。**
   必须是 `Authorization: QQBot <access_token>`；token 生命周期 7200s，有效期内重复获取返回**同一个**值，只有到期前 60s 内取才会换新（旧的还能用 60s）。写成 `Bearer` 直接 `401` / `11243`。→ <https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html>

3. **`msg_id` 时效与 `msg_seq` 的坑（文档自己都写矛盾了）。**
   同一页一处写「60 分钟 / 每条最多 4 次」，另一处写「5 分钟内有效」。**一律按最短的来：收到就回**。同一条消息回多条必须递增 `msg_seq`（默认 1），重复 `msg_id+msg_seq` 会失败（`40054005`），超时/超次 `40034005` / `40034128`。→ <https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_users_user_openid_messages.post.html>

4. **以为「主动推送」是无限的。**
   三重闸门：①用户可以在资料卡关掉「允许主动发送」（`C2C_MSG_REJECT`，发送失败 `40054013`）；②没有好友关系可能直接 `40054004`「请先添加好友后再发送私信」；③配额 1000 条/**用户**/天 + 10 QPS + 20 条/分钟（单关系），超了 `40034100`。定时提醒要自己做「每日预算 + 去重 + 开关状态」三件事。→ <https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html>

5. **图片：以为能直接发 URL，或拿群聊端点上传的 `file_info` 去发私聊。**
   ①发送侧没有「图片 URL」字段，必须先 `POST /v2/users/{openid}/files` 拿 `file_info` 再 `msg_type=7`；②`file_info` **有 ttl**（示例才 300 秒！），要即传即发、别缓存；③单聊/群聊上传端点**不互通**，用错端点 `304080`；④`file_data` 直传 **≤5MB**，超过走 URL 或分片；⑤`file_type` 只认 png/jpg（GIF/WebP 是否能发不确定）。→ <https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/rich-media.html>

---

## 附录：一页速查（Python 客户端要实现的 6 个动作）

```text
1) 取 token   POST https://api.bot.qq.com/app/getAppAccessToken
              body {"appId":..., "clientSecret":...}  → 缓存 access_token / expires_in
2) 取网关     GET  https://api.bot.qq.com/gateway
              header Authorization: QQBot <token>     → {"url":"wss://api.bot.qq.com/websocket/"}
3) 长连接     ws connect → recv op10 {heartbeat_interval}
              send op2 {token:"QQBot <token>", intents:33554432, shard:[0,1], properties:{...}}
              recv op0 t=READY {session_id}
              every heartbeat_interval: send op1 {d:last_s}   (first time d:null)
              recv op11 → ok；op7 → reconnect+op6；op9 → 重新 op2
              on reconnect: op6 {token, session_id, seq:last_s} → t=RESUMED
4) 收私聊     op0 t=C2C_MESSAGE_CREATE → d.id / d.author.user_openid / d.content / d.timestamp
              / d.attachments[] / d.message_scene.ext[msg_idx]；按 d.id 幂等去重
5) 被动回复   POST https://api.bot.qq.com/v2/users/{user_openid}/messages
              {"content":"...","msg_type":0,"msg_id":"<d.id>","msg_seq":1}
6) 主动/图片  POST .../v2/users/{user_openid}/files
              {"file_type":1,"file_data":"<b64 or multipart>","file_name":"a.png"}
              → {"file_info":"...","ttl":300}
              POST /v2/users/{user_openid}/messages {"msg_type":7,"media":{"file_info":"..."}}
```

**未查到 / 不确定清单（落地需实测）**：C2C intent 是否需后台申请（文档说需申请，社区说默认开）｜同 AppID 多开是否互踢｜C2C 是否逐条前置审核｜分片上传 `upload_prepare` 的精确路径与字段｜私聊入口的确切 UI 路径｜GIF/WebP 是否能直接以图片发送。
