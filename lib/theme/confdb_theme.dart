// Confdb Studio theme: Ubuntu Yaru dark, expressed as Material 3 roles.
// Source of truth: design/*.dc.html (the TV() palette in each file).
import 'package:flutter/material.dart';

/// Status tokens (success / warning / information). Error uses ColorScheme.error*.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.success,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.information,
    required this.informationContainer,
    required this.onInformationContainer,
  });

  final Color success, successContainer, onSuccessContainer;
  final Color warning, warningContainer, onWarningContainer;
  final Color information, informationContainer, onInformationContainer;

  static const dark = StatusColors(
    success: Color(0xFF5FC36E),
    successContainer: Color(0xFF0E4A18),
    onSuccessContainer: Color(0xFFCFF2D4),
    warning: Color(0xFFF9B54A),
    warningContainer: Color(0xFF4D3000),
    onWarningContainer: Color(0xFFFFE7C2),
    information: Color(0xFF7FB2E5),
    informationContainer: Color(0xFF13365A),
    onInformationContainer: Color(0xFFD6E6F7),
  );

  @override
  StatusColors copyWith() => this;

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) => this;
}

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFE95420), // Ubuntu orange
  onPrimary: Color(0xFF1A0700),
  primaryContainer: Color(0xFF5C2410),
  onPrimaryContainer: Color(0xFFFFDBCC),
  // White and neutral grey instead of the handoff's aubergine; the container
  // sits a step above surfaceContainerHighest so selections stay visible.
  secondary: Color(0xFFFFFFFF),
  onSecondary: Color(0xFF1E1E1E),
  secondaryContainer: Color(0xFF4D4D4D),
  onSecondaryContainer: Color(0xFFFFFFFF),
  tertiary: Color(0xFFC9C1BA), // warm grey
  onTertiary: Color(0xFF2A2420), // derived, not used in the designs
  tertiaryContainer: Color(0xFF3F3934),
  onTertiaryContainer: Color(0xFFEDE7E2),
  error: Color(0xFFF0727C),
  onError: Color(0xFF3B0006),
  errorContainer: Color(0xFF5C1018),
  onErrorContainer: Color(0xFFFFDADC),
  surface: Color(0xFF1E1E1E), // Yaru dark window
  onSurface: Color(0xFFF7F7F7),
  onSurfaceVariant: Color(0xFFBDBDBD),
  surfaceContainerLowest: Color(0xFF181818),
  surfaceContainerLow: Color(0xFF242424),
  surfaceContainer: Color(0xFF2A2A2A),
  surfaceContainerHigh: Color(0xFF303030), // Yaru dark header bar
  surfaceContainerHighest: Color(0xFF3A3A3A),
  outline: Color(0xFF8E8E8E),
  outlineVariant: Color(0xFF454545),
  inverseSurface: Color(0xFFEDEDED),
  onInverseSurface: Color(0xFF2A2A2A),
  inversePrimary: Color(0xFFCF4413),
  scrim: Color(0xFF000000),
  shadow: Color(0xFF000000),
);

/// Shapes from the designs: buttons/fields 6, cards/dialogs 12, chips 8, switches pill.
abstract final class ConfdbRadii {
  static const button = 6.0;
  static const field = 4.0;
  static const chip = 8.0;
  static const typeChip = 6.0;
  static const card = 12.0;
  static const dialog = 12.0;
  static const railIndicator = 8.0;
}

/// Monospace style for paths, identifiers, CLI commands, JSON and logs only.
const monoFamily = 'Ubuntu Sans Mono';

ThemeData confdbDarkTheme() {
  const scheme = _darkScheme;
  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.button));
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Ubuntu Sans',
    scaffoldBackgroundColor: scheme.surface,
    extensions: const [StatusColors.dark],
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainerHigh,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.railIndicator)),
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      labelType: NavigationRailLabelType.all,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: buttonShape, minimumSize: const Size(0, 40)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: buttonShape,
        foregroundColor: scheme.secondary,
        side: BorderSide(color: scheme.outline),
        minimumSize: const Size(0, 40),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: buttonShape, foregroundColor: scheme.secondary, minimumSize: const Size(0, 40)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(buttonShape))),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(ConfdbRadii.field)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ConfdbRadii.field),
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ConfdbRadii.field),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ConfdbRadii.field),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLowest,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ConfdbRadii.card),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.dialog)),
    ),
    chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ConfdbRadii.chip))),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      actionTextColor: scheme.inversePrimary,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
