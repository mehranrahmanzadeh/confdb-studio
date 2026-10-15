import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/account_names.dart';
import '../theme/app_theme.dart';
import '../theme/confdb_theme.dart';
import 'app_icons.dart';

/// An identifier (like `acme/network/wifi-admin`) that can be copied with one
/// click. Account IDs show as their aliases; the copy is the real text.
class CopyableText extends StatefulWidget {
  const CopyableText(this.text, {super.key, this.style, this.what = 'path', this.alias = true});

  final String text;
  final TextStyle? style;

  /// Names the thing in the tooltip: "Copy path".
  final String what;

  /// Show account IDs in [text] as their aliases. Off where the ID itself is the point.
  final bool alias;

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
    final shown = widget.alias ? context.aliased(widget.text) : widget.text;
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(color: c.surfaceContainerHigh, borderRadius: BorderRadius.circular(ConfdbRadii.chip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: shown == widget.text
                ? SelectableText(shown, style: style, maxLines: 1)
                // The real path, with the account ID, on hover.
                : Tooltip(
                    message: widget.text,
                    child: Text(shown, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
          ),
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
