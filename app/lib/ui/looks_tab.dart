// 자동 · 룩 · AI panels.
//
// Looks work like LUTs (one click, one strength slider), but each one is fitted to the
// photo by the engine first, so it blends with the image instead of sitting on top.

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../ai/ai_service.dart';
import '../engine/engine.dart';
import 'ai_settings.dart';
import 'editor_controller.dart';
import 'widgets.dart';

const templateCategories = ['기본', '필름', '감성', '깊이감', '시네마', '인물', '풍경', '야경', '흑백', '특수'];
const _imageTypes = XTypeGroup(label: '이미지', extensions: ['jpg', 'jpeg', 'png', 'tif', 'tiff']);
const _sceneNames = {'Portrait': '인물', 'Landscape': '풍경', 'Night': '야경', 'Sunset': '노을', 'General': '일반'};

Widget _grid(List<Widget> cards, {int columns = 3}) => GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      mainAxisSpacing: 10,
      crossAxisSpacing: 8,
      childAspectRatio: 0.82,
      children: cards,
    );

/// Strength slider + why the look was fitted the way it was.
class LookStrengthBar extends StatelessWidget {
  const LookStrengthBar(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) {
    if (!c.templateBlendActive) return const SizedBox.shrink();
    return Container(
      decoration: const BoxDecoration(color: cardColor, border: Border(top: BorderSide(color: borderColor))),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
            child: AdjustSlider(
              label: c.activeTemplate ?? '세기',
              value: c.templateAmount,
              min: 0,
              max: 1.5,
              reset: 1,
              display: (v) => '${(v * 100).round()}%',
              onChanged: (v) => c.setTemplateAmount(v),
              onChangeEnd: (v) => c.setTemplateAmount(v, commit: true),
            ),
          ),
          IconButton(
            tooltip: '룩 해제',
            onPressed: c.clearLook,
            icon: const Icon(Icons.close, size: 18, color: textDim),
          ),
        ]),
        if (c.fitNotes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 2),
            child: Text(
              '사진에 맞춤: ${c.fitNotes.join(' · ')}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: textDim, fontSize: 11.5, height: 1.4),
            ),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 자동

class AutoPanel extends StatelessWidget {
  const AutoPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) {
    final scene = _sceneNames[c.stats?['scene']];
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
          HistogramView(c.histogram),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
            child: Row(children: [
              Expanded(
                child: Text(scene == null ? '사진 분석 중…' : '장면: $scene · 이 사진에 맞춘 후보 ${c.candidateThumbs.length}개',
                    style: const TextStyle(color: textDim, fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: c.busy == null ? c.runAuto : null,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('다시 분석'),
              ),
            ]),
          ),
          const PanelLabel('기본 보정 + 어울리는 룩'),
          _grid([
            for (final t in c.candidateThumbs)
              LookCard(
                label: t.name,
                subtitle: t.recipe['description'] as String?,
                image: t.image,
                selected: c.activeTemplate == t.name,
                onTap: () => c.applyTemplate(t.recipe, layer: false),
              ),
          ]),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '"자동 보정"은 히스토그램으로 노출·화이트밸런스·명암 범위만 바로잡은 것이고, 나머지는 그 위에 룩을 사진에 맞춰 얹은 결과예요.',
              style: TextStyle(color: textDim, fontSize: 11.5, height: 1.5),
            ),
          ),
        ]),
      ),
      LookStrengthBar(c),
    ]);
  }
}

// ------------------------------------------------------------------ 룩

class LooksPanel extends StatefulWidget {
  const LooksPanel(this.c, {super.key});
  final EditorController c;
  @override
  State<LooksPanel> createState() => _LooksPanelState();
}

class _LooksPanelState extends State<LooksPanel> {
  String filter = '전체';
  EditorController get c => widget.c;

  Future<void> _saveLook() async {
    final ctrl = TextEditingController(text: (c.recipe['name'] as String?) ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('내 룩으로 저장'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '룩 이름')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('저장')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await c.saveUserTemplate(name);
      setState(() => filter = '내 룩');
    }
  }

