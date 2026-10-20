# 个人弹性日程助手 · 开发蓝图

日期：2026-10-19。版本 v0.3。状态：双端功能预览已实现并上传私有仓库；完整初版尚未验收。当前进度以 [STATUS](../STATUS.md) 为准，环境以 [共同开发环境](../development-environment.md) 为准。

## 已确认

- 单人自用；OPPO Find X8s / ColorOS 17；Windows 电脑通常开机、不休眠。
- 秋招转行自学、毕业实验代码、Fab 工艺为三条工作主线。
- 七天课表、今日卡片/列表、结果追问、状态机与弹性调整、对话助手、日报和跨设备使用。
- 每天文字反馈合计约两三句话；平时快捷点选。通常不使用 VPN；已有域名。

## 当前技术与产品决定

- Flutter Android + Windows；Python/FastAPI + SQLite 常驻电脑。
- 单人设备配对，私人网络优先；手机独立执行已同步提醒。
- 重排先预览；尊重固定预约、保护时间、依赖和最小连续投入。
- 首次设置读取客户端时区。本轮示例 America/Los_Angeles；真实作息首次规划时设置。
- 黑白近中性色的「墨晕白纸」界面，当前规范见 [视觉设计](../design/ink-system.md)。分类由用户创建与管理，三条工作主线是使用背景，不是预置分类。
- 学习材料、AI 日终复盘与知识回忆的设计已确认，功能尚未实现，见 [学习复盘设计](../design/daily-review.md)。
- 用户确认电脑登录微信小号，以普通好友私聊服务手机大号；先验证桌面适配再接入后台。调研完成、功能待实现，见 [微信小号技术路线](../design/wechat-personal-channel.md)。

## 阅读入口

1. [产品说明](01-product-brief.md)
2. [范围与验收](02-scope-and-requirements.md)
3. [页面与流程](03-user-flows-and-pages.md)
4. [视觉与交互](04-visual-and-ux-style.md)
5. [架构](05-tech-architecture.md)
6. [数据、状态机与接口](06-data-api-and-integrations.md)
7. [组织与命令](07-code-organization-and-conventions.md)
8. [实施任务](08-implementation-plan.md)
9. [验证与部署](09-quality-security-and-deployment.md)
10. [后续 AI 协作规则](10-ai-collaboration-rules.md)

## 开放决定

| 决定 | 默认方向 | 状态 |
|---|---|---|
| 跨端栈/视觉 | Flutter Android/Windows + 墨晕白纸 | 已实现功能预览；真机完整验收待完成 |
| 外网连接 | 私人网络与配对 | 待实际连通验证 |
| 模型 | OpenAI 兼容 Chat Completions 与结构化拟办 | 适配和 Mock 测试已完成；真实服务地址、模型名和 Key 待用户在电脑本地配置并实测 |
| 开发环境 | 独立 Python + 共享 Flutter/Android 工具链 | 已修复并通过 doctor、测试、静态检查及双端构建；先运行 tools/setup-dev.ps1 |
| 作息/固定预约 | 首次使用设置 | 不阻碍领域设计和界面确认 |
| 微信小号入口 | 独立 Windows UIA 桥接作为首个评估方向 | 本机微信 4.1.15.13；具体库、账号 UI 可读性、锁屏与收发待验证 |

## 决策记录

- 2026-10-19：接受先落盘需求、页面草图和环境检查的下一步。
- 2026-10-19：任务、计划时间块与实际执行分别建模；沉默/到点不推定完成。
- 2026-10-19：浏览器草图只使用演示数据，不代表原生通知、跨设备或模型能力通过验证。
- 2026-10-19：用户持续目标授权推进完整双端初版。沿用 Flutter Android + Windows 与 Python 电脑常驻服务；SDK 与项目独立环境开始配置。新许可仍需用户明确接受。
- 2026-10-19：项目改名 Timer；查明 AppData 重定向后，工具链和包缓存迁入 DevTools/Timer。产品与环境里程碑已推送至私有 GitHub 仓库 tjusaltedfish/Timer。
