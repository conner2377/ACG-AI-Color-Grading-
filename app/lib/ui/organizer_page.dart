// Photo organizer: pick a folder, the engine groups bursts of the same scene and
// recommends the best-taken frame of each (sharpest subject, no shake, good exposure),
// while keeping intentional variations (panning, a different moment or framing).
// Photos are shown large; the user ticks what to keep and copies (or moves) them into a
// new, named folder. Nothing is ever deleted.

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../engine/engine.dart';
import 'widgets.dart';

const _exts = {'.jpg', '.jpeg', '.png', '.tif', '.tiff'};

class _Shot {
  _Shot(this.path, this.verdict, this.note, this.width, this.height, this.preview, this.score);
  final String path;
  final String verdict; // single | best | variation | duplicate | weaker
  final String note;
  final int width;
  final int height;
  final String preview;
  final double score;
  String get display => preview.isNotEmpty ? preview : path;
  double get aspect => height == 0 ? 1.5 : width / height;
  bool get recommended => verdict == 'single' || verdict == 'best' || verdict == 'variation';
}

class OrganizerPage extends StatefulWidget {
  const OrganizerPage({super.key, this.initialFolder});

  /// Folder to scan right away (e.g. a folder dropped on the start screen).
  final String? initialFolder;
  @override
  State<OrganizerPage> createState() => _OrganizerPageState();
}

enum _Filter { all, picked, bursts }

class _OrganizerPageState extends State<OrganizerPage> {
  String? folder;
  bool includeSub = false;
  List<List<_Shot>> groups = [];
  final selected = <String>{};
  String? progress;
  double? progressValue;
  _Filter filter = _Filter.all;
  double rowHeight = 420;
  bool dragOver = false;

  @override
  void initState() {
    super.initState();
    final f = widget.initialFolder;
    if (f != null) WidgetsBinding.instance.addPostFrameCallback((_) => _scan(f));
  }

