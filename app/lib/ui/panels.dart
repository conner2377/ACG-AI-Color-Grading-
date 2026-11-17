import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../engine/recipe.dart';
import 'editor_controller.dart';
import 'widgets.dart';

const templateCategories = ['기본', '필름', '감성', '깊이감', '시네마', '인물', '풍경', '야경', '흑백', '특수'];

/// Builds a slider bound to a recipe field.
Widget recipeSlider(EditorController c, String label, String path,
    {double min = -1, double max = 1, String Function(double)? display, Gradient? track}) {
  return AdjustSlider(
    label: label,
    value: path.contains('.') ? getNum(c.recipe, path) : getVal(c.recipe, path),
    min: min,
    max: max,
    display: display,
    track: track,
    onChanged: (v) => c.edit((r) => setNum(r, path, v)),
    onChangeEnd: (_) => c.commitHistory(),
  );
}

String evDisplay(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)} EV';

class LightPanel extends StatelessWidget {
  const LightPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) => ListView(children: [
        HistogramView(c.histogram),
        recipeSlider(c, '노출', 'exposure', min: -5, max: 5, display: evDisplay),
        recipeSlider(c, '대비', 'contrast'),
        recipeSlider(c, '하이라이트', 'highlights'),
        recipeSlider(c, '섀도우', 'shadows'),
        recipeSlider(c, '흰색 계열', 'whites'),
        recipeSlider(c, '검정 계열', 'blacks'),
        recipeSlider(c, '페이드 (매트)', 'fade', min: 0, max: 1),
      ]);
}

class ColorPanel extends StatefulWidget {
  const ColorPanel(this.c, {super.key});
  final EditorController c;
  @override
  State<ColorPanel> createState() => _ColorPanelState();
}

class _ColorPanelState extends State<ColorPanel> {
  int band = 0;
  static const bandColors = [
    Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835), Color(0xFF43A047),
    Color(0xFF00ACC1), Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFFD81B60),
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return ListView(children: [
      recipeSlider(c, '색온도', 'temperature', track: tempGradient),
      recipeSlider(c, '색조', 'tint', track: tintGradient),
      recipeSlider(c, '생동감', 'vibrance'),
      recipeSlider(c, '채도', 'saturation'),
      const Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 4),
        child: Text('색상 혼합 (HSL)', style: TextStyle(color: Colors.white54, fontSize: 12)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Wrap(spacing: 10, children: [
          for (var i = 0; i < 8; i++)
            Tooltip(
              message: hslBandNames[i],
              child: GestureDetector(
                onTap: () => setState(() => band = i),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: bandColors[i],
                    shape: BoxShape.circle,
                    border: Border.all(color: band == i ? Colors.white : Colors.transparent, width: 2),
                  ),
                ),
              ),
            ),
        ]),
      ),
      recipeSlider(c, '${hslBandNames[band]} 색조', 'hsl.$band.hue', min: -45, max: 45, display: (v) => v.round().toString()),
      recipeSlider(c, '${hslBandNames[band]} 채도', 'hsl.$band.sat'),
      recipeSlider(c, '${hslBandNames[band]} 휘도', 'hsl.$band.lum'),
      SwitchListTile(
        dense: true,
        title: const Text('흑백', style: TextStyle(fontSize: 13)),
        value: getBool(c.recipe, 'monochrome'),
        onChanged: (v) => c.edit((r) => r['monochrome'] = v, commit: true),
      ),
      recipeSlider(c, '피부톤 보호', 'skin_protect', min: 0, max: 1),
      const Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 4),
        child: Text('캘리브레이션 (원색)', style: TextStyle(color: Colors.white54, fontSize: 12)),
      ),
      recipeSlider(c, '빨강 원색 색조', 'cal_red_hue'),
      recipeSlider(c, '빨강 원색 채도', 'cal_red_sat'),
      recipeSlider(c, '초록 원색 색조', 'cal_green_hue'),
      recipeSlider(c, '초록 원색 채도', 'cal_green_sat'),
      recipeSlider(c, '파랑 원색 색조', 'cal_blue_hue'),
      recipeSlider(c, '파랑 원색 채도', 'cal_blue_sat'),
    ]);
  }
}

