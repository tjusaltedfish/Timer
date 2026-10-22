# 运维手册：数据、备份、隧道与公众号

本文只讲「瞬时」v2 在家庭 Windows 主机上的运维：数据目录、SQLite 备份/恢复、cloudflared
命名隧道、公众号测试号回调、计划任务与排障。应用代码与接口约定见 `docs/STATUS.md` 与
`docs/plans/v2-multiuser-plan.md`。

## 1. 部署拓扑

| 组件 | 位置 / 值 | 说明 |
|---|---|---|
| 后端 | `uvicorn`，只绑 `127.0.0.1:8765` | FastAPI 单进程；启动脚本 `Start-Timer.ps1 -BackendOnly` |
| 数据目录 | `%USERPROFILE%\TimePlanner\data` | `planner.db`（SQLite/WAL）+ `secrets\` + `users\` |
| 备份目录 | `%USERPROFILE%\TimePlanner\backups` | `daily\`、`weekly\`、`backup.log` |
| 日志 | `%USERPROFILE%\TimePlanner\logs` | `watchdog.log`、`cloudflared.log` 等 |
| 隧道 | cloudflared 命名隧道 `timer`，主机名 `timer.studydazi.top` | 配置 `%USERPROFILE%\Apps\cloudflared\timer.yml` |
| 公众号回调 | `https://timer.studydazi.top/wechat/callback` | GET 校验 + POST 消息，见 §4 |
| 计划任务 | `TimePlannerBackend`、`TimePlannerWatchdog`、`TimePlannerBackup` | 前两个由 `tools/install-autostart.ps1`，备份任务见 §5 |

数据目录由 `PLANNER_DATA_DIR` 覆盖，默认 `Path.home()/TimePlanner/data`（`server/app/releases.py`）。
**红线**：`planner.db`、`secrets/`、备份文件都含用户数据或明文令牌，不进 Git、不进公共同步盘。

## 2. 数据目录结构

```
%USERPROFILE%\TimePlanner\data\
  planner.db            SQLite 主库（WAL 模式，运行中会有 planner.db-wal/-shm）
  secrets\              明文令牌：wechat-token、wechat-secret、qq-secret、llm-key 等
  users\<user>\         用户上传的素材（图片/文件）
```

`secrets\` 与 `users\` 是运行数据，**不要**手工编辑；改令牌用 App「设置」页或接口写入。

## 3. 备份与恢复

### 3.1 每日备份

```powershell
# 默认：数据目录 %USERPROFILE%\TimePlanner\data，目标 ...\backups\daily，保留 14 天 + 8 周
.\tools\host\backup.ps1

# 演练 / 自定义：注意 -DataDir 与 -Target 不能互相包含
.\tools\host\backup.ps1 -DataDir "$env:TEMP\fake data" -Target "$env:TEMP\fake backups\daily" -ForceWeekly
```

行为要点：

- `planner.db` 用 Python `sqlite3.Connection.backup`（在线备份 API）生成 `planner-YYYYMMDD-HHMMSS.db`，
  后端运行中也能得到一致副本，不依赖 `sqlite3.exe`；解释器默认 `server\.venv\Scripts\python.exe`。
- `users\` 用 robocopy 复制到同名 `planner-<stamp>.users\`，排除 `-wal/-shm/-journal`。
- `secrets\` 默认**不**备份；需要时显式 `-IncludeSecrets`（备份目录将含明文，务必限制访问）。
- `daily\latest.txt` 记录最新一次备份（`stamp/time/db/users/secrets/source/integrity`），恢复脚本可直接指向它。
- 每周一个归档到 `%USERPROFILE%\TimePlanner\backups\weekly`（最新 weekly 满 7 天才写，`-ForceWeekly` 强制）。
- 保留策略：daily 超过 `-KeepDays`（默认 14）删除，weekly 只留最新 `-KeepWeeks`（默认 8）个；
  伴随目录与孤儿目录一并清理。日志 `backups\backup.log`，超过 2 MB 轮转为 `.log.old`。
- 退出码：`0` 成功；`1` 任一步失败（日志中有 `backup: FAILED: ...`）。

### 3.2 恢复

一键恢复与回滚步骤见 **`tools/host/restore-drill.md`**（含隔离演练、生产恢复、回滚、记录表）。
概要：停后端 → `.\tools\host\restore.ps1 -BackupDir ...` → 用 `Start-Timer.ps1 -BackendOnly` 启动。
脚本会先 `integrity_check`、把现库改名为 `planner.db.pre-restore-<stamp>`（不删除），端口占用时 exit 2。

## 4. 公众号测试号接入

1. 打开微信公众平台「测试号」（`mp.weixin.qq.com` → 测试号管理），拿到 `appID`/`appsecret`，
   在测试号页面配置接口信息：
   - **URL**：`https://timer.studydazi.top/wechat/callback`
   - **Token**：与 `<data>\secrets\wechat-token` 一致（App 设置页填写后写入该文件）
   - **EncodingAESKey**：留空（明文模式）；消息加解密方式选「明文模式」
