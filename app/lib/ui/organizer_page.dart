// Photo organizer: pick a folder, the engine groups bursts of the same scene and
// recommends the best-taken frame of each (sharpest subject, no shake, good exposure),
// while keeping intentional variations (panning, a different moment or framing).
// Photos are shown large; the user ticks what to keep and copies (or moves) them into a
// new, named folder. Nothing is ever deleted.

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  const OrganizerPage({super.key, this.initialFolder, this.embedded = false, this.onEditPhoto});

  /// Shown as a main tab of the app (no back button) instead of a pushed page.
  final bool embedded;

  /// Open a photo in the editor ("이 사진 보정하기").
  final ValueChanged<String>? onEditPhoto;

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
  double rowHeight = 400;

  /// 0 = grouped by burst (rows), 1..4 = grid with that many columns.
  int layout = 0;
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

  /// Every visible photo in order (for the grid and for paging in the big view).
  List<_Shot> get _flat => [for (final g in _visible) ...g];

  Future<void> _view(_Shot shot) async {
    final all = _flat;
    final burstSize = {for (final g in groups) for (final s in g) s.path: g.length};
    final organize = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black,
      builder: (_) => _Viewer(
        shots: all,
        index: all.indexWhere((s) => s.path == shot.path).clamp(0, all.length - 1),
        burstSize: burstSize,
        selected: selected,
        onToggle: (path) => _toggle(path),
        onEdit: (path) {
          Navigator.of(context).pop();
          if (widget.onEditPhoto != null) {
            widget.onEditPhoto!(path);
          } else {
            Navigator.of(context).pop(path);
          }
        },
      ),
    );
    setState(() {});
    if (organize == true) await _organize();
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
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
        child: Row(children: [
          if (!widget.embedded) ...[
            IconButton(tooltip: '돌아가기', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, size: 20)),
            const SizedBox(width: 4),
            const Text('사진 정리', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(width: 12),
          ] else
            const SizedBox(width: 8),
          if (folder == null)
            const Text('연사 중 베스트 컷 고르기 · 남길 사진만 새 폴더로', style: TextStyle(color: textDim, fontSize: 13))
          else
            Flexible(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.folder_outlined, size: 16, color: textDim),
                const SizedBox(width: 6),
                Flexible(child: Text(folder!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: textDim, fontSize: 13))),
              ]),
            ),
          const Spacer(),
          if (progress != null) ...[
            const ApertureSpinner(size: 15),
            const SizedBox(width: 8),
            Text(progress!, style: readout.copyWith(color: textDim, fontSize: 12)),
            const SizedBox(width: 14),
          ],
          OutlinedButton.icon(
            onPressed: progress == null ? _pickFolder : null,
            icon: const Icon(Icons.folder_open_outlined, size: 17),
            label: Text(folder == null ? '폴더 열기' : '다른 폴더'),
          ),
        ]),
      );

  Widget _empty() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(color: accentDim, borderRadius: BorderRadius.circular(22)),
              child: const Stack(children: [
                Center(child: Icon(Icons.photo_library_outlined, size: 32, color: accent)),
                FrameCorners(color: accent, length: 12, width: 2, inset: 8),
              ]),
            ),
            const SizedBox(height: 22),
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

  Widget _layoutButton(int value, IconData icon, String tip) {
    final on = layout == value;
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => layout = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 34,
          height: 30,
          decoration: BoxDecoration(color: on ? const Color(0xFF26263A) : null, borderRadius: BorderRadius.circular(8)),
          child: value == 0
              ? Icon(icon, size: 17, color: on ? accent : textDim)
              : Center(
                  child: Text('${value}x',
                      style: readout.copyWith(fontSize: 12, fontWeight: FontWeight.w700, color: on ? accent : textDim)),
                ),
        ),
      ),
    );
  }

  Widget _list() {
    final vis = _visible;
    final flat = _flat;
    final burstSize = {for (final g in groups) for (final s in g) s.path: g.length};
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Row(children: [
          Text('사진 $total장', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('연사 묶음 $bursts개', style: const TextStyle(color: textDim, fontSize: 12.5)),
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
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: const Color(0xFF15151C), border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(10)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _layoutButton(0, Icons.view_agenda_outlined, '연사 묶음별로 보기'),
              for (var n = 1; n <= 4; n++) _layoutButton(n, Icons.grid_view, '한 줄에 $n장씩'),
            ]),
          ),
          if (layout == 0) ...[
            const SizedBox(width: 10),
            SizedBox(
              width: 110,
              child: Slider(value: rowHeight, min: 220, max: 720, onChanged: (v) => setState(() => rowHeight = v)),
            ),
          ],
        ]),
      ),
      Expanded(
        child: layout == 0
            ? ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                itemCount: vis.length,
                itemBuilder: (_, i) => _groupRow(vis[i]),
              )
            : LayoutBuilder(builder: (context, box) {
                final cellW = (box.maxWidth - 40 - (layout - 1) * 10) / layout;
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: layout,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: layout <= 2 ? 3 / 2 : 1,
                  ),
                  itemCount: flat.length,
                  itemBuilder: (_, i) => _tile(flat[i],
                      height: cellW / (layout <= 2 ? 1.5 : 1), fit: layout <= 2 ? BoxFit.contain : BoxFit.cover, burst: burstSize[flat[i].path] ?? 1),
                );
              }),
      ),
    ]);
  }

  Widget _groupRow(List<_Shot> g) {
    final burst = g.length > 1;
    final keepers = g.where((s) => s.verdict == 'best' || s.verdict == 'variation').length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (burst)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              const Icon(Icons.burst_mode_outlined, size: 16, color: accent),
              const SizedBox(width: 6),
              Text('비슷한 사진 ${g.length}장', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
            itemBuilder: (_, j) => AspectRatio(aspectRatio: g[j].aspect, child: _tile(g[j], height: rowHeight)),
          ),
        ),
      ]),
    );
  }

  Widget _tile(_Shot s, {required double height, BoxFit fit = BoxFit.cover, int burst = 1}) {
    final on = selected.contains(s.path);
    final badge = switch (s.verdict) {
      'best' => ('추천', accent, Colors.white),
      'variation' => ('다른 컷', const Color(0xFF3B82F6), Colors.white),
      'duplicate' => ('거의 같음', const Color(0xCC2A2A34), Colors.white),
      'weaker' => ('아쉬움', const Color(0xCC2A2A34), Colors.white),
      _ => null,
    };
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: () => _toggle(s.path),
      onDoubleTap: () => _view(s),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFF101015), borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Stack(fit: StackFit.expand, children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: on ? 1 : 0.42,
              child: Image.file(
                File(s.display),
                fit: fit,
                cacheHeight: (height * dpr).round().clamp(200, 1600),
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, color: textDim)),
              ),
            ),
            // Selected = an AF point locked on the photo.
            if (on) const FrameCorners(color: accent, length: 18, width: 2.5, inset: 6),
            Positioned(
              left: 10,
              top: 10,
              child: Row(children: [
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: badge.$2, borderRadius: BorderRadius.circular(20)),
                    child: Text(badge.$1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: badge.$3)),
                  ),
                if (burst > 1 && layout > 0) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0xCC111116), borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.burst_mode_outlined, size: 12, color: Colors.white70),
                      const SizedBox(width: 3),
                      Text('$burst', style: readout.copyWith(fontSize: 11, color: Colors.white70)),
                    ]),
                  ),
                ],
              ]),
            ),
            Positioned(
              right: 10,
              top: 10,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  gradient: on ? accentGradient : null,
                  color: on ? null : const Color(0x66000000),
                  shape: BoxShape.circle,
                  border: Border.all(color: on ? Colors.transparent : Colors.white70, width: 1.5),
                ),
                child: on ? const Icon(Icons.check, size: 15, color: Colors.white) : null,
              ),
            ),
            if (height > 160)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 9),
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

