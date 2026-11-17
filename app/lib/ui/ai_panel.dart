import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../ai/ai_service.dart';
import 'editor_controller.dart';
import 'panels.dart';
import 'theme.dart';
import 'widgets.dart';

class AiPanel extends StatefulWidget {
  const AiPanel(this.c, {super.key});
  final EditorController c;
  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final _request = TextEditingController();
  final _link = TextEditingController();
  AiSettings? _settings;
  double _matchStrength = 0.8;

  static const quick = ['적외선 촬영처럼', '플래시가 터진 것처럼', '필름 카메라 느낌', '시네마틱 영화처럼', '따뜻한 봄 감성', '차갑고 무디하게', '깔끔한 인물 보정'];

  @override
  void initState() {
    super.initState();
    AiSettings.load().then((s) => mounted ? setState(() => _settings = s) : null);
  }

  Future<void> _runAi({String? request, String? guideUrl, String? referencePath}) async {
    final c = widget.c;
    final s = c.session;
    final settings = _settings;
    if (s == null || settings == null) return;
    if (settings.apiKey.isEmpty) {
      await _openSettings();
      if ((_settings?.apiKey ?? '').isEmpty) return;
    }
    await c.withBusy('${_settings!.provider.label}가 보정안 4가지를 만드는 중…', () async {
      String? guide;
      if (guideUrl != null && guideUrl.trim().isNotEmpty) guide = await fetchGuideText(guideUrl);
      await c.runAi(settings: _settings!, request: request ?? '', guideText: guide, referencePath: referencePath);
    });
  }

