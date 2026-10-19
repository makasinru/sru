import 'package:flutter/material.dart';

/// Палитра повторяет AmneziaStyle.qml (client/ui/qml/Modules/Style).
class SruColors {
  static const bgBase = Color(0xFF101012);
  static const bgSurface = Color(0xFF18181B);
  static const bgSurfaceAlt = Color(0xFF1F1F23);
  static const bgSheet = Color(0xFF313136);
  static const border = Color(0xFF3F3F46);
  static const textPrimary = Color(0xFFFAFAFA);
  static const textSecondary = Color(0xFFE4E4E7);
  static const textTertiary = Color(0xFFA1A1AA);
  static const accent = Color(0xFFFDBA74);
  static const accentDefault = Color(0xFFF59E0B);
  static const accentDark = Color(0xFFD97706);
  static const action = Color(0xFFE4E4E7);
  static const destructive = Color(0xFFF87171);
  static const success = Color(0xFF4ADE80);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    surface: SruColors.bgBase,
    surfaceContainer: SruColors.bgSurface,
    surfaceContainerHigh: SruColors.bgSurfaceAlt,
    primary: SruColors.accent,
    onPrimary: Color(0xFF09090B),
    secondary: SruColors.action,
    error: SruColors.destructive,
    onSurface: SruColors.textPrimary,
    onSurfaceVariant: SruColors.textTertiary,
    outline: SruColors.border,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: SruColors.bgBase,
    appBarTheme: const AppBarTheme(backgroundColor: SruColors.bgBase, elevation: 0, centerTitle: false),
    cardTheme: CardThemeData(
      color: SruColors.bgSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: SruColors.action,
        foregroundColor: const Color(0xFF09090B),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SruColors.textPrimary,
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: SruColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SruColors.bgSurfaceAlt,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: SruColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: SruColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: SruColors.textSecondary),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: SruColors.bgSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: SruColors.bgSurface,
      indicatorColor: SruColors.bgSheet,
    ),
  );
}