/// Big view: page through every photo (not only one burst) with ← →, tick it with
/// Space or the button, and jump anywhere from the film strip.
class _Viewer extends StatefulWidget {
  const _Viewer({
    required this.shots,
    required this.index,
    required this.burstSize,
    required this.selected,
    required this.onToggle,
    required this.onEdit,
  });
  final List<_Shot> shots;
  final int index;
  final Map<String, int> burstSize;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onEdit;
  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  late int i = widget.index;
  final strip = ScrollController();

  void _go(int d) {
    final n = (i + d).clamp(0, widget.shots.length - 1);
    if (n == i) return;
    setState(() => i = n);
    if (strip.hasClients) {
      strip.animateTo((n * 86.0 - 300).clamp(0, strip.position.maxScrollExtent),
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
  }

  void _toggle() {
    widget.onToggle(widget.shots[i].path);
    setState(() {});
  }

  @override
  void dispose() {
    strip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.shots[i];
    final on = widget.selected.contains(s.path);
    final count = widget.selected.length;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.space): _toggle,
      },
      child: Focus(
        autofocus: true,
        child: Dialog.fullscreen(
          backgroundColor: const Color(0xFF060608),
          child: Column(children: [
            SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  IconButton(tooltip: '닫기 (Esc)', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(p.basename(s.path),
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  if (s.note.isNotEmpty)
                    Flexible(child: Text('  ·  ${s.note}', overflow: TextOverflow.ellipsis, style: const TextStyle(color: textDim, fontSize: 13))),
                  const Spacer(),
                  Text('${i + 1} / ${widget.shots.length}', style: readout.copyWith(color: textDim, fontSize: 13)),
                  const SizedBox(width: 16),
                  TextButton.icon(
                    onPressed: () => widget.onEdit(s.path),
                    icon: const Icon(Icons.tune, size: 17),
                    label: const Text('이 사진 보정하기'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: count == 0 ? null : () => Navigator.pop(context, true),
                    icon: const Icon(Icons.drive_folder_upload_outlined, size: 17),
                    label: Text('선택한 $count장 정리하기'),
                  ),
                ]),
              ),
            ),
            Expanded(
              child: Stack(children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 12),
                    child: InteractiveViewer(
                      key: ValueKey(s.path),
                      maxScale: 8,
                      child: Center(child: Image.file(File(s.display), fit: BoxFit.contain, filterQuality: FilterQuality.medium)),
                    ),
                  ),
                ),
                if (on) const Positioned.fill(child: FrameCorners(color: accent, length: 26, width: 2.5, inset: 18)),
                Positioned(
                  left: 14,
                  top: 0,
                  bottom: 0,
                  child: Center(child: _NavButton(icon: Icons.chevron_left, onTap: i > 0 ? () => _go(-1) : null)),
                ),
                Positioned(
                  right: 14,
                  top: 0,
                  bottom: 0,
                  child: Center(child: _NavButton(icon: Icons.chevron_right, onTap: i < widget.shots.length - 1 ? () => _go(1) : null)),
                ),
                Positioned(
                  bottom: 18,
                  left: 0,
                  right: 0,
                  child: Center(
                    // Shutter-style round button: tick this photo to keep it.
                    child: GestureDetector(
                      onTap: _toggle,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.fromLTRB(8, 8, 18, 8),
                          decoration: BoxDecoration(
                            color: const Color(0xE6141419),
                            border: Border.all(color: on ? accent : borderColor),
                            borderRadius: BorderRadius.circular(40),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                              padding: const EdgeInsets.all(3),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: on ? accentGradient : null,
                                  color: on ? null : Colors.white24,
                                ),
                                child: on ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(on ? '저장할 사진에 담음' : '저장할 사진에 담기',
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Text('Space', style: readout.copyWith(fontSize: 11, color: textDim)),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            SizedBox(
              height: 92,
              child: ListView.builder(
                controller: strip,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                itemCount: widget.shots.length,
                itemBuilder: (_, j) {
                  final t = widget.shots[j];
                  final sel = widget.selected.contains(t.path);
                  return GestureDetector(
                    onTap: () => _go(j - i),
                    child: Container(
                      width: 78,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: j == i ? Colors.white : Colors.transparent, width: 2),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(fit: StackFit.expand, children: [
                        Opacity(
                          opacity: sel ? 1 : 0.4,
                          child: Image.file(File(t.display), fit: BoxFit.cover, cacheHeight: 140, errorBuilder: (_, _, _) => const SizedBox()),
                        ),
                        if (sel)
                          Positioned(
                            right: 4,
                            top: 4,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: const BoxDecoration(shape: BoxShape.circle, gradient: accentGradient),
                            ),
                          ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, this.onTap});
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.25 : 1,
        child: Material(
          color: const Color(0xCC17171D),
          shape: const CircleBorder(side: BorderSide(color: borderColor)),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon))),
        ),
      );
}
