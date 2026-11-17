import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'ai_panel.dart';
import 'crop.dart';
import 'editor_controller.dart';
import 'panels.dart';
import 'theme.dart';
import 'widgets.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, this.initialPath});
  final String? initialPath;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

enum _Mode {
  auto('추천', '사진에 어울리는 보정안', Icons.auto_awesome_rounded),
  style('스타일', '분위기를 한 번에 바꾸기', Icons.style_rounded),
  adjust('조정', '직접 섬세하게 다듬기', Icons.tune_rounded),
  crop('자르기', '구도와 수평 맞추기', Icons.crop_rotate_rounded),
  ai('AI', '원하는 느낌을 말로 요청하기', Icons.forum_rounded);

  const _Mode(this.label, this.subtitle, this.icon);
  final String label, subtitle;
  final IconData icon;
}

const _photoExts = ['jpg', 'jpeg', 'png', 'tif', 'tiff'];

class _EditorPageState extends State<EditorPage> {
  final c = EditorController();
  _Mode mode = _Mode.auto;

  /// Before/after split view and where its divider sits (0..1 of the photo width).
  bool split = false;
  double splitAt = 0.5;
  bool dragOver = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    c.refreshTemplateThumbs();
    final first = widget.initialPath;
    if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openPath(first));
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
    final f = await openFile(acceptedTypeGroups: [const XTypeGroup(label: '사진', extensions: _photoExts)]);
    if (f != null) await _openPath(f.path);
  }

  Future<void> _openPath(String path) async {
    if (!_photoExts.contains(p.extension(path).replaceFirst('.', '').toLowerCase())) {
      c.setError('JPEG · PNG · TIFF 사진만 열 수 있어요');
      return;
    }
    setState(() {
      mode = _Mode.auto;
      split = false;
    });
    await c.openPhoto(path);
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('저장했어요 · ${p.basename(out)}')));
    }
  }

  void _setMode(_Mode m) {
    setState(() => mode = m);
    final crop = m == _Mode.crop;
    if (c.cropping != crop) c.setCropping(crop);
    if (crop) split = false;
  }

  Widget _panel() => switch (mode) {
        _Mode.auto => AutoPanel(c),
        _Mode.style => TemplatesPanel(c),
        _Mode.adjust => AdjustPanel(c),
        _Mode.crop => CropPanel(c),
        _Mode.ai => AiPanel(c),
      };

  // ------------------------------------------------------------------ viewer

  bool get _canSplit {
    final a = c.original, b = c.preview;
    if (a == null || b == null || c.cropping) return false;
    return ((a.width / a.height) - (b.width / b.height)).abs() < 0.01;
  }

  Widget _photo() {
    final img = c.showOriginal ? c.original : c.preview;
    if (img == null) return _EmptyState(onOpen: _open, dragOver: dragOver);
    if (c.cropping && !c.showOriginal) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Stack(children: [
          Positioned.fill(child: Center(child: RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium))),
          Positioned.fill(child: CropOverlay(c: c, image: img)),
        ]),
      );
    }
    if (split && !c.showOriginal) {
      if (_canSplit) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: _SplitCompare(
            before: c.original!,
            after: c.preview!,
            at: splitAt,
            onChanged: (v) => setState(() => splitAt = v),
          ),
        );
      }
    }
    final shown = split && !_canSplit ? c.original! : img;
    return GestureDetector(
      onLongPressStart: (_) => setState(() => c.showOriginal = true),
      onLongPressEnd: (_) => setState(() => c.showOriginal = false),
      child: InteractiveViewer(
        maxScale: 8,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(child: _Framed(image: shown)),
        ),
      ),
    );
  }

  Widget _viewer() {
    final showBefore = c.hasPhoto && (c.showOriginal || (split && !_canSplit && !c.cropping));
    return DropTarget(
      onDragEntered: (_) => setState(() => dragOver = true),
      onDragExited: (_) => setState(() => dragOver = false),
      onDragDone: (d) {
        setState(() => dragOver = false);
        if (d.files.isNotEmpty) _openPath(d.files.first.path);
      },
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.canvas,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: dragOver ? AppColors.accent : Colors.transparent, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Positioned.fill(child: _photo()),
          if (c.busy != null)
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(child: _Toast(text: c.busy!)),
            ),
          if (showBefore) const Positioned(left: 16, top: 16, child: _Tag('원본')),
          if (c.hasPhoto && dragOver)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: const _Tag('놓으면 이 사진으로 바꿔요'),
              ),
            ),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ chrome

  Widget _topBar(bool wide) {
    final name = c.path == null ? null : p.basename(c.path!);
    return SizedBox(
      height: 60,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const _Logo(),
          if (wide && name != null) ...[
            const SizedBox(width: 20),
            Flexible(
              child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textFaint, fontSize: 12.5)),
            ),
          ],
          const Spacer(),
          _IconPill(children: [
            _TopIcon(tooltip: '사진 열기 (Ctrl+O)', icon: Icons.add_photo_alternate_outlined, onTap: _open),
            _TopIcon(tooltip: '되돌리기 (Ctrl+Z)', icon: Icons.undo_rounded, onTap: c.canUndo ? c.undo : null),
            _TopIcon(tooltip: '다시 하기 (Ctrl+Y)', icon: Icons.redo_rounded, onTap: c.canRedo ? c.redo : null),
            _TopIcon(
              tooltip: '전후 비교 (\\)',
              icon: Icons.compare_rounded,
              active: split,
              onTap: c.hasPhoto && !c.cropping ? () => setState(() => split = !split) : null,
            ),
            _TopIcon(tooltip: '처음 상태로', icon: Icons.restart_alt_rounded, onTap: c.hasPhoto ? _confirmReset : null),
          ]),
          const SizedBox(width: 10),
          GradientButton(label: '저장', icon: Icons.download_rounded, height: 40, onPressed: c.hasPhoto ? _export : null),
        ]),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('처음 상태로 돌릴까요?'),
        content: const Text('모든 보정이 사라져요. 되돌리기(Ctrl+Z)로 다시 살릴 수 있어요.', style: TextStyle(color: AppColors.textDim)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('초기화')),
        ],
      ),
    );
    if (ok == true) c.reset();
  }

  Widget _dock({required bool compact}) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.line.withValues(alpha: 0.6)),
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: Row(mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min, children: [
        for (final m in _Mode.values)
          compact ? Expanded(child: _DockItem(mode: m, selected: mode == m, enabled: c.hasPhoto, onTap: () => _setMode(m))) : _DockItem(mode: m, selected: mode == m, enabled: c.hasPhoto, onTap: () => _setMode(m)),
      ]),
    );
  }

  Widget _panelCard() {
    final content = c.hasPhoto
        ? _panel()
        : const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('사진을 열면 여기에서\n보정안을 골라볼 수 있어요', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textFaint, height: 1.5)),
            ),
          );
    return Container(
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mode.label, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(height: 2),
            Text(mode.subtitle, style: const TextStyle(fontSize: 12.5, color: AppColors.textFaint)),
          ]),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(a), child: child),
            ),
            child: KeyedSubtree(key: ValueKey(mode), child: content),
          ),
        ),
      ]),
    );
  }

  /// Single-key shortcuts (1–5 switch modes, \ toggles before/after), skipped while
  /// typing so they never eat characters in a text field.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || !c.hasPhoto) return KeyEventResult.ignored;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null && (focus.widget is EditableText || focus.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isAltPressed) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.backslash) {
      if (!c.cropping) setState(() => split = !split);
      return KeyEventResult.handled;
    }
    final i = e.logicalKey.keyId - LogicalKeyboardKey.digit1.keyId;
    if (i >= 0 && i < _Mode.values.length) {
      _setMode(_Mode.values[i]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900;

    final body = wide
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Column(children: [
                  Expanded(child: _viewer()),
                  const SizedBox(height: 14),
                  _dock(compact: false),
                ]),
              ),
              const SizedBox(width: 16),
              SizedBox(width: size.width >= 1300 ? 400 : 360, child: _panelCard()),
            ]),
          )
        : Column(children: [
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _viewer())),
            const SizedBox(height: 10),
            SizedBox(height: size.height * 0.38, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _panelCard())),
            SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 12), child: _dock(compact: true))),
          ]);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): c.redo,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): _export,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _export,
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          body: SafeArea(child: Column(children: [_topBar(wide), Expanded(child: body)])),
        ),
      ),
    );
  }
}