class EffectsPanel extends StatelessWidget {
  const EffectsPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) => ListView(children: [
        recipeSlider(c, '텍스처', 'texture'),
        recipeSlider(c, '부분 대비 (Clarity)', 'clarity'),
        recipeSlider(c, '디헤이즈', 'dehaze'),
        recipeSlider(c, '비네팅', 'vignette'),
        recipeSlider(c, '선명하게', 'sharpen', min: 0, max: 1),
        recipeSlider(c, '노이즈 감소', 'noise_reduction', min: 0, max: 1),
        recipeSlider(c, '색상 노이즈 감소', 'color_noise_reduction', min: 0, max: 1),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 16, 24, 4),
          child: Text('필름 효과', style: TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        recipeSlider(c, '그레인', 'grain', min: 0, max: 1),
        AdjustSlider(
          label: '그레인 크기',
          value: getVal(c.recipe, 'grain_size'),
          min: 0,
          max: 1,
          reset: 0.3,
          onChanged: (v) => c.edit((r) => r['grain_size'] = v),
          onChangeEnd: (_) => c.commitHistory(),
        ),
        recipeSlider(c, '할레이션 (붉은 빛번짐)', 'halation', min: 0, max: 1),
        recipeSlider(c, '블룸 (빛 번짐)', 'bloom', min: 0, max: 1),
      ]);
}

class GradingPanel extends StatelessWidget {
  const GradingPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) {
    Widget wheel(String title, String key) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Text(title, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          recipeSlider(c, '색상', '$key.hue', min: 0, max: 360, display: (v) => '${v.round()}°', track: hueGradient),
          recipeSlider(c, '강도', '$key.sat', min: 0, max: 1),
        ]);
    return ListView(children: [
      wheel('섀도우', 'grade_shadows'),
      wheel('미드톤', 'grade_midtones'),
      wheel('하이라이트', 'grade_highlights'),
      recipeSlider(c, '균형 (섀도우 ↔ 하이라이트)', 'grade_balance'),
    ]);
  }
}

class CurvePanel extends StatefulWidget {
  const CurvePanel(this.c, {super.key});
  final EditorController c;
  @override
  State<CurvePanel> createState() => _CurvePanelState();
}

class _CurvePanelState extends State<CurvePanel> {
  String channel = 'curve';
  static const channels = {'curve': ('전체', Colors.white), 'curve_r': ('R', Colors.redAccent), 'curve_g': ('G', Colors.greenAccent), 'curve_b': ('B', Colors.lightBlueAccent)};

  List<List<double>> _points() {
    final v = widget.c.recipe[channel];
    if (v is List) return [for (final p in v) [(p[0] as num).toDouble(), (p[1] as num).toDouble()]];
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        for (final e in channels.entries)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(e.value.$1),
              selected: channel == e.key,
              onSelected: (_) => setState(() => channel = e.key),
            ),
          ),
        const Spacer(),
        TextButton(onPressed: () => c.edit((r) => r[channel] = <List<double>>[], commit: true), child: const Text('초기화')),
      ]),
      const SizedBox(height: 8),
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: CurveEditor(
            points: _points(),
            color: channels[channel]!.$2,
            onChanged: (p) => c.edit((r) => r[channel] = p),
            onChangeEnd: (p) => c.edit((r) => r[channel] = p, commit: true),
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('탭: 점 추가 · 드래그: 이동 · 더블탭: 점 삭제', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    ]);
  }
}

class AutoPanel extends StatelessWidget {
  const AutoPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) {
    final scene = c.stats?['scene'];
    const sceneNames = {'Portrait': '인물', 'Landscape': '풍경', 'Night': '야경', 'Sunset': '노을', 'General': '일반'};
    return ListView(padding: const EdgeInsets.symmetric(vertical: 12), children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          FilledButton.icon(
            onPressed: c.busy == null ? c.runAuto : null,
            icon: const Icon(Icons.auto_awesome),
            label: Text(c.candidateThumbs.isEmpty ? '사진 분석하고 보정 후보 만들기' : '다시 분석'),
          ),
          const SizedBox(width: 12),
          if (scene != null) Text('장면: ${sceneNames[scene] ?? scene}', style: const TextStyle(color: Colors.white54)),
        ]),
      ),
      const SizedBox(height: 12),
      if (c.templateBlendActive) AmountSlider(c),
      if (c.candidateThumbs.isNotEmpty)
        thumbGrid([
          for (final t in c.candidateThumbs)
            ThumbTile(
              label: t.name,
              image: t.image,
              selected: c.activeTemplate == t.name,
              onTap: () => c.applyTemplate(t.recipe, layer: false),
            ),
        ]),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text('후보를 고른 뒤 빛·색상 패널에서 이어서 다듬을 수 있습니다.', style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    ]);
  }
}

