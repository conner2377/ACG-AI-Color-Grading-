import 'package:flutter/material.dart';

import 'ui/editor_page.dart';
import 'ui/theme.dart';

/// A photo path on the command line (e.g. "Open with ACG" or dropping a file on the
/// exe) is opened right away.
void main(List<String> args) {
  runApp(AcgApp(initialPath: args.isEmpty ? null : args.first));
}

class AcgApp extends StatelessWidget {
  const AcgApp({super.key, this.initialPath});
  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ACG - AI Color Grading',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: EditorPage(initialPath: initialPath),
    );
  }
}