// ==================================================================== pieces

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(gradient: accentGradient, borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.blur_on_rounded, size: 19, color: Colors.white),
        ),
        const SizedBox(width: 10),
        const Text('ACG', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1.2)),
        const SizedBox(width: 6),
        const Text('Color Studio', style: TextStyle(fontSize: 12.5, color: AppColors.textFaint, fontWeight: FontWeight.w500)),
      ]);
}

class _IconPill extends StatelessWidget {
  const _IconPill({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        height: 40,
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
}

class _TopIcon extends StatelessWidget {
  const _TopIcon({required this.tooltip, required this.icon, this.onTap, this.active = false});
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20, color: active ? AppColors.accent : null),
      );
}

class _DockItem extends StatelessWidget {
  const _DockItem({required this.mode, required this.selected, required this.enabled, required this.onTap});
  final _Mode mode;
  final bool selected, enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : (enabled ? AppColors.textDim : AppColors.textFaint);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            gradient: selected ? accentGradient : null,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(mode.icon, size: 21, color: color),
            const SizedBox(height: 3),
            Text(mode.label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.black.withValues(alpha: 0.55),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
              const SizedBox(width: 10),
              Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

/// The photo with soft rounded corners and a shadow, fitted to the space.
class _Framed extends StatelessWidget {
  const _Framed({required this.image});
  final ui.Image image;
  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: image.width / image.height,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 30, offset: Offset(0, 12))],
          ),
          clipBehavior: Clip.antiAlias,
          child: RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
        ),
      );
}

