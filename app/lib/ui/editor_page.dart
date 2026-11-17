import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'adjust_tab.dart';
import 'crop.dart';
import 'editor_controller.dart';
import 'looks_tab.dart';
import 'widgets.dart';

const _photoTypes = XTypeGroup(label: '사진', extensions: ['jpg', 'jpeg', 'png', 'tif', 'tiff']);

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, this.initialPhoto, this.initialTab = 0});

  /// Photo to open at start (e.g. "Open with" from Explorer).
  final String? initialPhoto;
  final int initialTab;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

const _tabs = [
  ('룩', Icons.auto_awesome),
  ('다듬기', Icons.tune),
  ('자르기', Icons.crop_rotate),
];
const _cropTab = 2;

class _EditorPageState extends State<EditorPage> {
  final c = EditorController();
  int tab = 0;
  bool dragOver = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    c.loadFavorites();
    tab = widget.initialTab;
    final first = widget.initialPhoto;
    if (first != null) {
      c.openPhoto(first).then((_) {
        if (tab == _cropTab) c.setCropping(true);
      });
    } else {
      c.refreshTemplateThumbs();
    }
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

  void _setTab(int i) {
    setState(() => tab = i);
    if (c.cropping != (i == _cropTab)) c.setCropping(i == _cropTab);
  }