  Future<void> _importLook() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: '룩 (.json) / LUT (.cube)', extensions: ['json', 'cube']),
    ]);
    if (f == null) return;
    await c.withBusy('룩 가져오는 중…', () async {
      final Map<String, dynamic> t;
      if (f.path.toLowerCase().endsWith('.cube')) {
        t = await engineLoadCube(f.path);
      } else {
        t = jsonDecode(await File(f.path).readAsString()) as Map<String, dynamic>;
        t['name'] ??= f.name.replaceAll(RegExp(r'\.json$'), '');
      }
      await c.importTemplate(t);
    });
    setState(() => filter = '내 룩');
  }

  Future<void> _exportLook() async {
    final name = (c.recipe['name'] as String?)?.isNotEmpty == true ? c.recipe['name'] as String : '내 룩';
    final loc = await getSaveLocation(
        suggestedName: '$name.json', acceptedTypeGroups: [const XTypeGroup(label: '룩', extensions: ['json'])]);
    if (loc == null) return;
    await File(loc.path).writeAsString(const JsonEncoder.withIndent('  ').convert(c.recipe));
  }

  Future<void> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('"$name" 룩을 삭제할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok == true) await c.deleteUserTemplate(name);
  }

  @override
  Widget build(BuildContext context) {
    LookCard preset(PhotoThumb t) => LookCard(
          label: t.name,
          subtitle: t.recipe['description'] as String?,
          image: t.image,
          selected: c.activeTemplate == t.name,
          favorite: c.favorites.contains(t.name),
          onFavorite: () => c.toggleFavorite(t.name),
          onTap: () => c.applyTemplate(t.recipe),
        );
    LookCard mine(PhotoThumb t) => LookCard(
          label: t.name,
          image: t.image,
          selected: c.activeTemplate == t.name,
          favorite: c.favorites.contains(t.name),
          onFavorite: () => c.toggleFavorite(t.name),
          onDelete: () => _confirmDelete(t.name),
          onTap: () => c.applyTemplate(t.recipe, layer: false),
        );
    final List<Widget> cards = switch (filter) {
      '즐겨찾기' => [
          for (final t in c.presetThumbs.where((t) => c.favorites.contains(t.name))) preset(t),
          for (final t in c.userThumbs.where((t) => c.favorites.contains(t.name))) mine(t),
        ],
      '내 룩' => [for (final t in c.userThumbs) mine(t)],
      '전체' => [for (final t in c.presetThumbs) preset(t)],
      _ => [for (final t in c.presetThumbs.where((t) => t.recipe['category'] == filter)) preset(t)],
    };

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 0),
        child: Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: filter,
              isDense: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(),
              ),
              items: [
                for (final f in ['전체', '즐겨찾기', '내 룩', ...templateCategories])
                  DropdownMenuItem(value: f, child: Text(f, style: const TextStyle(fontSize: 13))),
              ],
              onChanged: (v) => setState(() => filter = v ?? '전체'),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '룩 관리',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) => switch (v) {
              'save' => _saveLook(),
              'import' => _importLook(),
              _ => _exportLook(),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'save', child: Text('지금 보정을 내 룩으로 저장')),
              PopupMenuItem(value: 'import', child: Text('룩 / LUT(.cube) 가져오기')),
              PopupMenuItem(value: 'export', child: Text('지금 보정을 룩 파일로 내보내기')),
            ],
          ),
        ]),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: const Text('사진에 맞춰 자동 조절', style: TextStyle(fontSize: 12.5)),
        subtitle: const Text('대비·색온도·채도를 사진에 맞게 줄이고, 하이라이트·어두운 곳·피부색을 지켜요',
            style: TextStyle(fontSize: 11, color: textDim)),
        value: c.autoFit,
        onChanged: c.setAutoFit,
      ),
      const Divider(height: 1, color: borderColor),
      Expanded(
        child: cards.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  switch (filter) {
                    '즐겨찾기' => '룩 썸네일의 ♡를 누르면 여기에 모여요.',
                    '내 룩' => '지금 보정을 저장하거나 공유받은 룩(.json) · LUT(.cube)을 가져올 수 있어요. 오른쪽 위 ⋮ 메뉴를 눌러 보세요.',
                    _ => '썸네일을 만드는 중이에요…',
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: textDim, fontSize: 12.5, height: 1.5),
                ),
              )
            : ListView(padding: const EdgeInsets.only(top: 12, bottom: 16), children: [_grid(cards)]),
      ),
      LookStrengthBar(c),
    ]);
  }
}

