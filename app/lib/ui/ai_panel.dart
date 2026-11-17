import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../ai/ai_service.dart';
import 'editor_controller.dart';
import 'panels.dart';
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
    final busy = widget.c.busy != null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        const Icon(Icons.auto_fix_high, size: 18, color: accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(s == null ? '' : '${s.provider.label} · ${s.model}${s.apiKey.isEmpty ? ' · 키 없음' : ''}',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
        TextButton.icon(onPressed: s == null ? null : _openSettings, icon: const Icon(Icons.settings, size: 16), label: const Text('AI 설정')),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: _request,
        minLines: 1,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: '어떻게 보정할까요? 예) 적외선 촬영처럼, 하늘은 더 파랗게',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: busy ? null : (v) => _runAi(request: v),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final q in quick)
          ActionChip(label: Text(q, style: const TextStyle(fontSize: 12)), onPressed: busy ? null : () {
            _request.text = q;
            _runAi(request: q);
          }),
      ]),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: busy ? null : () => _runAi(request: _request.text),
        icon: const Icon(Icons.auto_awesome),
        label: const Text('AI로 보정하기'),
      ),
      if (widget.c.aiThumbs.isNotEmpty) ...[
        const SizedBox(height: 16),
        if ((widget.c.aiAnalysis ?? '').isNotEmpty)
          Text(widget.c.aiAnalysis!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(children: [
          for (final t in widget.c.aiThumbs)
            Tooltip(
              message: (t.recipe['description'] as String?) ?? '',
              child: ThumbTile(
                label: t.name,
                image: t.image,
                selected: widget.c.activeTemplate == t.name,
                onTap: () => widget.c.pickAiVariation(t.recipe),
              ),
            ),
        ]),
        if (widget.c.templateBlendActive) AmountSlider(widget.c),
      ],
      const Divider(height: 32),
      const Text('참조 사진 따라하기', style: TextStyle(color: Colors.white54, fontSize: 12)),
      AdjustSlider(
        label: '색 매칭 강도',
        value: _matchStrength,
        min: 0,
        max: 1,
        reset: 0.8,
        onChanged: (v) => setState(() => _matchStrength = v),
        onChangeEnd: (_) {},
      ),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: busy ? null : () => _matchReference(useAi: false),
            child: const Text('정밀 색 매칭 (오프라인)'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: busy ? null : () => _matchReference(useAi: true),
            child: const Text('AI가 분석해서 따라하기'),
          ),
        ),
      ]),
      const Divider(height: 32),
      const Text('보정 가이드 링크', style: TextStyle(color: Colors.white54, fontSize: 12)),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _link,
            decoration: const InputDecoration(hintText: 'https://… 보정 방법이 담긴 글', border: OutlineInputBorder(), isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: busy ? null : () => _runAi(request: '링크의 보정 가이드대로 보정해 주세요. ${_request.text}', guideUrl: _link.text),
          child: const Text('적용'),
        ),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Text('AI는 사진을 새로 그리지 않습니다. 히스토그램 기본 보정 위에 검증된 템플릿·강도·미세 조정값만 골라 4가지 안을 만들어요. 결과는 슬라이더로 다시 조정하거나 템플릿으로 저장할 수 있습니다.',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
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
