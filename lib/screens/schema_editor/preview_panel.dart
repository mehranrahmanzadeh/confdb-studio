import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../domain/schema_codec.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';

/// The editor's preview step (between Schema and Signing key): a read-only
/// look at the confdb-schema assertion this draft would sign — its headers,
/// views (with rules), and storage schema (with aliases) — formatted the
/// way confdb's documentation shows a signed assertion.
class PreviewPanel extends StatefulWidget {
  const PreviewPanel({super.key, required this.draft});
  final ConfdbSchema draft;

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  bool _copied = false;
  Timer? _reset;

  String get _text => formatAssertionPreview(widget.draft);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(header: true, child: Text('Preview', style: context.text.titleMedium)),
              ),
              TertiaryButton(label: _copied ? 'Copied' : 'Copy', icon: _copied ? AppIcons.check : AppIcons.copy, onPressed: _copy),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'What `${widget.draft.id.path}` would sign as a confdb-schema assertion: its views and storage schema.',
            style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
              child: SingleChildScrollView(child: SelectableText(_text, style: context.text.bodyMedium?.mono)),
            ),
          ),
        ],
      ),
    );
  }
}