  int get total => groups.fold(0, (n, g) => n + g.length);
  int get bursts => groups.where((g) => g.length > 1).length;

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: '이 폴더 정리');
    if (dir != null) await _scan(dir);
  }

  List<String> _listPhotos(String dir) {
    final files = Directory(dir)
        .listSync(recursive: includeSub, followLinks: false)
        .whereType<File>()
        .map((f) => f.path)
        .where((f) => _exts.contains(p.extension(f).toLowerCase()) && !p.basename(f).startsWith('.'))
        .toList()
      ..sort();
    return files;
  }

  Future<void> _scan(String dir) async {
    setState(() {
      folder = dir;
      groups = [];
      selected.clear();
      progress = '사진을 찾는 중…';
      progressValue = null;
    });
    try {
      final paths = _listPhotos(dir);
      if (paths.isEmpty) {
        setState(() => progress = null);
        _snack('이 폴더에는 정리할 사진(JPEG · PNG · TIFF)이 없어요.');
        return;
      }
      final cache = Directory(p.join(Directory.systemTemp.path, 'acg_organizer'))..createSync(recursive: true);
      final metrics = <Map<String, dynamic>>[];
      final errors = <String>[];
      const batch = 8;
      for (var i = 0; i < paths.length; i += batch) {
        if (!mounted) return;
        setState(() {
          progress = '사진 분석 중… $i/${paths.length}';
          progressValue = i / paths.length;
        });
        final r = await engineCullMeasure(paths.sublist(i, (i + batch).clamp(0, paths.length)), cache.path);
        metrics.addAll((r['metrics'] as List).cast<Map<String, dynamic>>());
        errors.addAll((r['errors'] as List).cast<String>());
      }
      setState(() => progress = '비슷한 사진끼리 묶는 중…');
      final byPath = {for (final m in metrics) m['path'] as String: m};
      final gs = await engineCullGroup(metrics);
      final out = <List<_Shot>>[];
      const order = {'best': 0, 'single': 0, 'variation': 1, 'duplicate': 2, 'weaker': 3};
      for (final g in gs) {
        out.add([
          for (final it in (g['items'] as List).cast<Map<String, dynamic>>())
            _Shot(
              it['path'] as String,
              it['verdict'] as String,
              it['note'] as String? ?? '',
              (byPath[it['path']]?['width'] as num?)?.toInt() ?? 0,
              (byPath[it['path']]?['height'] as num?)?.toInt() ?? 0,
              byPath[it['path']]?['preview'] as String? ?? '',
              (it['score'] as num?)?.toDouble() ?? 1,
            ),
        ]..sort((a, b) => order[a.verdict]!.compareTo(order[b.verdict]!)));
      }
      if (!mounted) return;
      setState(() {
        groups = out;
        selected
          ..clear()
          ..addAll([for (final g in out) for (final s in g) if (s.recommended) s.path]);
        progress = null;
      });
      if (errors.isNotEmpty) _snack('${errors.length}장은 읽지 못했어요.');
    } catch (e) {
      if (mounted) setState(() => progress = null);
      _snack('$e');
    }
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _toggle(String path) => setState(() => selected.contains(path) ? selected.remove(path) : selected.add(path));

  void _selectRecommended() => setState(() {
        selected
          ..clear()
          ..addAll([for (final g in groups) for (final s in g) if (s.recommended) s.path]);
      });

  Future<void> _organize() async {
    if (selected.isEmpty || folder == null) return;
    final choice = await showDialog<(String, String, bool)>(
      context: context,
      builder: (_) => _OrganizeDialog(count: selected.length, source: folder!),
    );
    if (choice == null) return;
    final (parent, name, move) = choice;
    var target = p.join(parent, name);
    for (var i = 2; Directory(target).existsSync() && Directory(target).listSync().isNotEmpty; i++) {
      target = p.join(parent, '$name ($i)');
    }
    Directory(target).createSync(recursive: true);
    final files = [for (final g in groups) for (final s in g) if (selected.contains(s.path)) s.path];
    var done = 0;
    final failed = <String>[];
    for (final f in files) {
      setState(() {
        progress = '${move ? '옮기는' : '복사하는'} 중… $done/${files.length}';
        progressValue = done / files.length;
      });
      var dest = p.join(target, p.basename(f));
      for (var i = 2; File(dest).existsSync(); i++) {
        dest = p.join(target, '${p.basenameWithoutExtension(f)}_$i${p.extension(f)}');
      }
      try {
        if (move) {
          try {
            await File(f).rename(dest);
          } on FileSystemException {
            await File(f).copy(dest);
            await File(f).delete();
          }
        } else {
          await File(f).copy(dest);
        }
      } catch (_) {
        failed.add(f);
      }
      done++;
    }
    setState(() => progress = null);
    if (move) await _scan(folder!);
    _snack('${files.length - failed.length}장을 정리했어요: $target${failed.isEmpty ? '' : ' (실패 ${failed.length}장)'}');
  }

  Future<void> _view(List<_Shot> group, int index) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (_) => _Viewer(
        group: group,
        index: index,
        selected: selected,
        onToggle: (path) => _toggle(path),
        onEdit: (path) => Navigator.of(context)
          ..pop()
          ..pop(path),
      ),
    );
    setState(() {});
  }

  List<List<_Shot>> get _visible => switch (filter) {
        _Filter.all => groups,
        _Filter.bursts => groups.where((g) => g.length > 1).toList(),
        _Filter.picked => [
            for (final g in groups)
              if (g.any((s) => selected.contains(s.path))) g.where((s) => selected.contains(s.path)).toList()
          ],
      };

  @override
  Widget build(BuildContext context) {
    final has = groups.isNotEmpty;
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: DropTarget(
          onDragEntered: (_) => setState(() => dragOver = true),
          onDragExited: (_) => setState(() => dragOver = false),
          onDragDone: (d) {
            setState(() => dragOver = false);
            if (d.files.isEmpty) return;
            final path = d.files.first.path;
            _scan(FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path));
          },
          child: Container(
            foregroundDecoration: BoxDecoration(border: Border.all(color: dragOver ? accent : Colors.transparent, width: 2)),
            child: Column(children: [
              _topBar(),
              if (progress != null) LinearProgressIndicator(value: progressValue, minHeight: 2, color: accent, backgroundColor: borderColor),
              Expanded(child: has ? _list() : _empty()),
              if (has) _bottomBar(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _topBar() => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
        child: Row(children: [
          IconButton(tooltip: '돌아가기', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, size: 20)),
          const SizedBox(width: 4),
          const Text('사진 정리', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          if (folder != null)
            Flexible(
              child: Text(folder!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: textDim, fontSize: 12.5)),
            ),
          const Spacer(),
          if (progress != null)
            Padding(padding: const EdgeInsets.only(right: 12), child: Text(progress!, style: const TextStyle(color: textDim, fontSize: 12))),
          if (groups.isNotEmpty) ...[
            SizedBox(
              width: 140,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                child: Slider(value: rowHeight, min: 240, max: 720, onChanged: (v) => setState(() => rowHeight = v)),
              ),
            ),
            const Icon(Icons.photo_size_select_large, size: 16, color: textDim),
            const SizedBox(width: 12),
          ],
          TextButton.icon(
            onPressed: progress == null ? _pickFolder : null,
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: Text(folder == null ? '폴더 열기' : '다른 폴더'),
          ),
        ]),
      );

  Widget _empty() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.photo_library_outlined, size: 40, color: accent),
            const SizedBox(height: 18),
            const Text('정리할 폴더를 넣어 주세요', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            const Text(
              '같은 장면을 여러 장 찍었다면 가장 선명하게 잘 찍힌 컷을 골라 드려요. 패닝샷이나 피사체가 움직인 컷처럼 일부러 다르게 찍은 사진은 그대로 남겨요. 사진은 지우지 않아요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: textDim, fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 24),
            GradientButton(label: '폴더 고르기', icon: Icons.folder_open_outlined, onPressed: progress == null ? _pickFolder : null),
            const SizedBox(height: 10),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: includeSub, onChanged: (v) => setState(() => includeSub = v ?? false)),
              const Text('하위 폴더까지 포함', style: TextStyle(fontSize: 12.5, color: textDim)),
            ]),
            const Text('폴더를 이 창에 끌어다 놓아도 돼요', style: TextStyle(color: textDim, fontSize: 12)),
          ]),
        ),
      );

  Widget _list() {
    final vis = _visible;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Row(children: [
          Text('사진 $total장 · 연사 묶음 $bursts개', style: const TextStyle(color: textDim, fontSize: 12.5)),
          const Spacer(),
          SegmentedButton<_Filter>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: _Filter.all, label: Text('전체')),
              ButtonSegment(value: _Filter.bursts, label: Text('연사만')),
              ButtonSegment(value: _Filter.picked, label: Text('고른 사진')),
            ],
            selected: {filter},
            onSelectionChanged: (s) => setState(() => filter = s.first),
          ),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          itemCount: vis.length,
          itemBuilder: (_, i) => _groupRow(vis[i]),
        ),
      ),
    ]);
  }

  Widget _groupRow(List<_Shot> g) {
    final burst = g.length > 1;
    final keepers = g.where((s) => s.verdict == 'best' || s.verdict == 'variation').length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (burst)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              const Icon(Icons.burst_mode_outlined, size: 16, color: accent),
              const SizedBox(width: 6),
              Text('비슷한 사진 ${g.length}장', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text('추천 1 · 남길 만한 컷 ${keepers - 1}', style: const TextStyle(fontSize: 12, color: textDim)),
            ]),
          ),
        SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: g.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, j) => _tile(g, j),
          ),
        ),
      ]),
    );
  }

  Widget _tile(List<_Shot> g, int j) {
    final s = g[j];
    final on = selected.contains(s.path);
    final badge = switch (s.verdict) {
      'best' => ('추천', accent, onAccent),
      'variation' => ('다른 컷', const Color(0xFF6FA3D9), Colors.black),
      'duplicate' => ('거의 같음', const Color(0xFF3A3C42), Colors.white),
      'weaker' => ('아쉬움', const Color(0xFF3A3C42), Colors.white),
      _ => null,
    };
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: () => _toggle(s.path),
      onDoubleTap: () => _view(g, j),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AspectRatio(
          aspectRatio: s.aspect,
          child: Container(
            decoration: BoxDecoration(
              color: cardColor,
              border: Border.all(color: on ? accent : borderColor, width: on ? 2 : 1),
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(fit: StackFit.expand, children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: on ? 1 : 0.4,
                child: Image.file(
                  File(s.display),
                  fit: BoxFit.cover,
                  cacheHeight: (rowHeight * dpr).round().clamp(200, 1600),
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, color: textDim)),
                ),
              ),
              if (badge != null)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: badge.$2, borderRadius: BorderRadius.circular(4)),
                    child: Text(badge.$1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: badge.$3)),
                  ),
                ),
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: on ? accent : const Color(0x88000000),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: on ? const Icon(Icons.check, size: 15, color: onAccent) : null,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xAA000000)],
                    ),
                  ),
                  child: Text(
                    [p.basename(s.path), if (s.note.isNotEmpty) s.note].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Colors.white),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() => Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: const BoxDecoration(color: surfaceColor, border: Border(top: BorderSide(color: borderColor))),
        child: Row(children: [
          Text('${selected.length}장 선택', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Text('/ $total장', style: const TextStyle(color: textDim, fontSize: 13)),
          const SizedBox(width: 16),
          TextButton(onPressed: _selectRecommended, child: const Text('추천대로 선택')),
          TextButton(onPressed: () => setState(selected.clear), child: const Text('모두 해제')),
          const Spacer(),
          const Text('클릭: 선택 · 더블클릭: 크게 보기', style: TextStyle(color: textDim, fontSize: 11.5)),
          const SizedBox(width: 16),
          GradientButton(
            label: '새 폴더로 정리',
            icon: Icons.drive_folder_upload_outlined,
            onPressed: selected.isEmpty || progress != null ? null : _organize,
          ),
        ]),
      );
}

