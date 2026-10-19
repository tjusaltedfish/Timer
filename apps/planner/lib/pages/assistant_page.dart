part of '../home.dart';

extension _AssistantPage on _PlannerHomeState {
  Widget assistantPage() => padded(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('把变化，告诉助手。', '助手接入和结构化建议正在实现，任务、执行和反馈可先正常使用。'),
        panel(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('模型服务尚未配置', style: TextStyle(fontSize: 20)),
              SizedBox(height: 12),
              Text('API Key 将保留在电脑端。配置完成后，这里用于制定计划、解释调整和日终分析。'),
            ],
          ),
        ),
      ],
    ),
  );
}
