// Editor shell: top bar, photo viewer (with before/after split and crop overlay),
// and a right-hand panel with one tab per tool, selected from a vertical rail.

import 'dart:io';

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

/// One tool tab: rail label, icon, panel title and a one-line description.
typedef _Tool = (String, IconData, String, String);

const _tools = <_Tool>[
  ('자동', Icons.auto_fix_high, '자동 보정', '사진을 분석해 기본 보정과 어울리는 룩을 골라요'),
  ('룩', Icons.filter_vintage_outlined, '룩', 'LUT처럼 확실한 색감, 사진에 맞춰 세기를 자동 조절'),
  ('AI', Icons.auto_awesome_outlined, 'AI 추천', '말로 요청하면 AI가 룩과 값을 골라요 (픽셀은 건드리지 않아요)'),
  ('자르기', Icons.crop_rotate, '자르기 · 회전', '비율, 수평, 90° 회전, 반전'),
  ('빛', Icons.wb_sunny_outlined, '빛', '노출 · 대비 · 톤'),
  ('색', Icons.palette_outlined, '색', '화이트 밸런스 · 채도 · 색상 혼합'),
  ('커브', Icons.show_chart, '톤 커브', 'RGB · 채널별 커브'),
  ('그레이딩', Icons.contrast, '컬러 그레이딩', '섀도우 · 미드톤 · 하이라이트 색'),
  ('효과', Icons.grain, '효과', '디테일 · 노이즈 · 필름 · 렌즈'),
];
const _cropTab = 3;

class _EditorPageState extends State<EditorPage> {
  final c = EditorController();
  int tab = 0;
  bool dragOver = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    c.loadFavorites();
    c.loadRecent();
    tab = widget.initialTab.clamp(0, _tools.length - 1);
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

  Future<void> _openPath(String path) async {
    if (tab == _cropTab) _setTab(0);
    await c.openPhoto(path);
  }

  Future<void> _open() async {
    final f = await openFile(acceptedTypeGroups: [_photoTypes]);
    if (f != null) await _openPath(f.path);
  }