class _OrganizeDialog extends StatefulWidget {
  const _OrganizeDialog({required this.count, required this.source});
  final int count;
  final String source;
  @override
  State<_OrganizeDialog> createState() => _OrganizeDialogState();
}

class _OrganizeDialogState extends State<_OrganizeDialog> {
  late final name = TextEditingController(text: '${p.basename(widget.source)}_고른 사진');
  late String parent = p.dirname(widget.source);
  bool move = false;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${widget.count}장을 새 폴더로 정리'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '폴더 이름', border: OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 14),
            const Text('만들 위치', style: TextStyle(color: textDim, fontSize: 12)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: Text(parent, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
              TextButton(
                onPressed: () async {
                  final d = await getDirectoryPath(initialDirectory: parent, confirmButtonText: '여기에 만들기');
                  if (d != null) setState(() => parent = d);
                },
                child: const Text('바꾸기'),
              ),
            ]),
            const SizedBox(height: 8),
            RadioGroup<bool>(
              groupValue: move,
              onChanged: (v) => setState(() => move = v ?? false),
              child: const Column(children: [
                RadioListTile(value: false, dense: true, title: Text('복사'), subtitle: Text('원래 폴더는 그대로 둬요')),
                RadioListTile(value: true, dense: true, title: Text('이동'), subtitle: Text('원래 폴더에서 새 폴더로 옮겨요')),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
            onPressed: () {
              final n = name.text.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
              if (n.isEmpty) return;
              Navigator.pop(context, (parent, n, move));
            },
            child: const Text('정리하기'),
          ),
        ],
      );
}

