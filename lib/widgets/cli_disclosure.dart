import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';
import 'app_icons.dart';

/// Cli.dc.html: shows the exact command an action maps to, with a copy button.
class CliDisclosure extends StatefulWidget {
  const CliDisclosure(this.command, {super.key, this.label = 'CLI', this.initiallyOpen = false});

  final String command;
  final String label;
  final bool initiallyOpen;

  @override
  State<CliDisclosure> createState() => _CliDisclosureState();
}

class _CliDisclosureState extends State<CliDisclosure> {
  late bool _open = widget.initiallyOpen;
  bool _copied = false;
  Timer? _reset;

  @override
  void didUpdateWidget(CliDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.command != widget.command) _copied = false;
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.command));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final copyLabel = _copied ? 'Copied' : 'Copy command';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: 'Show the equivalent command',
          child: Semantics(
            expanded: _open,
            child: TextButton(
              onPressed: () => setState(() => _open = !_open),
              style: TextButton.styleFrom(
                foregroundColor: c.onSurfaceVariant,
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
                textStyle: context.text.labelMedium?.copyWith(letterSpacing: 0.4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AppIcons.terminal, size: 16),
                  const SizedBox(width: 6),
                  Text(widget.label),
                  const SizedBox(width: 6),
                  Icon(_open ? AppIcons.expand : AppIcons.chevronRight, size: 16),
                ],
              ),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(ConfdbRadii.chip)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SelectableText(widget.command, style: context.text.bodyMedium?.mono.copyWith(fontSize: 13, color: c.onSurface)),
                ),
                const SizedBox(width: 8),
                IconButton(tooltip: copyLabel, onPressed: _copy, icon: Icon(_copied ? AppIcons.check : AppIcons.copy, size: 18)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
