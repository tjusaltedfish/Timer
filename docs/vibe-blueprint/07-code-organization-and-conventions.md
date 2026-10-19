# 代码组织与约定

## 目录规划

```text
docs/vibe-blueprint/       产品、流程和契约
docs/environment-check.md
prototype/                HTML/CSS/JS 页面草图
apps/planner/             后续 Flutter 客户端
server/app/domain/        后续领域状态与排程
server/app/api/           HTTP 路由与校验
server/app/storage/       SQLite、迁移与事件
server/app/integrations/  模型与归档
server/tests/             领域、接口、恢复测试
artifacts/                本地验证产物，忽略提交
```

apps/server 目前为规划；按需要创建，避免空架构。

## 约定

- Python/Dart 文件 snake_case；Dart 类型 UpperCamelCase，成员 lowerCamelCase。
- Python 类型注解；边界校验；领域函数不依赖 UI 或发网络请求。
- JSON/表字段 snake_case；UUID 标识、版本号、UTC 时间附时区语义。
- 状态转换集中维护，附原因与事件；模型和 UI 不直接写任意状态。
- API `/api/v1`，错误稳定 code；UTF-8，中文用户文案。
- 一次一个纵向切片；锁文件、迁移和配置样例随切片加入。

```python
def validate_remaining_minutes(value: int) -> int:
    if value < 0:
        raise ValueError("remaining_minutes must be non-negative")
    return value
```

## 命令

当前草图预览见根 README。以下是后续对应项目初始化后的命令，不是本轮通过记录：

```powershell
# server 内，独立虚拟环境准备后
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8787
# apps/planner 内，工具链准备后
flutter analyze
flutter test
flutter run -d windows
flutter build apk --debug
```

源码不保存 API Key、设备凭证、数据库、个人归档或签名文件。
