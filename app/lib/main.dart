import 'package:flutter/material.dart';

import 'ui/editor_page.dart';
import 'ui/widgets.dart';

void main(List<String> args) {
  // A photo path may be passed on the command line ("Open with" / drag onto the icon).
  final photo = args.where((a) => !a.startsWith('-')).firstOrNull;
  runApp(AcgApp(initialPhoto: photo));
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
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: fontFamily,
        colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
          primary: accent,
          onPrimary: onAccent,
          surfaceContainerHighest: cardColor,
          outline: borderColor,
          outlineVariant: borderColor,
          surface: surfaceColor,
        ),
        scaffoldBackgroundColor: bgColor,
        dialogTheme: DialogThemeData(backgroundColor: cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        chipTheme: ChipThemeData(
          backgroundColor: cardColor,
          selectedColor: accentDim,
          side: const BorderSide(color: borderColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          secondaryLabelStyle: const TextStyle(color: accent, fontWeight: FontWeight.w600),
        ),
        popupMenuTheme: PopupMenuThemeData(color: cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        dividerColor: borderColor,
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(color: cardColor, border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(4)),
          textStyle: const TextStyle(fontSize: 12, color: Colors.white),
        ),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
        useMaterial3: true,
      ),
      home: EditorPage(initialPhoto: initialPhoto, initialTab: initialTab),
    );
  }
}
