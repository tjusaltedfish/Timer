# 恢复演练手册（一页纸）

每月一次，验证 `planner-YYYYMMDD-HHMMSS.db` 能真正恢复到可启动的数据库。
推荐先做「隔离演练」（R1，不碰生产），再每季度做一次「生产恢复」（R2）。

## 0. 前置检查

```powershell
# 备份是否存在、最新指针指向哪个文件
Get-ChildItem "$env:USERPROFILE\TimePlanner\backups\daily\planner-*.db" |
    Sort-Object Name -Descending | Select-Object -First 5 Name, Length
Get-Content "$env:USERPROFILE\TimePlanner\backups\daily\latest.txt"
```

`latest.txt` 正常内容（`secrets=` 为空表示未备份密钥，属默认行为）：

```
stamp=20261022-030000
time=2026-10-22T03:00:01
db=planner-20261022-030000.db
users=planner-20261022-030000.users
secrets=
source=C:\Users\ASUS\TimePlanner\data
integrity=ok
```

备份套件是三个同名件：`planner-<stamp>.db`（SQLite 在线备份）、
`planner-<stamp>.users\`（用户素材目录）、可选 `planner-<stamp>.secrets\`。

## R1. 隔离演练（推荐，无风险）

恢复到 `%TEMP%` 下的独立目录，生产数据一行不动：

```powershell
$drill = Join-Path $env:TEMP ("restore-drill-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
.\tools\host\restore.ps1 `
    -BackupDir "$env:USERPROFILE\TimePlanner\backups\daily" `
    -DataDir $drill `
    -AllowedDataRoots $env:TEMP
```

预期输出（2026-10-22 用两表夹具真实运行，行数按生产库会不同）：

```
restore: start backup=...\daily\planner-20261022-030000.db data=...\restore-drill-... port=8765 force=False
restore: backup check: integrity=ok tables=2
restore: created data directory C:\Users\ASUS\AppData\Local\Temp\restore-drill-...
restore: copied backup (16384 bytes) to ...\planner.db
restore: copied users -> ...\users
restore: restored check: integrity=ok tables=2
Restored: ...\planner.db
From:     ...\daily\planner-20261022-030000.db
Verified: integrity=ok tables=2
```

退出码 `0` 即通过。再手工确认内容（表名按当前 schema，数字不必相同）：

```powershell
$db = Join-Path $drill 'planner.db'
.\server\.venv\Scripts\python.exe -c @"
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
print('integrity:', con.execute('PRAGMA integrity_check').fetchone()[0])
print('tables   :', con.execute(\"SELECT count(*) FROM sqlite_master WHERE type='table'\").fetchone()[0])
print('tasks    :', con.execute('SELECT count(*) FROM tasks').fetchone()[0])
"@ $db
```

演练完删除临时目录：`Remove-Item -LiteralPath $drill -Recurse -Force`。

## R2. 生产恢复（真故障时）

1. 停止后端。占用 8765 时 `restore.ps1` 会以 **exit 2** 退出并且不改任何文件：

   ```powershell
   schtasks /End /TN TimePlannerBackend
   Get-NetTCPConnection -LocalPort 8765 -State Listen   # 应无输出
   ```

2. 记录现场（把当前库留档，脚本会自动改名，无需手工备份）：

   ```powershell
   Get-Item "$env:USERPROFILE\TimePlanner\data\planner.db" | Select-Object FullName, Length, LastWriteTime
   ```

3. 恢复（默认 `-DataDir` 就是生产目录，`-BackupDir` 可给 `daily`、`weekly` 目录、某个 `.db` 或 `latest.txt`）：

   ```powershell
   .\tools\host\restore.ps1 -BackupDir "$env:USERPROFILE\TimePlanner\backups\weekly"
   ```

   脚本行为：先做 `integrity_check`；把现库改名为 `planner.db.pre-restore-<stamp>`（`-wal/-shm/-journal`
   一并改名），`users\` 改名为 `users.pre-restore-<stamp>`；再复制备份；最后再校验一次并对比两次报告。
   任何一步失败退出码 `1`，此时生产库还是原样。

4. 启动后端（脚本末尾也会打印该命令）：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Apps\Timer\Start-Timer.ps1" -BackendOnly
   ```

5. 健康检查：

   ```powershell
   Invoke-RestMethod http://127.0.0.1:8765/health            # status=ok
   curl.exe -sS -o NUL -w "%{http_code}`n" https://timer.studydazi.top/api/v1/snapshot   # 200 或 401
   ```

## 回滚（恢复后发现问题）

`planner.db.pre-restore-<stamp>` 就是恢复前的现场，改名回去即可：

```powershell
$data = "$env:USERPROFILE\TimePlanner\data"
$stamp = (Get-ChildItem $data -Filter 'planner.db.pre-restore-*' | Sort-Object Name -Descending)[0].Name
schtasks /End /TN TimePlannerBackend
Move-Item -LiteralPath (Join-Path $data $stamp) -Destination (Join-Path $data 'planner.db') -Force
if (Test-Path (Join-Path $data "users.pre-restore-$($stamp -replace '^planner\.db\.pre-restore-','')")) {
    Move-Item -LiteralPath (Join-Path $data 'users') -Destination (Join-Path $data 'users.restored') -Force
    Move-Item -LiteralPath (Join-Path $data "users.pre-restore-$($stamp -replace '^planner\.db\.pre-restore-','')") -Destination (Join-Path $data 'users') -Force
}
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Apps\Timer\Start-Timer.ps1" -BackendOnly
```

## 常见失败

| 现象 | 处理 |
|---|---|
| exit 2，`port 8765 is listening (pid ...)` | 先停后端；确认误报才加 `-Force` |
| `Refusing to restore from ... outside ...backups` | 备份不在允许根内；确属手动备份时传 `-AllowedBackupRoot` |
| `Refusing to restore into ... not under any allowed root` | `-DataDir` 不在 `...\TimePlanner` 或 `%TEMP%` 下；演练时显式传 `-AllowedDataRoots $env:TEMP` |
| `backup check: ...` 报 integrity 失败 | 换 `weekly` 或更早的备份；该备份文件已损坏，保留现场待查 |
| 在 AI/沙箱终端里报 `PermissionError` | 沙箱限制该解释器写 `%TEMP%`/`%USERPROFILE%`，加 `-Python "C:\Users\ASUS\anaconda3\envs\pytorch\python.exe"`；计划任务与普通终端不受影响 |

## 记录表

| 日期 | 类型 | 备份文件 | 耗时 | 结果 | 执行人 | 备注 |
|---|---|---|---|---|---|---|
|  | R1 隔离 |  |  |  |  |  |
|  | R1 隔离 |  |  |  |  |  |
|  | R2 生产 |  |  |  |  |  |

判定标准：R1 连续两次通过且 `integrity=ok`、行数与预期一致；R2 通过后 `/health` 返回 ok、
公网 401/200，并观察 24 小时无异常。演练记录只写本地，不提交到 Git（含路径与时间信息）。
