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
  bool busy = false;
  String? generationId, generationInput;

  Future<void> addMaterial() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: [
        'pdf',
        'docx',
        'md',
        'txt',
        'csv',
        'json',
        'py',
        'log',
        'tex',
        'rst',
      ],
    );
    if (file == null || !mounted) return;
    final size = await file.length();
    if (!mounted) return;
    if (size == null || size > 8 * 1024 * 1024) {
      setState(() => result = '文件不能超过 8 MB。');
      return;
    }
    final description = TextEditingController();
    var allowed = true;
    final accepted = await showOwnedDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('添加学习或实验材料'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(file.name),
                  TextField(
                    controller: description,
                    maxLength: 2000,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '材料说明',
                      hintText: '这份材料留下了什么，哪些结论还待验证？',
                    ),
                  ),
                  CheckboxListTile(
                    value: allowed,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (value) =>
                        setDialog(() => allowed = value ?? false),
                    title: const Text('生成复盘时把提取的文字发送给模型'),
                    subtitle: const Text('取消勾选时，只发送你填写的说明。原文件保存在电脑。'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('上传到电脑'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && mounted) {
      setState(() => busy = true);
      try {
        await widget.controller.uploadMaterial(
          file.name,
          widget.day,
          description.text.trim(),
          allowed,
          await file.readAsBytes(),
        );
        if (mounted) setState(() => result = '材料已保存到电脑。');
      } catch (e) {
        if (mounted) setState(() => result = e.toString());
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }
    description.dispose();
  }

  Future<void> generate() async {
    if (text.text.trim().isEmpty) {
      setState(() => result = '先写下今天的产出、卡点或下一步。');
      return;
    }
    final ids = (widget.controller.state['materials'] as List? ?? [])
        .cast<Json>()
        .where((m) => m['date'] == widget.day)
        .map((m) => m['id'] as String)
        .toList();
    final signature = '${widget.day}|${text.text}|${ids.join(',')}';
    if (generationInput != signature) {
      generationInput = signature;
      generationId = const Uuid().v4();
    }
    setState(() {
      busy = true;
      result = '正在依据原文和材料复盘，输入会先保存。';
    });
    try {
      await widget.controller.generateReview(
        widget.day,
        text.text.trim(),
        ids,
        generationId!,
      );
      if (mounted) setState(() => result = '复盘已生成并归档到电脑。');
    } catch (e) {
      if (mounted) setState(() => result = '$e；你的原文与已上传材料会保留。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

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
    final day = widget.day;
    final baseline = text.text;
    final version =
        widget.controller.reviews
            .where((r) => r['date'] == day)
            .lastOrNull?['version'] ??
        0;
    widget.controller.storage.read('review.draft.$day').then((draft) {
      if (mounted &&
          widget.day == day &&
          draft != null &&
          text.text == baseline) {
        try {
          final saved = jsonDecode(draft) as Json;
          if (saved['version'] == version) {
            setState(() => text.text = saved['text']);
          }
        } catch (_) {
          if (version == 0 && text.text.isEmpty) {
            setState(() => text.text = draft);
          }
        }
      }
    });
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
        Text('${widget.day} · 放进今天的笔记或实验报告，写两三句产出、卡点和下一步，助手据此帮你总结。'),
        const SizedBox(height: 24),
        for (final material
            in (widget.controller.state['materials'] as List? ?? [])
                .cast<Json>()
                .where((m) => m['date'] == widget.day))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(material['name']),
            subtitle: Text(
              material['external_allowed'] == true
                  ? '生成时发送提取文字 · ${material['characters']} 字'
                  : '仅说明进入模型，原文留在电脑',
            ),
            trailing: IconButton(
              tooltip: '移除材料',
              icon: const Icon(Icons.close),
              onPressed: busy
                  ? null
                  : () async {
                      try {
                        await widget.controller.submit('material.delete', {
                          'id': material['id'],
                        });
                        if (mounted) setState(() {});
                      } catch (e) {
                        if (mounted) setState(() => result = e.toString());
                      }
                    },
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('review.add-material'),
            onPressed: busy ? null : addMaterial,
            icon: const Icon(Icons.attach_file),
            label: const Text('添加笔记或实验报告'),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: text,
          onChanged: (value) => widget.controller.storage.write(
            'review.draft.${widget.day}',
            jsonEncode({
              'text': value,
              'version':
                  widget.controller.reviews
                      .where((r) => r['date'] == widget.day)
                      .lastOrNull?['version'] ??
                  0,
            }),
          ),
          minLines: 5,
          maxLines: 10,
          maxLength: 10000,
          decoration: const InputDecoration(
            labelText: '你的两三句话',
            hintText: '今天留下了什么？哪些还在等待，明天从哪里继续？',
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const Key('review.generate'),
              onPressed: busy ? null : generate,
              child: Text(busy ? '处理中…' : '生成 AI 复盘'),
            ),
            OutlinedButton(
              key: const Key('review.save'),
              onPressed: busy
                  ? null
                  : () async {
                      if (text.text.trim().isEmpty) return;
                      try {
                        await widget.controller.submit('review.save', {
                          'date': widget.day,
                          'text': text.text.trim(),
                        });
                        if (mounted) {
                          setState(() => result = '原文已保留。连接电脑后写入日报归档。');
                        }
                      } catch (e) {
                        if (mounted) setState(() => result = e.toString());
                      }
                    },
              child: const Text('只保存原文'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('收尾时自动生成复盘'),
          subtitle: const Text('依据当天已保存的文字和材料；没有你的文字时先询问。'),
          value:
              widget.controller.settings['auto_daily_review'] as bool? ?? true,
          onChanged: busy
              ? null
              : (value) async {
                  try {
                    await widget.controller.submit('settings.update', {
                      'auto_daily_review': value,
                    });
                    if (mounted) setState(() {});
                  } catch (e) {
                    if (mounted) setState(() => result = e.toString());
                  }
                },
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(result!),
          ),
        const SizedBox(height: 24),
        for (final analysis
            in (widget.controller.state['analyses'] as List? ?? [])
                .cast<Json>()
                .where((a) => a['date'] == widget.day)
                .toList()
                .reversed
                .take(1)) ...[
          Text('助手复盘', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          SelectableText(analysis['text']),
          const SizedBox(height: 8),
          Text(
            '生成内容 · ${analysis['model']} · 依据已保存原文与所选材料核对',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
        ],
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
