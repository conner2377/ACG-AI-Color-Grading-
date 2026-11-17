import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'ai_panel.dart';
import 'crop.dart';
import 'editor_controller.dart';
import 'panels.dart';
import 'widgets.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _Tool {
  const _Tool(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _tools = [
  _Tool('자동', Icons.auto_awesome),
  _Tool('템플릿', Icons.style),
  _Tool('자르기', Icons.crop_rotate),
  _Tool('빛', Icons.wb_sunny_outlined),
  _Tool('색상', Icons.palette_outlined),
  _Tool('커브', Icons.show_chart),
  _Tool('그레이딩', Icons.contrast),
  _Tool('효과', Icons.blur_on),
  _Tool('AI', Icons.auto_fix_high),
];

const _cropTool = 2;

class _EditorPageState extends State<EditorPage> {
  final c = EditorController();
  int tool = 0;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    c.refreshTemplateThumbs();
  }

  void _onChange() {
    if (c.error != null) {
      final msg = c.error!;
      c.error = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    c.session?.close();
    super.dispose();
  }

  Future<void> _open() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: '사진', extensions: ['jpg', 'jpeg', 'png', 'tif', 'tiff'])
    ]);
    if (f != null) await c.openPhoto(f.path);
  }

  Future<void> _export() async {
    if (!c.hasPhoto) return;
    final choice = await showDialog<(String, int)>(context: context, builder: (_) => const _ExportDialog());
    if (choice == null) return;
    final (ext, quality) = choice;
    final base = p.basenameWithoutExtension(c.path!);
    final loc = await getSaveLocation(
      suggestedName: '${base}_ACG.$ext',
      acceptedTypeGroups: [XTypeGroup(label: ext.toUpperCase(), extensions: [ext])],
    );
    if (loc == null) return;
    var out = loc.path;
    if (p.extension(out).isEmpty) out = '$out.$ext';
    final ok = await c.withBusy('원본 해상도로 내보내는 중…', () async {
      await c.session!.export(c.recipe, out, jpegQuality: quality);
      return true;
    });
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('저장했습니다: $out')));
    }
  }

  Widget _panel() => switch (tool) {
        0 => AutoPanel(c),
        1 => TemplatesPanel(c),
        2 => CropPanel(c),
        3 => LightPanel(c),
        4 => ColorPanel(c),
        5 => CurvePanel(c),
        6 => GradingPanel(c),
        7 => EffectsPanel(c),
        _ => AiPanel(c),
      };

  Widget _viewer() {
    final img = c.showOriginal ? c.original : c.preview;
    if (img == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.photo_outlined, size: 64, color: Colors.white24),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _open, icon: const Icon(Icons.folder_open), label: const Text('사진 열기')),
          const SizedBox(height: 8),
          const Text('JPEG · PNG · TIFF(16비트)', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
      );
    }
    if (c.cropping && !c.showOriginal) {
      return Stack(children: [
        Positioned.fill(child: Center(child: RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium))),
        Positioned.fill(child: CropOverlay(c: c, image: img)),
      ]);
    }
    return GestureDetector(
      onLongPressStart: (_) => setState(() => c.showOriginal = true),
      onLongPressEnd: (_) => setState(() => c.showOriginal = false),
      child: InteractiveViewer(
        maxScale: 8,
        child: Center(child: RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium)),
      ),
    );
  }

  Widget _toolBar({required bool vertical}) {
    final items = [
      for (var i = 0; i < _tools.length; i++)
        InkWell(
          onTap: () {
            setState(() => tool = i);
            if (c.cropping != (i == _cropTool)) c.setCropping(i == _cropTool);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(_tools[i].icon, size: 22, color: tool == i ? accent : Colors.white70),
              const SizedBox(height: 2),
              Text(_tools[i].label, style: TextStyle(fontSize: 11, color: tool == i ? accent : Colors.white70)),
            ]),
          ),
        ),
    ];
    return vertical
        ? SingleChildScrollView(child: Column(children: items))
        : SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: items));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final appBar = AppBar(
      backgroundColor: const Color(0xFF161616),
      title: const Text('ACG', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1)),
      actions: [
        IconButton(tooltip: '사진 열기 (Ctrl+O)', onPressed: _open, icon: const Icon(Icons.folder_open)),
        IconButton(tooltip: '실행 취소 (Ctrl+Z)', onPressed: c.canUndo ? c.undo : null, icon: const Icon(Icons.undo)),
        IconButton(tooltip: '다시 실행 (Ctrl+Y)', onPressed: c.canRedo ? c.redo : null, icon: const Icon(Icons.redo)),
        IconButton(tooltip: '초기화', onPressed: c.hasPhoto ? c.reset : null, icon: const Icon(Icons.restart_alt)),
        GestureDetector(
          onTapDown: (_) => setState(() => c.showOriginal = true),
          onTapUp: (_) => setState(() => c.showOriginal = false),
          onTapCancel: () => setState(() => c.showOriginal = false),
          child: const Tooltip(
            message: '누르고 있으면 원본 보기',
            child: Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.compare)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FilledButton.icon(onPressed: c.hasPhoto ? _export : null, icon: const Icon(Icons.save_alt, size: 18), label: const Text('내보내기')),
        ),
      ],
    );

    final viewer = Stack(children: [
      Positioned.fill(child: Container(color: const Color(0xFF0B0B0B), child: _viewer())),
      if (c.busy != null)
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(c.busy!, style: const TextStyle(fontSize: 13)),
              ]),
            ),
          ),
        ),
      if (c.showOriginal)
        const Positioned(left: 12, bottom: 12, child: Chip(label: Text('원본'))),
    ]);

    final panel = c.hasPhoto
        ? _panel()
        : const Center(child: Text('사진을 열면 보정 도구가 나타납니다', style: TextStyle(color: Colors.white38)));

    final body = wide
        ? Row(children: [
            Expanded(child: viewer),
            Container(
              width: 380,
              color: const Color(0xFF161616),
              child: Row(children: [
                Container(width: 72, color: const Color(0xFF111111), child: _toolBar(vertical: true)),
                Expanded(child: panel),
              ]),
            ),
          ])
        : Column(children: [
            Expanded(child: viewer),
            Container(height: 280, color: const Color(0xFF161616), child: panel),
            Container(color: const Color(0xFF111111), child: SafeArea(top: false, child: _toolBar(vertical: false))),
          ]);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): _export,
      },
      child: Focus(autofocus: true, child: Scaffold(appBar: appBar, body: body)),
    );
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  String fmt = 'jpg';
  double quality = 100;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('내보내기'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          RadioGroup<String>(
            groupValue: fmt,
            onChanged: (v) => setState(() => fmt = v!),
            child: const Column(children: [
              RadioListTile(value: 'jpg', title: Text('JPEG'), subtitle: Text('8비트, 디더링으로 밴딩 방지')),
              RadioListTile(value: 'tif', title: Text('TIFF 16비트 (무손실)'), subtitle: Text('인쇄·추가 편집용')),
              RadioListTile(value: 'png', title: Text('PNG 16비트 (무손실)')),
            ]),
          ),
          if (fmt == 'jpg')
            AdjustSlider(
              label: 'JPEG 품질',
              value: quality,
              min: 70,
              max: 100,
              reset: 100,
              display: (v) => v.round().toString(),
              onChanged: (v) => setState(() => quality = v),
              onChangeEnd: (_) {},
            ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('항상 원본 해상도로 저장됩니다.', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(onPressed: () => Navigator.pop(context, (fmt, quality.round())), child: const Text('저장')),
      ],
    );
  }
}