  void _toggleCompare() {
    if (!c.hasPhoto) return;
    c.compareSplit = !c.compareSplit;
    c.touch();
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

  // ---------------------------------------------------------------- viewer

  Widget _viewer() {
    final img = c.showOriginal ? c.original : c.preview;
    if (img == null) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: accent)));
    }
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
            Positioned(left: x - 0.75, top: 0, bottom: 0, child: Container(width: 1.5, color: Colors.white)),
            Positioned(
              left: x - 16,
              top: box.maxHeight / 2 - 16,
              child: Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(blurRadius: 8, color: Colors.black45)]),
                child: const Icon(Icons.unfold_more, color: Colors.black87, size: 18, textDirection: TextDirection.ltr),
              ),
            ),
            const Positioned(left: 12, top: 12, child: _Tag('원본')),
            const Positioned(right: 12, top: 12, child: _Tag('보정')),
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

  Widget _viewerArea() => Stack(children: [
        Positioned.fill(child: Padding(padding: const EdgeInsets.all(16), child: _viewer())),
        if (c.busy != null)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                    color: const Color(0xEE18191C), border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(6)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: accent)),
                  const SizedBox(width: 10),
                  Text(c.busy!, style: const TextStyle(fontSize: 12.5)),
                ]),
              ),
            ),
          ),
        if (c.showOriginal) const Positioned(left: 28, top: 28, child: _Tag('원본')),
      ]);

  // ---------------------------------------------------------------- tools

  Widget _panel() => switch (tab) {
        0 => AutoPanel(c),
        1 => LooksPanel(c),
        2 => AiPanel(c),
        3 => CropPanel(c),
        4 => LightPanel(c),
        5 => ColorPanel(c),
        6 => CurvePanel(c),
        7 => GradingPanel(c),
        _ => EffectsPanel(c),
      };

  Widget _panelHeader() {
    final t = _tools[tab];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.$3, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 3),
        Text(t.$4, style: const TextStyle(color: textDim, fontSize: 11.5)),
      ]),
    );
  }

  /// Vertical tool rail (desktop).
  Widget _rail() => Container(
        width: 68,
        decoration: const BoxDecoration(color: bgColor, border: Border(left: BorderSide(color: borderColor))),
        child: Material(type: MaterialType.transparency, child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          for (var i = 0; i < _tools.length; i++) ...[
            if (i == 3 || i == 4) const Divider(height: 12, indent: 16, endIndent: 16, color: borderColor),
            _RailItem(tool: _tools[i], selected: tab == i, onTap: () => _setTab(i)),
          ],
        ])),
      );

  /// Horizontal tool strip (narrow windows).
  Widget _strip() => SizedBox(
        height: 58,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (var i = 0; i < _tools.length; i++)
            SizedBox(width: 62, child: _RailItem(tool: _tools[i], selected: tab == i, onTap: () => _setTab(i), compact: true)),
        ]),
      );

  // ---------------------------------------------------------------- top bar

  Widget _iconBtn(String tip, IconData icon, VoidCallback? onTap, {bool active = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: active ? accentDim : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        icon: Icon(icon, size: 19, color: active ? accent : null),
      );

  Widget _topBar(bool wide) {
    final has = c.hasPhoto;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(color: bgColor, border: Border(bottom: BorderSide(color: borderColor))),
      child: Row(children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: has ? c.closePhoto : null,
          child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: AcgLogo(size: 15)),
        ),
        SizedBox(width: wide ? 8 : 0),
        _iconBtn('사진 열기 (Ctrl+O)', Icons.folder_open_outlined, _open),
        if (has && wide)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(p.basename(c.path!),
                  overflow: TextOverflow.ellipsis, style: const TextStyle(color: textDim, fontSize: 12.5)),
            ),
          ),
        const Spacer(),
        if (has) ...[
          _iconBtn('되돌리기 (Ctrl+Z)', Icons.undo, c.canUndo ? c.undo : null),
          _iconBtn('다시 하기 (Ctrl+Y)', Icons.redo, c.canRedo ? c.redo : null),
          if (wide) _iconBtn('처음으로', Icons.restart_alt, c.reset),
          const SizedBox(width: 4),
          _iconBtn('전후 비교 (\\)', Icons.compare, _toggleCompare, active: c.compareSplit),
          if (wide)
            _iconBtn('같은 룩으로 여러 장 저장', Icons.photo_library_outlined, _batch)
          else
            PopupMenuButton<int>(
              icon: const Icon(Icons.more_horiz, size: 19),
              onSelected: (v) => v == 0 ? c.reset() : _batch(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0, child: Text('처음으로')),
                PopupMenuItem(value: 1, child: Text('같은 룩으로 여러 장 저장')),
              ],
            ),
          SizedBox(width: wide ? 8 : 2),
          GradientButton(label: '저장', icon: wide ? Icons.download : null, onPressed: _export),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final has = c.hasPhoto;

    final Widget body;
    if (!has) {
      body = StartScreen(c: c, onOpen: _open, onOpenPath: _openPath);
    } else if (wide) {
      body = Row(children: [
        Expanded(child: _viewerArea()),
        Container(
          width: 360,
          decoration: const BoxDecoration(color: surfaceColor, border: Border(left: BorderSide(color: borderColor))),
          child: Material(type: MaterialType.transparency, child: Column(children: [_panelHeader(), Expanded(child: _panel())])),
        ),
        _rail(),
      ]);
    } else {
      body = Column(children: [
        Expanded(child: _viewerArea()),
        Container(
          height: 380,
          decoration: const BoxDecoration(color: surfaceColor, border: Border(top: BorderSide(color: borderColor))),
          child: SafeArea(
            top: false,
            child: Material(type: MaterialType.transparency, child: Column(children: [
              _strip(),
              const Divider(height: 1, color: borderColor),
              Expanded(child: _panel()),
            ])),
          ),
        ),
      ]);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): _export,
        const SingleActivator(LogicalKeyboardKey.backslash): _toggleCompare,
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
                if (d.files.isNotEmpty) _openPath(d.files.first.path);
              },
              child: Container(
                foregroundDecoration: BoxDecoration(
                  border: Border.all(color: dragOver ? accent : Colors.transparent, width: 2),
                ),
                child: Column(children: [_topBar(wide), Expanded(child: body)]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.tool, required this.selected, required this.onTap, this.compact = false});
  final _Tool tool;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final color = selected ? accent : textDim;
    return Tooltip(
      message: tool.$3,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(vertical: compact ? 6 : 9),
          decoration: BoxDecoration(
            border: compact
                ? Border(bottom: BorderSide(color: selected ? accent : Colors.transparent, width: 2))
                : Border(right: BorderSide(color: selected ? accent : Colors.transparent, width: 2)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(tool.$2, size: 20, color: color),
            const SizedBox(height: 4),
            Text(tool.$1,
                style: TextStyle(fontSize: 10.5, color: selected ? Colors.white : textDim, fontWeight: selected ? FontWeight.w600 : null)),
          ]),
        ),
      ),
    );
  }
}

/// Wordmark: amber square mark + "ACG".
class AcgLogo extends StatelessWidget {
  const AcgLogo({super.key, this.size = 15});
  final double size;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: size * 1.35,
          height: size * 1.35,
          decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(size * 0.3)),
          child: Icon(Icons.blur_on, size: size, color: onAccent),
        ),
        SizedBox(width: size * 0.55),
        Text('ACG', style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: size * 0.12)),
      ]);
}