class _Viewer extends StatefulWidget {
  const _Viewer({required this.group, required this.index, required this.selected, required this.onToggle, required this.onEdit});
  final List<_Shot> group;
  final int index;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onEdit;
  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  late int i = widget.index;

  @override
  Widget build(BuildContext context) {
    final s = widget.group[i];
    final on = widget.selected.contains(s.path);
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Column(children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            Text(p.basename(s.path), style: const TextStyle(fontSize: 13)),
            if (s.note.isNotEmpty) Text('  ·  ${s.note}', style: const TextStyle(color: textDim, fontSize: 12.5)),
            const Spacer(),
            if (widget.group.length > 1) Text('${i + 1} / ${widget.group.length}', style: const TextStyle(color: textDim, fontSize: 12.5)),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: () => widget.onEdit(s.path),
              icon: const Icon(Icons.tune, size: 17),
              label: const Text('이 사진 보정하기'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () {
                widget.onToggle(s.path);
                setState(() {});
              },
              style: FilledButton.styleFrom(
                backgroundColor: on ? accent : cardColor,
                foregroundColor: on ? onAccent : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              icon: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked, size: 17),
              label: Text(on ? '선택됨' : '선택'),
            ),
          ]),
        ),
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 8,
                child: Image.file(File(s.display), fit: BoxFit.contain, filterQuality: FilterQuality.medium),
              ),
            ),
            if (i > 0)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(child: IconButton.filledTonal(onPressed: () => setState(() => i--), icon: const Icon(Icons.chevron_left))),
              ),
            if (i < widget.group.length - 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(child: IconButton.filledTonal(onPressed: () => setState(() => i++), icon: const Icon(Icons.chevron_right))),
              ),
          ]),
        ),
      ]),
    );
  }
}
