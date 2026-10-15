import 'package:flutter/material.dart';

import '../state/account_names.dart';
import '../theme/app_theme.dart';

/// Text where `backticked` parts are identifiers set in mono, as in the
/// designs' `PT()` helper: "Connect `browser-proxy:proxy-state`".
class CodeText extends StatelessWidget {
  const CodeText(this.text, {super.key, this.style, this.codeColor, this.codeWeight, this.maxLines, this.overflow});

  final String text;
  final TextStyle? style;

  /// Color for the mono parts; defaults to the surrounding text color.
  final Color? codeColor;
  final FontWeight? codeWeight;
  final int? maxLines;
  final TextOverflow? overflow;

  static List<InlineSpan> spans(String text, TextStyle base, {Color? codeColor, FontWeight? codeWeight}) {
    final parts = text.split('`');
    return [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].isNotEmpty)
          TextSpan(
            text: parts[i],
            style: i.isOdd ? base.mono.copyWith(color: codeColor ?? base.color, fontWeight: codeWeight ?? base.fontWeight) : null,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    return Text.rich(
      TextSpan(
        style: base,
        // Sentences name accounts by alias; commands (CliDisclosure) keep the ID.
        children: spans(context.aliased(text), base, codeColor: codeColor, codeWeight: codeWeight),
      ),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// Text in Ubuntu Sans Mono: paths, identifiers, CLI, JSON and logs.
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.style, this.maxLines, this.overflow, this.selectable = false});

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final s = (style ?? DefaultTextStyle.of(context).style).mono;
    if (selectable) return SelectableText(text, style: s, maxLines: maxLines);
    return Text(text, style: s, maxLines: maxLines, overflow: overflow);
  }
}
