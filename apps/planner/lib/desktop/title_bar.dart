import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/seal.dart';
import 'desktop_window.dart';

/// Frameless-window title bar painted on the same paper as the page, so the
/// window has no separate chrome. Drag anywhere empty; double-click maximizes.
class InkTitleBar extends StatelessWidget {
  const InkTitleBar({super.key, this.title, this.compact = false});
  final String? title;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final w = DesktopWindow.instance;
    final p = context.inkPalette;
    return AnimatedBuilder(
      animation: w.changes,
      builder: (context, _) => SizedBox(
        height: compact ? 40 : 44,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => w.startDragging(),
                onDoubleTap: compact ? null : w.toggleMaximize,
                child: Padding(
                  padding: EdgeInsets.only(left: compact ? 14 : 18),
                  child: Row(
                    children: [
                      if (!compact) ...[
                        const Seal('日程', label: '日程之间', size: 20),
                        const SizedBox(width: 12),
                        Text(
                          '日程之间',
                          style: TextStyle(
                            fontFamily: 'WenKai',
                            fontSize: 14,
                            color: p.inkNong,
                          ),
                        ),
                      ],
                      if (title != null) ...[
                        if (!compact)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text('·', style: TextStyle(color: p.inkDan)),
                          ),
                        Flexible(
                          child: Text(
                            title!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'WenKai',
                              fontSize: compact ? 15 : 14,
                              color: compact ? p.inkJiao : p.inkZhong,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (compact) ...[
              _ChromeButton(
                tooltip: '展开为完整窗口',
                icon: Icons.open_in_full,
                onPressed: () => w.setWidgetMode(false),
              ),
              _ChromeButton(
                tooltip: w.pinned.value ? '取消置顶' : '置顶',
                icon: w.pinned.value ? Icons.push_pin : Icons.push_pin_outlined,
                selected: w.pinned.value,
                onPressed: () => w.setPinned(!w.pinned.value),
              ),
              _OpacityButton(window: w),
            ] else ...[
              _ChromeButton(
                tooltip: '收成桌面挂件',
                icon: Icons.picture_in_picture_alt_outlined,
                onPressed: () => w.setWidgetMode(true),
              ),
              _ChromeButton(
                tooltip: w.pinned.value ? '取消置顶' : '窗口置顶',
                icon: w.pinned.value ? Icons.push_pin : Icons.push_pin_outlined,
                selected: w.pinned.value,
                onPressed: () => w.setPinned(!w.pinned.value),
              ),
              const SizedBox(width: 6),
              _ChromeButton(
                tooltip: '最小化',
                icon: Icons.remove,
                onPressed: w.minimize,
              ),
              _ChromeButton(
                tooltip: w.maximized.value ? '还原' : '最大化',
                icon: w.maximized.value ? Icons.filter_none : Icons.crop_square,
                iconSize: w.maximized.value ? 14 : 16,
                onPressed: w.toggleMaximize,
              ),
            ],
            _ChromeButton(
              tooltip: '关闭',
              icon: Icons.close,
              danger: true,
              onPressed: w.close,
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class _ChromeButton extends StatefulWidget {
  const _ChromeButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.danger = false,
    this.iconSize = 17,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected, danger;
  final double iconSize;
  @override
  State<_ChromeButton> createState() => _ChromeButtonState();
}

class _ChromeButtonState extends State<_ChromeButton> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final fill = hover
        ? (widget.danger ? p.inkJiao : p.washStrong)
        : widget.selected
        ? p.wash
        : p.paper.withValues(alpha: 0);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => hover = true),
          onExit: (_) => setState(() => hover = false),
          child: GestureDetector(
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: InkMetrics.micro,
              width: 36,
              height: 30,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: hover && widget.danger
                    ? p.paper
                    : widget.selected
                    ? p.inkJiao
                    : p.inkZhong,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OpacityButton extends StatelessWidget {
  const _OpacityButton({required this.window});
  final DesktopWindow window;
  @override
  Widget build(BuildContext context) => _ChromeButton(
    tooltip: '透明度',
    icon: Icons.opacity,
    onPressed: () => showDialog<void>(
      context: context,
      barrierColor: context.inkPalette.bloom.withValues(alpha: .08),
      builder: (context) => Dialog(
        alignment: Alignment.topRight,
        insetPadding: const EdgeInsets.only(top: 44, right: 8),
        child: SizedBox(
          width: 240,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: ValueListenableBuilder(
              valueListenable: window.opacity,
              builder: (context, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '挂件透明度 ${(value * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Slider(
                    value: value,
                    min: .5,
                    max: 1,
                    divisions: 10,
                    onChanged: window.setOpacity,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