// ------------------------------------------------------------------ start screen

class StartScreen extends StatefulWidget {
  const StartScreen({super.key, required this.c, required this.onOpen, required this.onOpenPath});
  final EditorController c;
  final VoidCallback onOpen;
  final ValueChanged<String> onOpenPath;
  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  bool hoverDrop = false;

  static const features = [
    (Icons.auto_fix_high, '자동 분석', '히스토그램으로 노출·화이트밸런스를 먼저 바로잡아요'),
    (Icons.filter_vintage_outlined, '사진에 맞춰지는 룩', 'LUT처럼 확실한 색감을, 사진마다 세기를 맞춰 얹어요'),
    (Icons.auto_awesome_outlined, 'AI는 값만 조절', '픽셀을 새로 그리지 않아 화질이 그대로예요'),
    (Icons.high_quality_outlined, '16비트 무손실', '원본 해상도 그대로 JPEG · TIFF · PNG 저장'),
  ];

  @override
  Widget build(BuildContext context) {
    final recent = widget.c.recent;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 980;
      final hero = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const AcgLogo(size: 22),
        const SizedBox(height: 28),
        const Text('사진에 어울리는 색을\n자동으로 찾아 드려요',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, height: 1.3, letterSpacing: -0.5)),
        const SizedBox(height: 12),
        const Text('사진을 열면 장면을 분석하고, 룩을 그 사진에 맞게 조절해서 보여 줘요.',
            style: TextStyle(color: textDim, fontSize: 14, height: 1.5)),
        const SizedBox(height: 28),
        _dropZone(),
        const SizedBox(height: 28),
        for (final (icon, title, sub) in features)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(color: textDim, fontSize: 12)),
                ]),
              ),
            ]),
          ),
      ]);

      final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const _SectionTitle('최근 사진'),
        if (recent.isEmpty)
          Container(
            height: 160,
            alignment: Alignment.center,
            decoration: BoxDecoration(border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(8)),
            child: const Text('아직 연 사진이 없어요', style: TextStyle(color: textDim, fontSize: 12.5)),
          )
        else
          GridView.count(
            crossAxisCount: wide ? 4 : 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.82,
            children: [for (final r in recent) _RecentTile(path: r, onTap: () => widget.onOpenPath(r))],
          ),
        const SizedBox(height: 28),
        const _SectionTitle('곧 추가될 기능'),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: surfaceColor, border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(8)),
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.photo_library_outlined, color: accent, size: 22),
            SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('사진 정리', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  SizedBox(width: 8),
                  _Badge('준비 중'),
                ]),
                SizedBox(height: 6),
                Text('폴더를 넣으면 비슷한 연사 중 가장 선명한 컷을 골라 주고, 크게 넘겨 보며 남길 사진만 새 폴더로 정리해요.',
                    style: TextStyle(color: textDim, fontSize: 12, height: 1.5)),
              ]),
            ),
          ]),
        ),
      ]);

      final content = wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 420, child: hero),
              const SizedBox(width: 64),
              Expanded(child: side),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [hero, const SizedBox(height: 32), side]);

      return SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: wide ? 64 : 24, vertical: wide ? 56 : 28),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1180), child: content)),
      );
    });
  }

  Widget _dropZone() => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => hoverDrop = true),
        onExit: (_) => setState(() => hoverDrop = false),
        child: GestureDetector(
          onTap: widget.onOpen,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
            decoration: BoxDecoration(
              color: hoverDrop ? const Color(0xFF1C1D21) : surfaceColor,
              border: Border.all(color: hoverDrop ? accent : borderColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: accentDim, borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.add_photo_alternate_outlined, color: accent),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('사진 열기', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  SizedBox(height: 3),
                  Text('클릭하거나 사진을 끌어다 놓으세요 · Ctrl+O', style: TextStyle(color: textDim, fontSize: 12)),
                ]),
              ),
              const Text('JPEG · PNG · TIFF', style: TextStyle(color: textDim, fontSize: 11)),
            ]),
          ),
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: textDim, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: accentDim, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(color: accent, fontSize: 10.5, fontWeight: FontWeight.w600)),
      );
}

class _RecentTile extends StatefulWidget {
  const _RecentTile({required this.path, required this.onTap});
  final String path;
  final VoidCallback onTap;
  @override
  State<_RecentTile> createState() => _RecentTileState();
}

class _RecentTileState extends State<_RecentTile> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: cardColor,
                  border: Border.all(color: hover ? accent : borderColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(
                  File(widget.path),
                  fit: BoxFit.cover,
                  cacheWidth: 360,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => const Icon(Icons.image_outlined, color: textDim),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(p.basename(widget.path),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: textDim)),
          ]),
        ),
      );
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
