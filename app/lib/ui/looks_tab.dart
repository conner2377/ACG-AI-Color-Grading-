// "룩" tab: say what you want (AI), or pick a look card. One tap applies it,
// one slider sets how strong it is.

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

class LooksTab extends StatefulWidget {
  const LooksTab(this.c, {super.key});
  final EditorController c;
  @override
  State<LooksTab> createState() => _LooksTabState();
}

class _LooksTabState extends State<LooksTab> {
  final _request = TextEditingController();
  AiSettings? _settings;
  String? _referencePath;
  String filter = '추천';

  static const quick = ['필름 카메라 느낌', '영화처럼', '따뜻하고 포근하게', '차갑고 무디하게', '깊고 진하게', '밝고 화사하게', '적외선 촬영처럼', '플래시 터진 것처럼'];

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
    await c.withBusy('${_settings!.provider.label}가 어울리는 룩 4가지를 고르는 중…', () async {
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
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'https://… 보정 방법이 담긴 글'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('이대로 보정')),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) await _runAi(guideUrl: url);
  }

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

  Widget _promptCard(bool busy) {
    final s = _settings;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.auto_awesome, size: 18, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _request,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: '어떤 느낌으로 바꿀까요?',
                hintStyle: TextStyle(color: textDim),
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: busy ? null : (_) => _runAi(),
            ),
          ),
          IconButton(
            tooltip: '예시 사진 첨부 (이 사진 색감처럼)',
            onPressed: busy ? null : _pickReference,
            icon: Icon(Icons.add_photo_alternate_outlined, color: _referencePath != null ? accent : textDim, size: 20),
          ),
          PopupMenuButton<String>(
            tooltip: '더 보기',
            icon: const Icon(Icons.more_horiz, color: textDim, size: 20),
            onSelected: (v) => switch (v) {
              'settings' => _openSettings(),
              'guide' => _guideLink(),
              'match' => _matchOffline(),
              'save' => _saveLook(),
              'import' => _importLook(),
              _ => _exportLook(),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'settings',
                  child: Text(s == null ? 'AI 설정' : 'AI 설정 · ${s.provider.label}${s.apiKey.isEmpty ? ' (키 없음)' : ''}')),
              const PopupMenuItem(value: 'guide', child: Text('보정 가이드 링크로 보정')),
              const PopupMenuItem(value: 'match', child: Text('예시 사진 색감 그대로 옮기기 (AI 없이)')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'save', child: Text('지금 보정을 내 룩으로 저장')),
              const PopupMenuItem(value: 'import', child: Text('룩/LUT 가져오기')),
              const PopupMenuItem(value: 'export', child: Text('지금 보정을 파일로 내보내기')),
            ],
          ),
          IconButton.filled(
            tooltip: 'AI로 보정',
            style: IconButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.black87),
            onPressed: busy ? null : () => _runAi(),
            icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.black87),
          ),
        ]),
        if (_referencePath != null)
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              avatar: const Icon(Icons.image_outlined, size: 16),
              label: Text('예시: ${_referencePath!.split(RegExp(r'[\\/]')).last}', style: const TextStyle(fontSize: 12)),
              onDeleted: () => setState(() => _referencePath = null),
            ),
          ),
        const SizedBox(height: 6),
        SizedBox(
          height: 30,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final q in quick)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(q, style: const TextStyle(fontSize: 12)),
                  onPressed: busy
                      ? null
                      : () {
                          _request.text = q;
                          _runAi(request: q);
                        },
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _grid(List<Widget> cards) => GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1.25,
        children: cards,
      );

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

  List<Widget> _cards() {
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
    switch (filter) {
      case '추천':
        return [
          for (final t in c.candidateThumbs)
            LookCard(
              label: t.name,
              subtitle: t.recipe['description'] as String?,
              image: t.image,
              selected: c.activeTemplate == t.name,
              favorite: c.favorites.contains(t.name),
              onFavorite: () => c.toggleFavorite(t.name),
              onTap: () => c.applyTemplate(t.recipe, layer: false),
            ),
        ];
      case '즐겨찾기':
        return [
          for (final t in c.presetThumbs.where((t) => c.favorites.contains(t.name))) preset(t),
          for (final t in c.userThumbs.where((t) => c.favorites.contains(t.name))) mine(t),
        ];
      case '내 룩':
        return [for (final t in c.userThumbs) mine(t)];
      case '전체':
        return [for (final t in c.presetThumbs) preset(t)];
      default:
        return [for (final t in c.presetThumbs.where((t) => t.recipe['category'] == filter)) preset(t)];
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = c.busy != null;
    final cards = _cards();
    const sceneNames = {'Portrait': '인물', 'Landscape': '풍경', 'Night': '야경', 'Sunset': '노을', 'General': '일반'};
    final scene = sceneNames[c.stats?['scene']];
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
          _promptCard(busy),
          if (c.aiThumbs.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text((c.aiAnalysis ?? '').isEmpty ? 'AI가 고른 4가지' : c.aiAnalysis!,
                      style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4)),
                ),
                IconButton(
                  tooltip: 'AI 결과 닫기',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: () {
                    c.aiThumbs = [];
                    c.aiAnalysis = null;
                    c.touch();
                  },
                  icon: const Icon(Icons.close, color: textDim),
                ),
              ]),
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
            ]),
            const SizedBox(height: 8),
          ],
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final f in ['추천', '즐겨찾기', '내 룩', '전체', ...templateCategories])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    showCheckmark: false,
                    label: Text(f == '즐겨찾기' ? '♥ 즐겨찾기' : f, style: const TextStyle(fontSize: 13)),
                    selected: filter == f,
                    onSelected: (_) => setState(() => filter = f),
                  ),
                ),
            ]),
          ),
          if (filter == '추천' && scene != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
              child: Text('$scene 사진으로 보고 어울리는 룩을 골랐어요', style: const TextStyle(color: textDim, fontSize: 12)),
            ),
          if (cards.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                switch (filter) {
                  '즐겨찾기' => '마음에 드는 룩의 ♥를 누르면 여기에 모여요.',
                  '내 룩' => '지금 보정을 저장하거나, 공유받은 룩(.json)·LUT(.cube)을 가져올 수 있어요. 위쪽 ⋯ 메뉴를 눌러 보세요.',
                  _ => '사진을 분석하는 중이에요…',
                },
                textAlign: TextAlign.center,
                style: const TextStyle(color: textDim, fontSize: 13, height: 1.5),
              ),
            )
          else
            _grid(cards),
        ]),
      ),
      if (c.templateBlendActive)
        Container(
          decoration: const BoxDecoration(color: cardColor, border: Border(top: BorderSide(color: Colors.white10))),
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 8),
          child: Row(children: [
            Expanded(
              child: AdjustSlider(
                label: c.activeTemplate ?? '룩 세기',
                value: c.templateAmount,
                min: 0,
                max: 1.5,
                reset: 1,
                display: (v) => '${(v * 100).round()}%',
                onChanged: (v) => c.setTemplateAmount(v),
                onChangeEnd: (v) => c.setTemplateAmount(v, commit: true),
              ),
            ),
            IconButton(tooltip: '룩 빼기', onPressed: c.clearLook, icon: const Icon(Icons.layers_clear_outlined, color: textDim)),
          ]),
        ),
    ]);
  }
}