// ------------------------------------------------------------------ AI

class AiPanel extends StatefulWidget {
  const AiPanel(this.c, {super.key});
  final EditorController c;
  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final _request = TextEditingController();
  AiSettings? _settings;
  String? _referencePath;

  static const quick = ['필름 카메라 느낌', '영화처럼', '따뜻하고 포근하게', '차갑고 무디하게', '깊고 진하게', '밝고 화사하게', '적외선 촬영처럼', '플래시 터진 것처럼', '하늘을 더 파랗게', '인물 피부 화사하게'];

  EditorController get c => widget.c;

  @override
  void initState() {
    super.initState();
    AiSettings.load().then((s) => mounted ? setState(() => _settings = s) : null);
  }

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  Future<void> _openSettings() async {
    final s = _settings;
    if (s == null) return;
    final result = await showDialog<AiSettings>(context: context, builder: (_) => AiSettingsDialog(initial: s));
    if (result != null) {
      await result.save();
      setState(() => _settings = result);
    }
  }

  Future<void> _runAi({String? request, String? guideUrl}) async {
    if (c.session == null || _settings == null) return;
    if (_settings!.apiKey.isEmpty) {
      await _openSettings();
      if ((_settings?.apiKey ?? '').isEmpty) return;
    }
    final text = request ?? _request.text;
    final label = text.trim().isEmpty && guideUrl == null ? '사진을 분석해서 보정하는 중…' : '요청을 읽고 보정하는 중…';
    await c.withBusy('${_settings!.provider.label} · $label', () async {
      String? guide;
      if (guideUrl != null && guideUrl.trim().isNotEmpty) guide = await fetchGuideText(guideUrl);
      await c.runAi(
        settings: _settings!,
        request: guideUrl != null ? '링크의 보정 가이드대로 보정해 주세요. $text' : text,
        guideText: guide,
        referencePath: _referencePath,
      );
    });
  }

  Future<bool> _ensureKey() async {
    if (_settings == null) return false;
    if (_settings!.apiKey.isEmpty) await _openSettings();
    return (_settings?.apiKey ?? '').isNotEmpty;
  }

  Future<void> _refine() async {
    if (!await _ensureKey()) return;
    await c.withBusy('${_settings!.provider.label} · 결과를 다시 보고 다듬는 중…', () => c.refineAi(_settings!));
  }

  Future<void> _pickReference() async {
    final f = await openFile(acceptedTypeGroups: [_imageTypes]);
    if (f != null) setState(() => _referencePath = f.path);
  }

  Future<void> _matchOffline() async {
    final f = await openFile(acceptedTypeGroups: [_imageTypes]);
    if (f == null) return;
    await c.withBusy('예시 사진의 색감을 옮기는 중…', () async {
      final r = await c.session!.matchReference(c.recipe, f.path, 0.8);
      c.setRecipe(r);
    });
  }

