// Manual adjustment panels, one per tool tab: 빛 · 색 · 커브 · 그레이딩 · 효과.

import 'package:flutter/material.dart';

import '../engine/recipe.dart';
import 'editor_controller.dart';
import 'widgets.dart';

/// A slider bound to a recipe field.
Widget recipeSlider(EditorController c, String label, String path,
    {double min = -1, double max = 1, double? reset, String Function(double)? display, Gradient? track}) {
  return AdjustSlider(
    label: label,
    value: path.contains('.') ? getNum(c.recipe, path) : getVal(c.recipe, path),
    min: min,
    max: max,
    reset: reset ?? (recipeDefaults[path] ?? 0),
    display: display,
    track: track,
    onChanged: (v) => c.edit((r) => setNum(r, path, v)),
    onChangeEnd: (_) => c.commitHistory(),
  );
}

String evDisplay(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

Widget _list(List<Widget> children) => ListView(padding: const EdgeInsets.only(bottom: 24), children: children);

const _hint = Padding(
  padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
  child: Text('슬라이더 이름을 더블클릭하면 초기화돼요.', style: TextStyle(color: textDim, fontSize: 11.5)),
);

class LightPanel extends StatelessWidget {
  const LightPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) => _list([
        HistogramView(c.histogram),
        const PanelLabel('노출'),
        recipeSlider(c, '노출', 'exposure', min: -3, max: 3, display: evDisplay),
        recipeSlider(c, '대비', 'contrast'),
        const PanelLabel('톤'),
        recipeSlider(c, '하이라이트', 'highlights'),
        recipeSlider(c, '섀도우', 'shadows'),
        recipeSlider(c, '흰색 계열', 'whites'),
        recipeSlider(c, '검정 계열', 'blacks'),
        const PanelLabel('분위기'),
        recipeSlider(c, '페이드 (매트 블랙)', 'fade', min: 0, max: 1),
        recipeSlider(c, '디헤이즈', 'dehaze'),
        _hint,
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
    Color(0xFFE05252), Color(0xFFE08A3C), Color(0xFFE0C84A), Color(0xFF5BB35B),
    Color(0xFF3FB5C4), Color(0xFF4A7FE0), Color(0xFF9563D6), Color(0xFFD65C9C),
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return _list([
      const PanelLabel('화이트 밸런스'),
      recipeSlider(c, '색온도', 'temperature', track: tempGradient),
      recipeSlider(c, '색조', 'tint', track: tintGradient),
      const PanelLabel('채도'),
      recipeSlider(c, '생동감', 'vibrance'),
      recipeSlider(c, '채도', 'saturation'),
      recipeSlider(c, '피부톤 보호', 'skin_protect', min: 0, max: 1),
      SwitchListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: const Text('흑백', style: TextStyle(fontSize: 12.5)),
        value: getBool(c.recipe, 'monochrome'),
        onChanged: (v) => c.edit((r) => r['monochrome'] = v, commit: true),
      ),
      const PanelLabel('색상 혼합 (HSL)'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (var i = 0; i < 8; i++)
            Tooltip(
              message: hslBandNames[i],
              child: GestureDetector(
                onTap: () => setState(() => band = i),
                child: Container(
                  width: 24,
                  height: 24,
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
      const PanelLabel('캘리브레이션 (원색)'),
      recipeSlider(c, '빨강 원색 색조', 'cal_red_hue'),
      recipeSlider(c, '빨강 원색 채도', 'cal_red_sat'),
      recipeSlider(c, '초록 원색 색조', 'cal_green_hue'),
      recipeSlider(c, '초록 원색 채도', 'cal_green_sat'),
      recipeSlider(c, '파랑 원색 색조', 'cal_blue_hue'),
      recipeSlider(c, '파랑 원색 채도', 'cal_blue_sat'),
      _hint,
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
  static const channels = {
    'curve': ('RGB', Colors.white),
    'curve_r': ('R', Color(0xFFE06060)),
    'curve_g': ('G', Color(0xFF60C070)),
    'curve_b': ('B', Color(0xFF6090E0)),
  };

  List<List<double>> _points() {
    final v = widget.c.recipe[channel];
    if (v is List) return [for (final p in v) [(p[0] as num).toDouble(), (p[1] as num).toDouble()]];
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return _list([
      HistogramView(c.histogram, height: 56),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Row(children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [for (final e in channels.entries) ButtonSegment(value: e.key, label: Text(e.value.$1))],
            selected: {channel},
            onSelectionChanged: (s) => setState(() => channel = s.first),
          ),
          const Spacer(),
          TextButton(onPressed: () => c.edit((r) => r[channel] = <List<double>>[], commit: true), child: const Text('초기화')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFF0D0D0F), border: Border.all(color: borderColor)),
          child: CurveEditor(
            points: _points(),
            color: channels[channel]!.$2,
            onChanged: (p) => c.edit((r) => r[channel] = p),
            onChangeEnd: (p) => c.edit((r) => r[channel] = p, commit: true),
          ),
        ),
      ),
      const Center(child: Text('클릭: 점 추가 · 드래그: 이동 · 더블클릭: 삭제', style: TextStyle(color: textDim, fontSize: 11.5))),
    ]);
  }
}

class GradingPanel extends StatelessWidget {
  const GradingPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) {
    Widget wheel(String title, String key) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PanelLabel(title),
          recipeSlider(c, '색상', '$key.hue', min: 0, max: 360, display: (v) => '${v.round()}°', track: hueGradient),
          recipeSlider(c, '강도', '$key.sat', min: 0, max: 1),
        ]);
    return _list([
      wheel('섀도우', 'grade_shadows'),
      wheel('미드톤', 'grade_midtones'),
      wheel('하이라이트', 'grade_highlights'),
      const PanelLabel('전체'),
      recipeSlider(c, '균형', 'grade_balance'),
      _hint,
    ]);
  }
}

class EffectsPanel extends StatelessWidget {
  const EffectsPanel(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) => _list([
        const PanelLabel('디테일'),
        recipeSlider(c, '텍스처', 'texture'),
        recipeSlider(c, '부분 대비', 'clarity'),
        recipeSlider(c, '선명도', 'sharpen', min: 0, max: 1),
        const PanelLabel('노이즈 감소'),
        recipeSlider(c, '휘도', 'noise_reduction', min: 0, max: 1),
        recipeSlider(c, '색상', 'color_noise_reduction', min: 0, max: 1),
        const PanelLabel('필름'),
        recipeSlider(c, '그레인', 'grain', min: 0, max: 1),
        recipeSlider(c, '그레인 크기', 'grain_size', min: 0, max: 1),
        recipeSlider(c, '할레이션', 'halation', min: 0, max: 1),
        recipeSlider(c, '블룸', 'bloom', min: 0, max: 1),
        const PanelLabel('렌즈'),
        recipeSlider(c, '비네팅', 'vignette'),
        _hint,
      ]);
}