  Future<void> _matchReference({required bool useAi}) async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: '이미지', extensions: ['jpg', 'jpeg', 'png', 'tif', 'tiff'])
    ]);
    if (f == null) return;
    if (useAi) {
      await _runAi(request: '두 번째 사진(참조)과 같은 색감·톤으로 보정해 주세요. ${_request.text}', referencePath: f.path);
      return;
    }
    final c = widget.c;
    await c.withBusy('참조 사진 색감 분석 중…', () async {
      final r = await c.session!.matchReference(c.recipe, f.path, _matchStrength);
      c.setRecipe(r);
    });
  }

  Future<void> _openSettings() async {
    final result = await showDialog<AiSettings>(context: context, builder: (_) => _AiSettingsDialog(initial: _settings!));
    if (result != null) {
      await result.save();
      setState(() => _settings = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final c = widget.c;
    final busy = c.busy != null;
    final noKey = s != null && s.apiKey.isEmpty;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      // Who answers + settings.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 10, 10),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: noKey ? AppColors.surface2 : AppColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(noKey ? Icons.key_off_rounded : Icons.bolt_rounded, size: 14, color: noKey ? AppColors.textDim : AppColors.accent),
              const SizedBox(width: 5),
              Text(
                s == null ? '…' : (noKey ? 'API 키를 먼저 설정하세요' : '${s.provider.label} · ${s.model}'),
                style: TextStyle(fontSize: 12, color: noKey ? AppColors.textDim : AppColors.accent, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
          const Spacer(),
          IconButton(tooltip: 'AI 설정', onPressed: s == null ? null : _openSettings, icon: const Icon(Icons.settings_rounded, size: 20)),
        ]),
      ),
      // Composer.
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(4, 4, 6, 6),
        decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          TextField(
            controller: _request,
            minLines: 2,
            maxLines: 5,
            style: const TextStyle(fontSize: 14, height: 1.4),
            decoration: const InputDecoration(
              hintText: '어떤 느낌으로 바꿔볼까요?\n예) 적외선 사진처럼, 하늘은 더 파랗게',
              fillColor: Colors.transparent,
              focusedBorder: InputBorder.none,
            ),
            onSubmitted: busy ? null : (v) => _runAi(request: v),
          ),
          GradientButton(
            label: '보정안 만들기',
            icon: Icons.arrow_upward_rounded,
            height: 38,
            onPressed: busy ? null : () => _runAi(request: _request.text),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          for (final q in quick)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                label: Text(q),
                labelStyle: const TextStyle(fontSize: 12.5, color: AppColors.textDim),
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
      if (c.aiThumbs.isNotEmpty) ...[
        const SectionLabel('AI가 만든 보정안'),
        if ((c.aiAnalysis ?? '').isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface2.withValues(alpha: 0.55),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(18),
              ),
            ),
            child: Text(c.aiAnalysis!, style: const TextStyle(color: AppColors.text, fontSize: 13, height: 1.5)),
          ),
        ThumbGrid(
          count: c.aiThumbs.length,
          minTile: 140,
          builder: (i, size) => Tooltip(
            message: (c.aiThumbs[i].recipe['description'] as String?) ?? '',
            child: ThumbTile(
              size: size,
              label: c.aiThumbs[i].name,
              image: c.aiThumbs[i].image,
              selected: c.activeTemplate == c.aiThumbs[i].name,
              onTap: () => c.pickAiVariation(c.aiThumbs[i].recipe),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (c.templateBlendActive) AmountSlider(c),
      ],
      const SizedBox(height: 8),
      SoftCard(
        title: '이 사진처럼 해줘',
        icon: Icons.photo_library_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const HintText('좋아하는 보정 사진을 고르면 그 색감을 따라가요.'),
          AdjustSlider(
            label: '따라가는 정도',
            value: _matchStrength,
            min: 0,
            max: 1,
            reset: 0.8,
            display: (v) => '${(v * 100).round()}%',
            onChanged: (v) => setState(() => _matchStrength = v),
            onChangeEnd: (_) {},
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(spacing: 8, children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => _matchReference(useAi: false),
                  child: const Text('색만 정확히 맞추기', textAlign: TextAlign.center),
                ),
              ),
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => _matchReference(useAi: true),
                  child: const Text('AI가 분석해서 따라하기', textAlign: TextAlign.center),
                ),
              ),
            ]),
          ),
        ]),
      ),
      SoftCard(
        title: '보정 가이드 글로 보정',
        icon: Icons.link_rounded,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _link,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(hintText: 'https://… 보정 방법이 담긴 글', isDense: true, fillColor: AppColors.surface3),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : () => _runAi(request: '링크의 보정 가이드대로 보정해 주세요. ${_request.text}', guideUrl: _link.text),
              child: const Text('적용'),
            ),
          ]),
        ),
      ),
      const HintText('AI는 사진을 새로 그리지 않아요. 검증된 템플릿·강도·미세 조정값만 골라 4가지 안을 만들기 때문에 화질 손실이 없고, 결과는 언제든 다시 다듬을 수 있어요.'),
    ]);
  }
}
class _AiSettingsDialog extends StatefulWidget {
  const _AiSettingsDialog({required this.initial});
  final AiSettings initial;
  @override
  State<_AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialog> {
  late AiProvider provider = widget.initial.provider;
  late final model = TextEditingController(text: widget.initial.model);
  late final key = TextEditingController(text: widget.initial.apiKey);
  bool obscure = true;

  Future<void> _switch(AiProvider p) async {
    final s = await AiSettings.loadFor(p);
    setState(() {
      provider = p;
      model.text = s.model;
      key.text = s.apiKey;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('AI 설정'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<AiProvider>(
            segments: [for (final p in AiProvider.values) ButtonSegment(value: p, label: Text(p.label))],
            selected: {provider},
            onSelectionChanged: (s) => _switch(s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: key,
            obscureText: obscure,
            decoration: InputDecoration(
              labelText: '${provider.label} API 키',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => obscure = !obscure)),
            ),
          ),
          const SizedBox(height: 4),
          SelectableText('키 발급: ${provider.keyHelpUrl}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 12),
          TextField(
            controller: model,
            decoration: InputDecoration(labelText: '모델 (기본: ${provider.defaultModel})', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          const Text('키는 이 기기에만 암호화되어 저장되고, 보정 요청 시 해당 AI 회사로만 전송됩니다.',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: () => Navigator.pop(context, AiSettings(provider: provider, model: model.text, apiKey: key.text)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}
