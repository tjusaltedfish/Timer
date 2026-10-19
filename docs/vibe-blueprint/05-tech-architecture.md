# 架构建议

```text
Flutter Android：本地缓存、执行反馈、本地提醒
          ↕ 设备配对 + 加密连接 + 版本同步
Windows 常驻 Python/FastAPI + SQLite
  ├─ 领域状态、规则排程、提案校验
  ├─ 模型接口、日报和归档
  └─ 持久化作业与事件
          ↕ localhost
Flutter Windows：计划编辑、课表、结果和设置
```

## 运行边界

- 电脑数据库是共享日程规范版本；手机缓存带版本。
- 服务器生成提案，应用前校验版本并原子提交。
- 离线可记录执行/反馈和新任务草稿；全局重排待连接后生成正式提案。
- 手机提前注册已同步日程的本地提醒，电脑展示手机最后确认版本。
- 手机后台远程变更不承诺即时送达；推送/系统约束同步路径需真机验证。
- 单常驻进程 + SQLite 事务 + 持久化作业表；V1 不引入分布式队列。
- UI 关闭时服务独立；重启按幂等键恢复作业；失败保留输入。

## 连接与部署

先评估 Tailscale 私人网络和配对，不默认开放公网端口。手机移动网络验证连通、耗电及 VPN 占用。实际不可用时再比较带认证的 HTTPS 入口。域名到期不影响本地记录与导出。

先本地运行，再跨设备，最后配置自启动。系统安装、服务注册和防火墙调整执行前说明范围。

## 依赖与配置

初始化时解析兼容稳定版本并提交锁文件，不在蓝图编造版本。Python 独立 .venv，不向研究环境安装产品依赖。配置监听、数据/归档目录、IANA 时区、模型供应商/base URL/model；Key 仅保留电脑配置或系统凭证存储。

## 依据

- [Flutter 跨端](https://docs.flutter.dev/platform-integration)
- [Windows 工具链](https://docs.flutter.dev/platform-integration/windows/setup)
- [Android 提醒](https://developer.android.com/develop/background-work/services/alarms)
- [私人设备连接](https://tailscale.com/docs/how-to/connect-to-devices)
- [VPN 共存限制](https://tailscale.com/docs/reference/faq/other-vpns)
