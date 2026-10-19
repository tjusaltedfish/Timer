part of '../home.dart';

class ReviewPanel extends StatefulWidget {
  const ReviewPanel({super.key, required this.controller, required this.day});
  final PlannerController controller;
  final String day;
  @override
  State<ReviewPanel> createState() => _ReviewPanelState();
}

class _ReviewPanelState extends State<ReviewPanel> {
  final text = TextEditingController();
  String? result;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant ReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day != widget.day) load();
  }

  void load() {
    text.text =
        widget.controller.reviews
            .where((r) => r['date'] == widget.day)
            .lastOrNull?['text'] ??
        '';
    result = null;
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '让今天，有个收尾。',
          style: TextStyle(fontSize: 28, color: context.inkPalette.inkJiao),
        ),
        const SizedBox(height: 10),
        Text('${widget.day} · 两三句话，记录产出、卡点和下一步。'),
        const SizedBox(height: 24),
        TextField(
          controller: text,
          minLines: 5,
          maxLines: 10,
          maxLength: 10000,
          decoration: const InputDecoration(
            labelText: '你的两三句话',
            hintText: '今天留下了什么？哪些还在等待，明天从哪里继续？',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
            if (text.text.trim().isEmpty) return;
            try {
              await widget.controller.submit('review.save', {
                'date': widget.day,
                'text': text.text.trim(),
              });
              if (mounted) setState(() => result = '原文已保留。连接电脑后写入日报归档。');
            } catch (e) {
              if (mounted) setState(() => result = e.toString());
            }
          },
          child: const Text('保存今天的回顾'),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(result!),
          ),
        const SizedBox(height: 24),
        const Text('记录来源'),
        for (final review
            in widget.controller.reviews
                .where((r) => r['date'] == widget.day)
                .toList()
                .reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(review['text']),
            subtitle: Text(
              review['archive_status'] == 'saved' ? '已归档到电脑' : '等待电脑归档',
            ),
          ),
      ],
    ),
  );
}
