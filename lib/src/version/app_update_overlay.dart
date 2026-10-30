import 'package:flutter/material.dart';

import '../ui/strings.dart';
import 'app_update_controller.dart';

/// Wraps the app and shows a "new version" card when a newer InfraGIS release goes live while the
/// page stays open. It never reloads by itself and stays hidden while [busy] (a sync running).
class AppUpdateOverlay extends StatefulWidget {
  const AppUpdateOverlay({super.key, required this.child, required this.busy, this.listenable, this.controller});

  final Widget child;
  final bool Function() busy;

  /// Notifies when [busy] may have changed.
  final Listenable? listenable;
  final AppUpdateController? controller;

  @override
  State<AppUpdateOverlay> createState() => _AppUpdateOverlayState();
}

class _AppUpdateOverlayState extends State<AppUpdateOverlay> {
  late final AppUpdateController _controller = widget.controller ?? AppUpdateController();

  // MaterialApp.builder sits above the Navigator and its Overlay, so the notice brings its own:
  // without one the close button tooltip throws on hover and the release build replaces the card
  // with a grey error box.
  late final OverlayEntry _entry = OverlayEntry(builder: _buildContent);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    widget.listenable?.addListener(_onChanged);
    _controller.start();
  }

  @override
  void didUpdateWidget(AppUpdateOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable?.removeListener(_onChanged);
      widget.listenable?.addListener(_onChanged);
    }
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    widget.listenable?.removeListener(_onChanged);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);

  Widget _buildContent(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_controller.noticeVisible && !widget.busy())
          Positioned(
            left: mobile ? 8 : null,
            right: mobile ? 8 : 24,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: mobile ? 8 : 24),
                child: _AppUpdateNotice(controller: _controller),
              ),
            ),
          ),
      ],
    );
  }
}

class _AppUpdateNotice extends StatelessWidget {
  const _AppUpdateNotice({required this.controller});

  final AppUpdateController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final version = controller.deployed?.version;
    final critical = controller.critical;
    final title = tr(context, critical ? 'updateImportant' : 'updateAvailable');

    return Semantics(
      liveRegion: true,
      container: true,
      label: title,
      child: Material(
        elevation: 6,
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 380),
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: critical ? colorScheme.primary : colorScheme.outlineVariant,
              width: critical ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(critical ? Icons.system_update : Icons.auto_awesome, color: colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(TextSpan(
                      text: title,
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      children: [
                        if (version != null)
                          TextSpan(
                            text: '  v$version',
                            style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                      ],
                    )),
                    const SizedBox(height: 4),
                    Text(
                      tr(context, 'updateHelp'),
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.4),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (!critical) TextButton(onPressed: controller.postpone, child: Text(tr(context, 'updateLater'))),
                        FilledButton.icon(
                          onPressed: controller.reloadNow,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(tr(context, 'updateNow')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!critical)
                IconButton(
                  tooltip: tr(context, 'updateLater'),
                  onPressed: controller.postpone,
                  icon: const Icon(Icons.close),
                  color: colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