2. 点「提交」时微信会 `GET` 回调地址：`signature`、`timestamp`、`nonce`、`echostr`。
   服务端用 `sha1(sorted([token, timestamp, nonce]))` 与 `signature` 对比（时间窗 ±30 分钟），
   成功回 `echostr` 纯文本，失败 `403 forbidden`。返回非 `echostr` 原文即配置失败。
3. 用户发消息时微信 `POST` XML 到同一 URL：签名校验通过后服务端立即回纯文本 `success`，
   消息在后台异步入库/处理。**不要**在该路径做耗时操作——微信要求 5 秒内响应，否则重试。
4. 验证：关注测试号二维码后发「今天」等指令，观察 App 内公众号消息与 `watchdog.log`；
   也可用 `curl.exe "http://127.0.0.1:8765/wechat/callback?signature=...&echostr=test"` 本地自测签名逻辑。

回调解密、口令与指令语义属于应用逻辑，见 `server/app/wechat.py`。

## 5. 每日 03:00 备份计划任务

推荐用仓库脚本注册（会自动设置工作目录、错过补跑、1 小时上限、失败重试 2 次）：

```powershell
.\tools\host\install-backup-task.ps1                 # 每天 03:00，14 天 + 8 周
.\tools\host\install-backup-task.ps1 -Time 03:30 -KeepDays 30
.\tools\host\install-backup-task.ps1 -ValidateOnly   # 只读检查（未注册时 exit 1）
.\tools\host\install-backup-task.ps1 -Remove         # 删除任务
```

等价的 `schtasks` 命令行。在仓库根目录的 PowerShell 里执行（路径含空格也安全）：

```powershell
$backup = Join-Path $PWD 'tools\host\backup.ps1'
$action = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -KeepDays 14 -KeepWeeks 8' -f $backup
schtasks /Create /TN TimePlannerBackup /SC DAILY /ST 03:00 /RL LIMITED /F /TR "powershell.exe $action"
```

在 `cmd.exe` 里等价写法（`\"` 是 cmd 传给 schtasks 的内层引号，必须保留）：

```bat
schtasks /Create /TN TimePlannerBackup /SC DAILY /ST 03:00 /RL LIMITED /F ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\Users\ASUS\Documents\Timer\tools\host\backup.ps1\" -KeepDays 14 -KeepWeeks 8"
```

注册后务必核对实际存储的命令行，确认 `-File` 路径与参数没有被截断；日常也用这些命令管理任务：

```powershell
schtasks /Query /TN TimePlannerBackup /V /FO LIST
schtasks /Run /TN TimePlannerBackup        # 立即试跑，然后看 backups\backup.log
schtasks /End /TN TimePlannerBackup        # 停止正在跑的一次
schtasks /Delete /TN TimePlannerBackup /F  # 删除任务
```

注意：

- `schtasks /TR` 不会设置工作目录与「错过补跑/失败重启」，长期使用优先 `install-backup-task.ps1`。
- 仓库搬家后 `/TR` 里的绝对路径会失效：重新运行安装脚本（或删任务重建）。
- 03:00 后端仍在运行是安全的：在线备份 API 不要求停服。
- 结果核对：`backup.log` 末尾出现 `backup: done in ...`、`daily\latest.txt` 时间戳更新、
  `(Get-ScheduledTaskInfo -TaskName TimePlannerBackup).LastTaskResult` 为 `0`。

## 6. cloudflared 命名隧道

本机已安装 `cloudflared`（`%USERPROFILE%\Apps\cloudflared\cloudflared.exe`），并已有 v1 隧道
`fe2c5622-060b-4d31-8fa5-f7d18b1149fa`、`cert.pem` 与隧道凭据在 `%USERPROFILE%\.cloudflared\`。
v2 只是把服务的本地端口从 8787 换成 **8765**。

### 6.1 新建命名隧道（一次）

```powershell
cloudflared tunnel login                 # 浏览器授权域名，生成 %USERPROFILE%\.cloudflared\cert.pem
cloudflared tunnel create timer          # 输出 UUID，并写 .cloudflared\<UUID>.json 凭据
cloudflared tunnel list                  # 确认 timer 与 UUID
cloudflared tunnel route dns timer timer.studydazi.top   # 自动建 CNAME timer -> <UUID>.cfargotunnel.com
```

### 6.2 配置 `timer.yml`

`%USERPROFILE%\Apps\cloudflared\timer.yml`（v2 模板，旧文件两个 `service` 端口都要改）：

```yaml
# 只暴露 v2 API 与公众号回调；其余路径 404（/health 仅本机可用，不对外）。
tunnel: <UUID>
credentials-file: C:\Users\ASUS\.cloudflared\<UUID>.json
no-autoupdate: true
# QUIC 在部分代理/TUN 环境不稳定；HTTP/2 走 TCP，与本机网络现状一致。
protocol: http2
ingress:
  - hostname: timer.studydazi.top
    path: ^/api/v1/
    service: http://127.0.0.1:8765
  - hostname: timer.studydazi.top
    path: ^/wechat/callback$
    service: http://127.0.0.1:8765
  - service: http_status:404