  Future<void> _open() async {
    final f = await openFile(acceptedTypeGroups: [_photoTypes]);
    if (f != null) {
      _setTab(0);
      await c.openPhoto(f.path);
    }
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
    final ok = await c.withBusy('원본 해상도로 저장하는 중…', () async {
      await c.session!.export(c.recipe, out, jpegQuality: quality);
      return true;
    });
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('저장했어요: $out')));
    }
  }

  /// Apply the current look to many photos at once.
  Future<void> _batch() async {
    if (!c.hasPhoto) return;
    final files = await openFiles(acceptedTypeGroups: [_photoTypes]);
    if (files.isEmpty || !mounted) return;
    final preset = c.activePreset;
    final choice = await showDialog<(String, int, bool)>(
      context: context,
      builder: (_) => _ExportDialog.batch(count: files.length, lookName: preset?['name'] as String?),
    );
    if (choice == null) return;
    final dir = await getDirectoryPath(confirmButtonText: '여기에 저장');
    if (dir == null) return;
    final (ext, quality, perPhoto) = choice;
    final n = await c.withBusy('여러 장 저장하는 중… 0/${files.length}', () {
      return c.batchExport([for (final f in files) f.path], dir, ext, quality,
          perPhotoBase: perPhoto, onProgress: (d) {
        c.busy = '여러 장 저장하는 중… $d/${files.length}';
        c.touch();
      });
    });
    if (n != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n장을 저장했어요: $dir')));
    }
  }

  Widget _welcome() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ShaderMask(
            shaderCallback: (r) => accentGradient.createShader(r),
            child: const Icon(Icons.filter_vintage, size: 72, color: Colors.white),
          ),
          const SizedBox(height: 20),
          const Text('사진 한 장으로 시작해요', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('열자마자 어울리는 룩을 골라 드려요. 마음에 드는 걸 누르기만 하면 돼요.',
              style: TextStyle(color: textDim, fontSize: 14)),
          const SizedBox(height: 24),
          GradientButton(label: '사진 열기', icon: Icons.add_photo_alternate_outlined, onPressed: _open),
          const SizedBox(height: 12),
          const Text('사진을 이 창에 끌어다 놓아도 돼요 · JPEG · PNG · TIFF(16비트)', style: TextStyle(color: textDim, fontSize: 12)),
        ]),
      );

  Widget _viewer() {
    final img = c.showOriginal ? c.original : c.preview;
    if (img == null) return _welcome();
    final picture = SizedBox.expand(child: RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium));
    if (c.cropping && !c.showOriginal) {
      return Stack(children: [
        Positioned.fill(child: picture),
        Positioned.fill(child: CropOverlay(c: c, image: img)),
      ]);
    }
    final before = c.original;
    if (c.compareSplit && before != null && c.preview != null) {
      return LayoutBuilder(builder: (context, box) {
        final x = box.maxWidth * c.splitPos;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            c.splitPos = (c.splitPos + d.delta.dx / box.maxWidth).clamp(0.02, 0.98);
            c.touch();
          },
          onTapDown: (d) {
            c.splitPos = (d.localPosition.dx / box.maxWidth).clamp(0.02, 0.98);
            c.touch();
          },
          child: Stack(children: [
            Positioned.fill(child: RawImage(image: c.preview, fit: BoxFit.contain, filterQuality: FilterQuality.medium)),
            Positioned.fill(
              child: ClipRect(
                clipper: _LeftClipper(x),
                child: SizedBox.expand(child: RawImage(image: before, fit: BoxFit.contain, filterQuality: FilterQuality.medium)),
              ),
            ),
            Positioned(left: x - 1, top: 0, bottom: 0, child: Container(width: 2, color: Colors.white)),
            Positioned(
              left: x - 18,
              top: box.maxHeight / 2 - 18,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(blurRadius: 8, color: Colors.black45)]),
                child: const Icon(Icons.unfold_more, color: Colors.black87, size: 20, textDirection: TextDirection.ltr),
              ),
            ),
            const Positioned(left: 12, bottom: 12, child: _Tag('원본')),
            const Positioned(right: 12, bottom: 12, child: _Tag('보정')),
          ]),
        );
      });
    }
    return GestureDetector(
      onLongPressStart: (_) => setState(() => c.showOriginal = true),
      onLongPressEnd: (_) => setState(() => c.showOriginal = false),
      child: InteractiveViewer(maxScale: 8, child: picture),
    );
  }

  Widget _tabBar() => Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (var i = 0; i < _tabs.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _setTab(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    gradient: tab == i ? accentGradient : null,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(_tabs[i].$2, size: 16, color: tab == i ? Colors.black87 : textDim),
                    const SizedBox(width: 6),
                    Text(_tabs[i].$1,
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: tab == i ? Colors.black87 : textDim)),
                  ]),
                ),
              ),
            ),
        ]),
      );

  Widget _panel() => switch (tab) {
        0 => LooksTab(c),
        1 => AdjustTab(c),
        _ => CropPanel(c),
      };

  Widget _iconBtn(String tip, IconData icon, VoidCallback? onTap, {bool active = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(icon, size: 20, color: active ? accent : null),
      );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final has = c.hasPhoto;
    final topBar = Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: bgColor,
      child: Row(children: [
        const SizedBox(width: 4),
        ShaderMask(
          shaderCallback: (r) => accentGradient.createShader(r),
          child: const Text('ACG', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2, color: Colors.white)),
        ),
        const SizedBox(width: 12),
        _iconBtn('사진 열기 (Ctrl+O)', Icons.add_photo_alternate_outlined, _open),
        const Spacer(),
        _iconBtn('되돌리기 (Ctrl+Z)', Icons.undo, c.canUndo ? c.undo : null),
        _iconBtn('다시 하기 (Ctrl+Y)', Icons.redo, c.canRedo ? c.redo : null),
        if (wide) _iconBtn('처음으로', Icons.restart_alt, has ? c.reset : null),
        _iconBtn('전후 비교 (\\)', Icons.compare, has
            ? () {
                c.compareSplit = !c.compareSplit;
                c.touch();
              }
            : null, active: c.compareSplit),
        if (wide)
          _iconBtn('같은 룩으로 여러 장 저장', Icons.photo_library_outlined, has ? _batch : null)
        else
          PopupMenuButton<int>(
            enabled: has,
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (v) => v == 0 ? c.reset() : _batch(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('처음으로')),
              PopupMenuItem(value: 1, child: Text('같은 룩으로 여러 장 저장')),
            ],
          ),
        const SizedBox(width: 8),
        GradientButton(label: '저장', icon: wide ? Icons.download : null, onPressed: has ? _export : null),
      ]),
    );

    final viewer = Stack(children: [
      Positioned.fill(
        child: Padding(
          padding: EdgeInsets.all(has ? 12 : 0),
          child: ClipRRect(borderRadius: BorderRadius.circular(has ? 12 : 0), child: _viewer()),
        ),
      ),
      if (c.busy != null)
        Positioned(
          top: 20,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: const Color(0xE6000000), borderRadius: BorderRadius.circular(24)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
                const SizedBox(width: 10),
                Text(c.busy!, style: const TextStyle(fontSize: 13)),
              ]),
            ),
          ),
        ),
      if (c.showOriginal) const Positioned(left: 24, bottom: 24, child: _Tag('원본')),
    ]);

    final side = Column(children: [_tabBar(), Expanded(child: _panel())]);

    final Widget body;
    if (!has) {
      body = viewer;
    } else if (wide) {
      body = Row(children: [
        Expanded(child: viewer),
        Container(width: 400, color: surfaceColor, child: side),
      ]);
    } else {
      body = Column(children: [
        Expanded(child: viewer),
        Container(
          height: 360,
          decoration: const BoxDecoration(color: surfaceColor, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          child: SafeArea(top: false, child: side),
        ),
      ]);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): _export,
        const SingleActivator(LogicalKeyboardKey.backslash): () {
          c.compareSplit = !c.compareSplit;
          c.touch();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: bgColor,
          body: SafeArea(
            child: DropTarget(
              onDragEntered: (_) => setState(() => dragOver = true),
              onDragExited: (_) => setState(() => dragOver = false),
              onDragDone: (d) {
                setState(() => dragOver = false);
                if (d.files.isNotEmpty) {
                  _setTab(0);
                  c.openPhoto(d.files.first.path);
                }
              },
              child: Container(
                foregroundDecoration: BoxDecoration(
                  border: Border.all(color: dragOver ? accent : Colors.transparent, width: 3),
                ),
                child: Column(children: [topBar, Expanded(child: body)]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  _LeftClipper(this.x);
  final double x;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, x, size.height);
  @override
  bool shouldReclip(_LeftClipper old) => old.x != x;
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog() : count = null, lookName = null;
  const _ExportDialog.batch({required int this.count, this.lookName});
  final int? count;
  final String? lookName;
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  String fmt = 'jpg';
  double quality = 100;
  late bool perPhoto = widget.lookName != null;

  @override
  Widget build(BuildContext context) {
    final batch = widget.count != null;
    return AlertDialog(
      title: Text(batch ? '${widget.count}장 한꺼번에 저장' : '저장'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          RadioGroup<String>(
            groupValue: fmt,
            onChanged: (v) => setState(() => fmt = v!),
            child: const Column(children: [
              RadioListTile(value: 'jpg', title: Text('JPEG'), subtitle: Text('가장 흔한 형식')),
              RadioListTile(value: 'tif', title: Text('TIFF 16비트'), subtitle: Text('무손실 · 인쇄나 추가 편집용')),
              RadioListTile(value: 'png', title: Text('PNG 16비트'), subtitle: Text('무손실')),
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
          if (batch && widget.lookName != null)
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: const Text('사진마다 밝기·색온도 자동 맞춤'),
              subtitle: Text('각 사진을 먼저 자동 보정한 뒤 "${widget.lookName}" 룩을 입혀요. 끄면 지금 값을 그대로 써요.'),
              value: perPhoto,
              onChanged: (v) => setState(() => perPhoto = v),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 8),
            child: Text(batch ? '파일 이름 뒤에 _ACG가 붙고, 자르기·회전은 적용하지 않아요.' : '항상 원본 해상도로 저장돼요.',
                style: const TextStyle(color: textDim, fontSize: 12)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: () => batch
              ? Navigator.pop(context, (fmt, quality.round(), perPhoto))
              : Navigator.pop(context, (fmt, quality.round())),
          child: Text(batch ? '폴더 고르기' : '저장'),
        ),
      ],
    );
  }
}