  Future<void> _guideLink() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('보정 가이드 링크'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'https://… 보정 방법이 담긴 글')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('이대로 보정')),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) await _runAi(guideUrl: url);
  }

  @override
  Widget build(BuildContext context) {
    final busy = c.busy != null;
    final s = _settings;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
          Container(
            margin: const EdgeInsets.fromLTRB(12, 14, 12, 4),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accentDim,
              border: Border.all(color: accent.withValues(alpha: 0.35)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Row(children: [
                Icon(Icons.auto_awesome, size: 16, color: accent),
                SizedBox(width: 8),
                Text('AI 분석 보정', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 6),
              const Text('AI가 사진의 장면·빛·색을 읽고 노출부터 색, 분위기까지 값을 직접 정해요. 프리셋은 쓰지 않아요.',
                  style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5)),
              const SizedBox(height: 12),
              GradientButton(
                label: '사진 분석해서 보정',
                icon: Icons.auto_fix_high,
                onPressed: busy ? null : () => _runAi(request: ''),
              ),
            ]),
          ),
          const PanelLabel('말로 부탁하기'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _request,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontSize: 13),
              onSubmitted: busy ? null : (_) => _runAi(),
              decoration: const InputDecoration(
                hintText: '예) 해 질 녘처럼 따뜻하게, 하늘은 더 깊게, 얼굴은 자연스럽게',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final q in quick)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(q, style: const TextStyle(fontSize: 11.5)),
                  onPressed: busy
                      ? null
                      : () {
                          _request.text = q;
                          _runAi(request: q);
                        },
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(children: [
              Expanded(
                child: _referencePath == null
                    ? TextButton.icon(
                        style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: textDim),
                        onPressed: busy ? null : _pickReference,
                        icon: const Icon(Icons.add_photo_alternate_outlined, size: 17),
                        label: const Text('예시 사진 첨부', style: TextStyle(fontSize: 12)),
                      )
                    : InputChip(
                        avatar: const Icon(Icons.image_outlined, size: 16),
                        label: Text(_referencePath!.split(RegExp(r'[\\/]')).last,
                            overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                        onDeleted: () => setState(() => _referencePath = null),
                      ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: busy ? null : () => _runAi(),
                style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                child: const Text('요청대로 보정'),
              ),
            ]),
          ),
          if (c.aiThumbs.isNotEmpty) ...[
            PanelLabel('AI 보정 결과',
                trailing: GestureDetector(
                  onTap: () {
                    c.aiThumbs = [];
                    c.aiAnalysis = null;
                    c.touch();
                  },
                  child: const Icon(Icons.close, size: 14, color: textDim),
                )),
            if ((c.aiAnalysis ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(c.aiAnalysis!, style: const TextStyle(fontSize: 12.5, color: Colors.white70, height: 1.5)),
              ),
            _grid([
              for (final t in c.aiThumbs)
                LookCard(
                  label: t.name,
                  subtitle: t.recipe['description'] as String?,
                  image: t.image,
                  selected: c.activeTemplate == t.name,
                  onTap: () => c.pickAiVariation(t.recipe),
                ),
            ], columns: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: OutlinedButton.icon(
                onPressed: busy ? null : _refine,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('결과를 다시 보고 한 번 더 다듬기'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('AI가 정한 값은 빛·색·커브·그레이딩 탭의 슬라이더에 그대로 들어가 있어서 이어서 손볼 수 있어요.',
                  style: TextStyle(color: textDim, fontSize: 11.5, height: 1.5)),
            ),
          ],
          const PanelLabel('기타'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.link, size: 18),
            title: const Text('보정 가이드 글 링크로 보정', style: TextStyle(fontSize: 12.5)),
            onTap: busy ? null : _guideLink,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.colorize, size: 18),
            title: const Text('예시 사진 색감 그대로 옮기기 (AI 없이)', style: TextStyle(fontSize: 12.5)),
            onTap: busy ? null : _matchOffline,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.settings_outlined, size: 18),
            title: Text(s == null ? 'AI 설정' : 'AI 설정 · ${s.provider.label}${s.apiKey.isEmpty ? ' (키 없음)' : ''}',
                style: const TextStyle(fontSize: 12.5)),
            onTap: _openSettings,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'AI는 사진을 새로 그리지 않아요. 슬라이더·커브·색 휠 값만 정하고, 앱이 원본 해상도로 적용해서 화질이 그대로예요.',
              style: TextStyle(color: textDim, fontSize: 11.5, height: 1.5),
            ),
          ),
        ]),
      ),
      LookStrengthBar(c),
    ]);
  }
}
