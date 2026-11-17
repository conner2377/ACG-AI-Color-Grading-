import 'package:flutter/material.dart';

import 'ui/editor_page.dart';
import 'ui/widgets.dart';

void main(List<String> args) {
  // A photo path may be passed on the command line ("Open with" / drag onto the icon).
  final photo = args.where((a) => !a.startsWith('-')).firstOrNull;
  runApp(AcgApp(initialPhoto: photo));
}

ThemeData buildTheme(String? fontFamily) {
  final shape10 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  return ThemeData(
    brightness: Brightness.dark,
    fontFamily: fontFamily ?? 'Pretendard',
    colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
      primary: accent,
      onPrimary: onAccent,
      secondaryContainer: const Color(0xFF2A2442),
      onSecondaryContainer: Colors.white,
      surfaceContainerHighest: cardColor,
      outline: borderColor,
      outlineVariant: borderColor,
      surface: surfaceColor,
    ),
    scaffoldBackgroundColor: bgColor,
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF17171E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: borderColor)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: cardColor,
      selectedColor: accentDim,
      side: const BorderSide(color: borderColor),
      shape: const StadiumBorder(side: BorderSide(color: borderColor)),
      secondaryLabelStyle: const TextStyle(color: accent, fontWeight: FontWeight.w600),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xFF1B1B23),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: borderColor)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF15151C),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accent)),
      hintStyle: const TextStyle(color: Color(0xFF6E6E7C)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape10)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: shape10, side: const BorderSide(color: borderColor), foregroundColor: Colors.white),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape10)),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shape10),
        side: const WidgetStatePropertyAll(BorderSide(color: borderColor)),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : const Color(0xFF2A2A34)),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(thumbColor: Colors.white),
    dividerColor: borderColor,
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: const Color(0xFF22222B), border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontSize: 12, color: Colors.white),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF22222B),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    useMaterial3: true,
  );
}

class AcgApp extends StatelessWidget {
  const AcgApp({super.key, this.initialPhoto, this.initialTab = 0, this.fontFamily});
  final String? initialPhoto;
  final int initialTab;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ACG - AI Color Grading',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(fontFamily),
      home: EditorPage(initialPhoto: initialPhoto, initialTab: initialTab),
    );
  }
}
