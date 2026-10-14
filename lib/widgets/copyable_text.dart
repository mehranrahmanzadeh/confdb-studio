import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';
import 'app_icons.dart';

/// An identifier (like `acme/network/wifi-admin`) that can be selected and
/// copied with one click.
class CopyableText extends StatefulWidget {
  const CopyableText(this.text, {super.key, this.style, this.what = 'path'});

  final String text;
  final TextStyle? style;

  /// Names the thing in the tooltip: "Copy path".
  final String what;

  @override
  State<CopyableText> createState() => _CopyableTextState();
}

class _CopyableTextState extends State<CopyableText> {
  bool _copied = false;
  Timer? _reset;

  @override
  void didUpdateWidget(CopyableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _copied = false;
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
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
    final style = (widget.style ?? context.text.bodyMedium!).mono;
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(color: c.surfaceContainerHigh, borderRadius: BorderRadius.circular(ConfdbRadii.chip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: SelectableText(widget.text, style: style, maxLines: 1)),
          IconButton(
            tooltip: _copied ? 'Copied' : 'Copy ${widget.what}',
            onPressed: _copy,
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(_copied ? AppIcons.check : AppIcons.copy),
          ),
        ],
      ),
    );
  }
}
