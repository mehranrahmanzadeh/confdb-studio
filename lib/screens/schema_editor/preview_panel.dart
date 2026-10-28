import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../domain/schema_codec.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';

/// The editor's preview step (between Schema and Signing key): a read-only
/// look at the confdb-schema assertion this draft would sign — its headers,
/// views (with rules), and storage schema (with aliases) — formatted the
/// way confdb's documentation shows a signed assertion.
class PreviewPanel extends StatefulWidget {
  const PreviewPanel({super.key, required this.draft, required this.base});
  final ConfdbSchema draft;
  final ConfdbSchema? base;

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  bool _copied = false;
  bool _showChanges = false;
  Timer? _reset;

  String get _text => formatAssertionPreview(widget.draft);
  List<SchemaDiffLine> get _changes => diffSchemas(widget.base, widget.draft);

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(header: true, child: Text('Review before signing', style: context.text.titleMedium)),
                    Text(
                      widget.base == null
                          ? 'New schema · ${_changes.length} additions'
                          : 'Based on revision ${widget.base!.revision ?? '?'} · ${_changes.length} changes',
                      style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Changes')),
                  ButtonSegment(value: false, label: Text('Assertion')),
                ],
                selected: {_showChanges},
                onSelectionChanged: (value) => setState(() => _showChanges = value.first),
              ),
              const SizedBox(width: 8),
              TertiaryButton(
                label: _copied ? 'Copied' : 'Copy assertion',
                icon: _copied ? AppIcons.check : AppIcons.copy,
                onPressed: _copy,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _showChanges
                ? 'Review the storage and view changes before signing `${widget.draft.id.path}`.'
                : 'The exact confdb-schema assertion input for `${widget.draft.id.path}`.',
            style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
              child: _showChanges
                  ? _ChangeList(changes: _changes)
                  : SingleChildScrollView(child: SelectableText(_text, style: context.text.bodyMedium?.mono)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChangeList extends StatelessWidget {
  const _ChangeList({required this.changes});
  final List<SchemaDiffLine> changes;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (changes.isEmpty) {
      return Center(
        child: Text(
          'No schema changes from the acknowledged revision.',
          style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: changes.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: c.outlineVariant),
      itemBuilder: (context, index) {
        final change = changes[index];
        final color = change.added ? c.tertiary : c.error;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(change.added ? '+' : '−', style: context.text.titleSmall?.copyWith(color: color)),
              ),
              SizedBox(
                width: 100,
                child: Text(change.where, style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant)),
              ),
              Expanded(child: SelectableText(change.what, style: context.text.bodyMedium?.mono)),
            ],
          ),
        );
      },
    );
  }
}