/// Wrapping grid of thumbnails (many candidates/templates at once).
Widget thumbGrid(List<Widget> tiles) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Wrap(spacing: 0, runSpacing: 4, children: tiles),
    );

class AmountSlider extends StatelessWidget {
  const AmountSlider(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) => AdjustSlider(
        label: '적용 강도${c.activeTemplate != null ? ' · ${c.activeTemplate}' : ''}',
        value: c.templateAmount,
        min: 0,
        max: 1.5,
        reset: 1,
        display: (v) => '${(v * 100).round()}%',
        onChanged: (v) => c.setTemplateAmount(v),
        onChangeEnd: (v) => c.setTemplateAmount(v, commit: true),
      );
}

class TemplatesPanel extends StatelessWidget {
  const TemplatesPanel(this.c, {super.key});
  final EditorController c;

  Future<void> _save(BuildContext context) async {
    final ctrl = TextEditingController(text: (c.recipe['name'] as String?) ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('템플릿으로 저장'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '템플릿 이름')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('저장')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await c.saveUserTemplate(name);
  }

  Future<void> _import() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: '템플릿', extensions: ['json', 'cube']),
    ]);
    if (f == null) return;
    await c.withBusy('템플릿 가져오는 중…', () async {
      final Map<String, dynamic> t;
      if (f.path.toLowerCase().endsWith('.cube')) {
        t = await engineLoadCube(f.path);
      } else {
        t = jsonDecode(await File(f.path).readAsString()) as Map<String, dynamic>;
        t['name'] ??= f.name.replaceAll(RegExp(r'\.json$'), '');
      }
      await c.importTemplate(t);
    });
  }

  Future<void> _export() async {
    final name = (c.recipe['name'] as String?)?.isNotEmpty == true ? c.recipe['name'] as String : '내 보정';
    final loc = await getSaveLocation(suggestedName: '$name.json', acceptedTypeGroups: [
      const XTypeGroup(label: '템플릿', extensions: ['json'])
    ]);
    if (loc == null) return;
    await File(loc.path).writeAsString(const JsonEncoder.withIndent('  ').convert(c.recipe));
  }

  @override
  Widget build(BuildContext context) {
    Widget strip(List<PhotoThumb> items, {bool user = false}) => SizedBox(
          height: 124,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final t in items)
              ThumbTile(
                label: t.name,
                image: t.image,
                selected: c.activeTemplate == t.name,
                onTap: () => c.applyTemplate(t.recipe, layer: !user),
                onLongPress: user
                    ? () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('"${t.name}" 삭제할까요?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
                            ],
                          ),
                        );
                        if (ok == true) await c.deleteUserTemplate(t.name);
                      }
                    : null,
              ),
          ]),
        );
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      if (c.templateBlendActive) AmountSlider(c),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final cat in [null, ...templateCategories])
            ChoiceChip(
              label: Text(cat ?? '전체', style: const TextStyle(fontSize: 12)),
              selected: c.templateCategory == cat,
              onSelected: (_) {
                c.templateCategory = cat;
                c.touch();
              },
            ),
        ]),
      ),
      thumbGrid([
        for (final t in c.presetThumbs.where((t) => c.templateCategory == null || t.recipe['category'] == c.templateCategory))
          Tooltip(
            message: (t.recipe['description'] as String?) ?? '',
            waitDuration: const Duration(milliseconds: 400),
            child: ThumbTile(
              label: t.name,
              image: t.image,
              selected: c.activeTemplate == t.name,
              onTap: () => c.applyTemplate(t.recipe),
            ),
          ),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
        child: Row(children: [
          const Text('내 템플릿', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const Spacer(),
          TextButton(onPressed: () => _save(context), child: const Text('현재 보정 저장')),
          TextButton(onPressed: _import, child: const Text('가져오기')),
          TextButton(onPressed: _export, child: const Text('내보내기')),
        ]),
      ),
      if (c.userThumbs.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('저장한 템플릿이 없습니다. 공유받은 템플릿(.json)이나 LUT(.cube)도 가져올 수 있습니다.', style: TextStyle(color: Colors.white38, fontSize: 12)),
        )
      else
        strip(c.userThumbs, user: true),
    ]);
  }
}
