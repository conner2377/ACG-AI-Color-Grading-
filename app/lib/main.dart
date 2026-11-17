import 'package:flutter/material.dart';

import 'ui/editor_page.dart';
import 'ui/widgets.dart';

void main() {
  runApp(const AcgApp());
}

class AcgApp extends StatelessWidget {
  const AcgApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ACG - AI Color Grading',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0B0B0B),
        useMaterial3: true,
      ),
      home: const EditorPage(),
    );
  }
}