```

要点：

- `ingress` 从上到下匹配，路径是正则；`/wechat/callback` 单独一条是因为它不带 `/api/v1` 前缀。
- 最后一条必须是兜底（`http_status:404`），否则未匹配路径会被拒绝连接。
- 修改后校验并重启隧道：

```powershell
cloudflared tunnel ingress validate --config "$env:USERPROFILE\Apps\cloudflared\timer.yml"
cloudflared tunnel info timer
cloudflared tunnel --config "$env:USERPROFILE\Apps\cloudflared\timer.yml" --logfile "$env:USERPROFILE\TimePlanner\logs\cloudflared.log" run timer
```

### 6.3 验证

```powershell
Invoke-RestMethod http://127.0.0.1:8765/health        # {"status":"ok",...}
curl.exe -sS -o NUL -w "%{http_code}`n" https://timer.studydazi.top/api/v1/snapshot  # 401 = 隧道通、未带 token
```

- 公网 404：`ingress` 路径或端口不对（先本地 `curl http://127.0.0.1:8765/api/v1/snapshot` 对照）。
- 公网 1033/530：隧道没连上（进程挂了、凭据过期、DNS 未生效）→ 看 `cloudflared.log` 与 §8。
- 不建议用 `cloudflared service install`：Windows 服务以 LocalSystem 运行时容易读不到用户目录下的
  `cert.pem`/凭据；沿用「用户会话 + watchdog」的 v1 方式最省事。

## 7. 保留、异地与监控

- 本地保留：daily 14 天 + weekly 8 周；旧库（`planner.db.pre-restore-*`）建议保留 30 天再手工清理。
- 第二块盘（拔盘即做的冷备）：紧接备份任务的每日 robocopy，`/MIR` 删除已过期文件：

```powershell
robocopy "$env:USERPROFILE\TimePlanner\backups" "D:\TimerBackups" /E /MIR /R:1 /W:1 /XF *.log /NFL /NDL /NJH /NJS
```

- 异地：`rclone sync "$env:USERPROFILE\TimePlanner\backups" b2:timer-backups --fast-list`（先 `rclone config` 配 B2）。
- 监测：`backup.log`（每日 `done`）、`watchdog.log`（隧道重启记录）、`cloudflared.log`、
  `Get-ScheduledTaskInfo` 的 `LastTaskResult`；`planner.db` 持续接近/超过 2 MB 时按计划 §5.5 做瘦身
  （清理旧 release、素材与历史执行记录），瘦身前先做一次 `-ForceWeekly` 备份。

## 8. 排障速查

| 症状 | 先查 | 处理 |
|---|---|---|
| 8765 无监听 | `Get-NetTCPConnection -LocalPort 8765 -State Listen`；任务 `LastTaskResult` | `Start-Timer.ps1 -BackendOnly`；看后端日志 |
| 本地 `/health` OK、公网 404 | ingress path/端口 | 改 `timer.yml` 后重启隧道（§6.2） |
| 公网 1033/530 | 隧道进程、凭据、DNS | 重启 cloudflared / `tunnel list` / `route dns` 重查 |
| 公众号保存配置 403 | `secrets\wechat-token` 与页面 Token 是否一致；系统时间 | `w32tm /resync`；改 Token 后重新提交 |
| 公众号发消息没反应 | 微信 5 秒超时/重试 | 回调必须立即回 `success`；查后端日志 |
| `restore.ps1` exit 2 | 8765 被占 | 先停后端，确认误报再用 `-Force` |
| `backup.ps1` exit 1 + `PermissionError` | 解释器写权限（见 §9） | 换 `-Python` 或普通 PowerShell 窗口重跑 |
| 备份打不开 / integrity 失败 | `PRAGMA integrity_check` | 用 `weekly` 或更早备份；保留损坏文件排查 |

## 9. 本机沙箱注意（AI/托管终端）

这台机器上的托管沙箱按可执行文件路径限制写盘：`server\.venv\Scripts\python.exe` 在 AI 终端里
只能写仓库目录，写 `%TEMP%`/`%USERPROFILE%` 会报 `PermissionError` 或
`sqlite3.OperationalError: unable to open database file`（`docs/STATUS.md` 有同类记录）。
计划任务由 Task Scheduler 在用户会话里启动，通常不在 agent 的沙箱内，生产备份按设计不受影响；
但如果 `backup.log` 出现上述错误，按下一段加 `-Python` 或在普通 PowerShell 窗口重跑即可。

手动在沙箱里跑演练时，加 `-Python` 指向 pyvenv 的 base 解释器（`server\.venv\pyvenv.cfg` 的
`home`，本机实测为 `C:\Users\ASUS\anaconda3\envs\pytorch\python.exe`），即：

```powershell
.\tools\host\backup.ps1 -DataDir "$env:TEMP\fake data" -Target "$env:TEMP\fake backups\daily" -Python C:\Users\ASUS\anaconda3\envs\pytorch\python.exe
```