/// Before/after with a draggable divider: original on the left, edit on the right.
class _SplitCompare extends StatelessWidget {
  const _SplitCompare({required this.before, required this.after, required this.at, required this.onChanged});
  final ui.Image before, after;
  final double at;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Center(
        child: AspectRatio(
          aspectRatio: after.width / after.height,
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            final x = w * at;
            void move(Offset local) => onChanged((local.dx / w).clamp(0.0, 1.0));
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => move(d.localPosition),
              onHorizontalDragUpdate: (d) => move(d.localPosition),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(fit: StackFit.expand, children: [
                    RawImage(image: after, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                    ClipRect(
                      clipper: _LeftClip(x),
                      child: RawImage(image: before, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                    ),
                    Positioned(left: x - 1, top: 0, bottom: 0, child: Container(width: 2, color: Colors.white)),
                    Positioned(
                      left: x - 18,
                      top: box.maxHeight / 2 - 18,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 10)],
                        ),
                        child: const Icon(Icons.code_rounded, size: 20, color: Colors.black87),
                      ),
                    ),
                    const Positioned(left: 12, bottom: 12, child: _Tag('원본')),
                    const Positioned(right: 12, bottom: 12, child: _Tag('보정')),
                  ]),
                ),
              ),
            );
          }),
        ),
      );
}

class _LeftClip extends CustomClipper<Rect> {
  _LeftClip(this.x);
  final double x;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, x, size.height);
  @override
  bool shouldReclip(_LeftClip old) => old.x != x;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onOpen, required this.dragOver});
  final VoidCallback onOpen;
  final bool dragOver;
  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            constraints: const BoxConstraints(maxWidth: 460),
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
            decoration: BoxDecoration(
              color: dragOver ? AppColors.accent.withValues(alpha: 0.08) : AppColors.surface.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: dragOver ? AppColors.accent : AppColors.line, width: 1.5),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: accentGradient,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: AppColors.accent2.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 10))],
                ),
                child: const Icon(Icons.photo_camera_rounded, size: 34, color: Colors.white),
              ),
              const SizedBox(height: 22),
              const Text('사진 한 장이면 충분해요', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
              const SizedBox(height: 8),
              const Text('열자마자 사진을 분석해서 어울리는 보정안을\n여러 가지 보여드려요. 마음에 드는 걸 고르기만 하세요.',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim, height: 1.55, fontSize: 13.5)),
              const SizedBox(height: 26),
              GradientButton(label: '사진 열기', icon: Icons.add_photo_alternate_rounded, onPressed: onOpen, height: 48),
              const SizedBox(height: 14),
              const Text('또는 사진을 여기로 끌어다 놓기', style: TextStyle(color: AppColors.textFaint, fontSize: 12.5)),
              const SizedBox(height: 18),
              const Wrap(spacing: 6, children: [
                _FormatChip('JPEG'),
                _FormatChip('PNG'),
                _FormatChip('TIFF 16bit'),
              ]),
            ]),
          ),
        ),
      );
}

class _FormatChip extends StatelessWidget {
  const _FormatChip(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: const TextStyle(fontSize: 11, color: AppColors.textDim, fontWeight: FontWeight.w600)),
      );
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  String fmt = 'jpg';
  double quality = 100;

  static const formats = [
    ('jpg', 'JPEG', '공유·SNS용 · 디더링으로 밴딩 방지', Icons.image_rounded),
    ('tif', 'TIFF 16비트', '무손실 · 인쇄와 추가 편집용', Icons.layers_rounded),
    ('png', 'PNG 16비트', '무손실', Icons.crop_original_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('사진 저장', style: TextStyle(fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (id, name, desc, icon) in formats)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setState(() => fmt = id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: fmt == id ? AppColors.accent.withValues(alpha: 0.1) : AppColors.surface2,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: fmt == id ? AppColors.accent : Colors.transparent, width: 1.5),
                  ),
                  child: Row(children: [
                    Icon(icon, color: fmt == id ? AppColors.accent : AppColors.textDim),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(desc, style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
                      ]),
                    ),
                    if (fmt == id) const Icon(Icons.check_circle_rounded, color: AppColors.accent, size: 20),
                  ]),
                ),
              ),
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
            padding: EdgeInsets.only(top: 10, left: 4),
            child: Text('항상 원본 해상도 그대로 저장돼요.', style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        GradientButton(label: '저장', height: 40, onPressed: () => Navigator.pop(context, (fmt, quality.round()))),
      ],
    );
  }
}
