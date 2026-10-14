// App-level additions on top of confdb_theme.dart (which is kept as delivered).
// Adds the TextTheme weights from ComponentSheet.dc.html, the 3px secondary
// focus ring for buttons, and context helpers for status colors and mono text.
import 'package:flutter/material.dart';

import 'confdb_theme.dart';

/// Fallback for glyphs the Ubuntu fonts lack (→, ←).
const arrowsFamily = 'Confdb Arrows';

ThemeData buildAppTheme() {
  final base = confdbDarkTheme();
  final scheme = base.colorScheme;
  final t = base.textTheme;

  // ComponentSheet "TextTheme in use": headlines and titles are w500.
  final textTheme = t
      .copyWith(
        displaySmall: t.displaySmall?.copyWith(fontSize: 36, height: 44 / 36, fontWeight: FontWeight.w400),
        headlineMedium: t.headlineMedium?.copyWith(fontSize: 28, height: 36 / 28, fontWeight: FontWeight.w500),
        headlineSmall: t.headlineSmall?.copyWith(fontSize: 24, height: 32 / 24, fontWeight: FontWeight.w500),
        titleLarge: t.titleLarge?.copyWith(fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w500),
        titleMedium: t.titleMedium?.copyWith(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w500),
        titleSmall: t.titleSmall?.copyWith(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600),
        bodyLarge: t.bodyLarge?.copyWith(fontSize: 16, height: 24 / 16),
        bodyMedium: t.bodyMedium?.copyWith(fontSize: 14, height: 20 / 14),
        bodySmall: t.bodySmall?.copyWith(fontSize: 12, height: 16 / 12),
        labelLarge: t.labelLarge?.copyWith(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500),
        labelMedium: t.labelMedium?.copyWith(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500),
      )
      .apply(fontFamilyFallback: const [arrowsFamily]);

  // Focus: 10% state layer (Material default) + 3px secondary ring.
  final focusRing = WidgetStateProperty.resolveWith<BorderSide?>((states) {
    if (states.contains(WidgetState.focused)) {
      return BorderSide(color: scheme.secondary, width: 3);
    }
    return null;
  });
  final outlinedSide = WidgetStateProperty.resolveWith<BorderSide?>((states) {
    if (states.contains(WidgetState.disabled)) {
      return BorderSide(color: scheme.onSurface.withValues(alpha: 0.12));
    }
    if (states.contains(WidgetState.focused)) {
      return BorderSide(color: scheme.secondary, width: 3);
    }
    return BorderSide(color: scheme.outline);
  });

  // Flutter's default is a hand cursor on the web only; desktop gets the
  // arrow. Use the hand wherever something is clickable.
  const clickable = WidgetStateMouseCursor.clickable;

  return base.copyWith(
    textTheme: textTheme,
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style!.copyWith(side: focusRing, mouseCursor: clickable),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style!.copyWith(side: outlinedSide, mouseCursor: clickable),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style!.copyWith(side: focusRing, mouseCursor: clickable),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        mouseCursor: clickable,
        foregroundColor: WidgetStatePropertyAll(scheme.onSurfaceVariant),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.button))),
        side: focusRing,
        minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: base.segmentedButtonTheme.style!.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? scheme.secondaryContainer : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? scheme.onSecondaryContainer : scheme.onSurface,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        mouseCursor: clickable,
      ),
    ),
    menuButtonTheme: const MenuButtonThemeData(style: ButtonStyle(mouseCursor: clickable)),
    popupMenuTheme: base.popupMenuTheme.copyWith(mouseCursor: clickable),
    listTileTheme: base.listTileTheme.copyWith(mouseCursor: clickable),
    // The base SnackBar style has no font family; keep it in Ubuntu Sans.
    snackBarTheme: base.snackBarTheme.copyWith(contentTextStyle: textTheme.bodyMedium?.copyWith(color: scheme.onInverseSurface)),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(4)),
      textStyle: textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.transparent : scheme.outline,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.field))),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.secondary, linearTrackColor: scheme.secondaryContainer),
  );
}

extension ConfdbThemeContext on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  StatusColors get status => Theme.of(this).extension<StatusColors>()!;
}

/// Monospace only for paths, identifiers, CLI, JSON and logs.
extension MonoStyle on TextStyle {
  TextStyle get mono => copyWith(fontFamily: monoFamily, fontFamilyFallback: const [arrowsFamily]);
}
