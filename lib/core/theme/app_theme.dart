import 'package:flutter/material.dart';

/// Tema de escritorio, con paleta tipo GitHub (claro / oscuro).
class AppTheme {
  const AppTheme._();

  static const _seed = Color(0xFF24292F);

  static ThemeData light() => _build(
        ColorScheme.fromSeed(seedColor: _seed).copyWith(
          primary: const Color(0xFF0969DA),
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFDDF4FF),
          onPrimaryContainer: const Color(0xFF0A3069),
          surface: const Color(0xFFFFFFFF),
          surfaceContainerLowest: const Color(0xFFFFFFFF),
          surfaceContainerLow: const Color(0xFFF6F8FA),
          surfaceContainer: const Color(0xFFF0F3F6),
          surfaceContainerHigh: const Color(0xFFEAEEF2),
          surfaceContainerHighest: const Color(0xFFE1E6EB),
          outlineVariant: const Color(0xFFD0D7DE),
        ),
      );

  static ThemeData dark() => _build(
        ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark).copyWith(
          primary: const Color(0xFF58A6FF),
          onPrimary: const Color(0xFF051D36),
          primaryContainer: const Color(0xFF1F3A5F),
          onPrimaryContainer: const Color(0xFFCAE4FF),
          surface: const Color(0xFF161B22),
          onSurface: const Color(0xFFE6EDF3),
          onSurfaceVariant: const Color(0xFF8D96A0),
          surfaceContainerLowest: const Color(0xFF0D1117),
          surfaceContainerLow: const Color(0xFF13181F),
          surfaceContainer: const Color(0xFF1C2128),
          surfaceContainerHigh: const Color(0xFF22272E),
          surfaceContainerHighest: const Color(0xFF2D333B),
          outline: const Color(0xFF545D68),
          outlineVariant: const Color(0xFF30363D),
        ),
      );

  static ThemeData _build(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.compact,
      dividerColor: scheme.outlineVariant,
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(scheme.onSurfaceVariant.withValues(alpha: 0.35)),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: TextStyle(fontSize: 12, color: dark ? const Color(0xFF0D1117) : Colors.white),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFE6EDF3) : const Color(0xFF24292F),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: border(scheme.outlineVariant),
        enabledBorder: border(scheme.outlineVariant),
        focusedBorder: border(scheme.primary, 1.5),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, width: 440),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}
