// Visual language: a calm, warm dark studio. Soft rounded surfaces, one coral→pink
// accent for the things that matter, quiet text everywhere else.

import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF101013);
  static const canvas = Color(0xFF09090B);
  static const surface = Color(0xFF18181C);
  static const surface2 = Color(0xFF222228);
  static const surface3 = Color(0xFF2C2C33);
  static const line = Color(0xFF2E2E36);
  static const text = Color(0xFFF3F3F6);
  static const textDim = Color(0xFFA3A3AE);
  static const textFaint = Color(0xFF6E6E7A);
  static const accent = Color(0xFFFF8A5C);
  static const accent2 = Color(0xFFFF5C8A);
}

const accentGradient = LinearGradient(
  colors: [AppColors.accent, AppColors.accent2],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: Colors.white,
    secondary: AppColors.accent2,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    surfaceContainerHighest: AppColors.surface2,
    outline: AppColors.line,
  );
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: 'Segoe UI',
    fontFamilyFallback: const ['Malgun Gothic', 'Apple SD Gothic Neo', 'Noto Sans KR'],
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        shape: rounded,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.line),
        shape: rounded,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.textDim, shape: rounded),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.textDim, disabledForegroundColor: AppColors.textFaint.withValues(alpha: 0.5)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surface2,
      selectedColor: AppColors.accent.withValues(alpha: 0.18),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
      secondaryLabelStyle: const TextStyle(color: AppColors.accent, fontSize: 12.5),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface2,
      hintStyle: const TextStyle(color: AppColors.textFaint, fontSize: 13.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surface3,
      contentTextStyle: const TextStyle(color: AppColors.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: AppColors.surface3, borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(color: AppColors.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 350),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.accent : AppColors.surface3),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.12)),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(4),
    ),
  );
}
