# 瞬时 v2 API 契约（P1：认证与多租户）

> 这是后端与客户端之间的最小契约。实现见 `server/app/main.py`（`/api/v1/auth/*`、`/api/v1/me*`）与
> `server/app/auth.py`。错误统一为 `{"code": "...", "message": "..."}`（HTTP 状态码見括号）。

## 1. 认证

所有业务接口带 `Authorization: Bearer <token>`。令牌由服务端签发，DB 只存 sha256。

### POST /api/v1/auth/login

```json
{ "username": "shidi", "password": "初始密码", "device": { "name": "Pixel 9", "platform": "android" } }
```

成功 200：

```json
{
  "token": "32字节urlsafe",
  "device": { "id": "uuid", "name": "Pixel 9", "platform": "android" },
  "user": {
    "id": "uuid", "username": "shidi", "display_name": "师弟", "role": "member",
    "timezone": "Asia/Shanghai", "onboarding": {"version": 2, "step": 0, "done": [], "skipped": []}
  }
}
```

失败：401 `INVALID_CREDENTIALS`（用户名或密码不对，不区分哪个错）；
429 `RATE_LIMITED`（同一 IP 1 分钟 10 次失败）；403 `ACCOUNT_DISABLED`。

客户端必须把 `token` 与 `baseUrl` 一起持久化；下次启动直接用 token 调 `GET /api/v1/me`，
401 时才回登录页。首次登录服务器的默认地址为 `http://127.0.0.1:8765`（桌面本机）。

### POST /api/v1/auth/logout

Bearer 当前设备 → 200 `{"ok": true}`，服务端吊销该设备令牌（不是账号）。

### GET /api/v1/me

返回 `{"user": {...user 同上}, "device": {"id","name","platform"}}`。

### PATCH /api/v1/me

```json
{ "display_name": "师弟", "timezone": "Asia/Shanghai", "onboarding": {"version":2,"step":4,"done":["welcome"],"skipped":[]} }
```

字段都可选；`timezone` 必须是 IANA 名称（如 `Asia/Shanghai`）。返回更新后的 `user`。

### POST /api/v1/me/password

```json
{ "current_password": "旧", "new_password": "新（10 位起）" }
```

成功 200 `{"ok": true}`；同时吊销**其他**设备令牌（当前设备保留）。失败 401 `INVALID_CREDENTIALS`，
422 `VALIDATION_ERROR`（太短）。

### GET /api/v1/me/devices

返回 `{"devices": [{"id","name","platform","created_at","last_seen_at","revoked"}]}`（只含自己的）。

### DELETE /api/v1/me/devices/{device_id}

吊销自己的某台设备；`404` 表示不属于你（不要泄漏别人的设备是否存在）。不能删除当前设备，
此时返回 409 `CANNOT_REVOKE_CURRENT`（用 logout）。

## 2. 同步与业务接口（沿用现有实现）

- `GET /api/v1/snapshot`、`POST /api/v1/operations`：请求/响应结构不变，但**按登录用户隔离**；
  A 的令牌看不到 B 的任务/块/事件/助手内容。跨用户 id → 404。
- 现有 `/api/v1/pairing/*` 与 `desktop-token` 仅用于「本机单用户兼容模式」，新 App 不再使用。
- `GET /health` 保持无鉴权（只返回服务版本）；任何数据接口无令牌 → 401。

## 3. 站长 CLI（不进 App）

```bash
./server/.venv/Scripts/python.exe -m app.admin user add --username shidi --name 师弟
./server/.venv/Scripts/python.exe -m app.admin user list
./server/.venv/Scripts/python.exe -m app.admin user reset-password --username shidi
./server/.venv/Scripts/python.exe -m app.admin user disable --username shidi
```

`user add` 打印一次性初始密码（除非 `--password` 指定）。没有注册页，没有邀请码。

## 4. 客户端落地要点（P3 之前先做最小登录）

1. 启动：读本地 `baseUrl` + `token`；无 token → 登录页（地址 + 用户名 + 密码）。
2. 登录成功：写本地 `token`/`baseUrl`/`user`，直接进首页并照常拉 `/snapshot`。
3. 任何接口返回 401：清 token → 登录页（不要死循环重试）。
4. 设置页：显示当前账号、服务地址（可改，改完提示重新登录）、本机设备列表、退出登录。
5. 状态栏：现有「离线，N 条待同步」逻辑保留。
