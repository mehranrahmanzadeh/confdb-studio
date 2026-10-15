import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/account_names.dart';
import '../theme/app_theme.dart';

/// An account shown by its alias (store username). Hovering shows the
/// account ID; clicking copies it.
class AccountName extends StatefulWidget {
  const AccountName(this.id, {super.key, this.style});
  final String id;
  final TextStyle? style;

  @override
  State<AccountName> createState() => _AccountNameState();
}

class _AccountNameState extends State<AccountName> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.id));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (AccountNames.isReserved(widget.id)) return Text(widget.id, style: widget.style);
    final info = context.accounts?.info(widget.id);
    final alias = info?.alias ?? widget.id;
    final name = info?.displayName;
    final tip = _copied
        ? 'Copied account ID'
        : [if (name != null && name != alias) name, 'Account ID: ${widget.id}', 'Click to copy'].join('\n');
    return Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        label: 'Account $alias. Copy account ID',
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _copy,
            child: Text(
              alias,
              style: (widget.style ?? DefaultTextStyle.of(context).style).copyWith(
                decoration: TextDecoration.underline,
                decorationStyle: TextDecorationStyle.dotted,
                decorationColor: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A schema or view path (`<account>/<schema>[/<view>]`) whose account shows
/// as an [AccountName]: hover for the ID, click to copy it.
class AccountPath extends StatelessWidget {
  const AccountPath(this.path, {super.key, this.style, this.maxLines, this.overflow});
  final String path;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final slash = path.indexOf('/');
    if (slash <= 0) return Text(path, style: base, maxLines: maxLines, overflow: overflow);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: AccountName(path.substring(0, slash), style: base),
          ),
          TextSpan(text: path.substring(slash)),
        ],
      ),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
