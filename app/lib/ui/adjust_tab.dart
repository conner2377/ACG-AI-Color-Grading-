// "다듬기" tab: a few plain-language sliders per section, with the professional
// controls tucked behind "자세히".

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

class AdjustTab extends StatefulWidget {
  const AdjustTab(this.c, {super.key});
  final EditorController c;
  @override
  State<AdjustTab> createState() => _AdjustTabState();
}

class _AdjustTabState extends State<AdjustTab> {
  final open = <String>{'빛'};
  final more = <String>{};
  int band = 0;
  String curveChannel = 'curve';

  static const bandColors = [
    Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835), Color(0xFF43A047),
    Color(0xFF00ACC1), Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFFD81B60),
  ];
  static const curveChannels = {
    'curve': ('전체', Colors.white),
    'curve_r': ('R', Colors.redAccent),
    'curve_g': ('G', Colors.greenAccent),
    'curve_b': ('B', Colors.lightBlueAccent),
  };

  EditorController get c => widget.c;

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
        child: Text(t, style: const TextStyle(color: textDim, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  /// Section with simple controls and an optional "자세히" block.
  Widget _section(String title, IconData icon, List<Widget> simple, [List<Widget> advanced = const []]) {
    final isOpen = open.contains(title);
    final showMore = more.contains(title);
    return SectionCard(
      icon: icon,
      title: title,
      open: isOpen,
      onToggle: () => setState(() => isOpen ? open.remove(title) : open.add(title)),
      children: [
        ...simple,
        if (advanced.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => showMore ? more.remove(title) : more.add(title)),
              icon: Icon(showMore ? Icons.remove : Icons.add, size: 16),
              label: Text(showMore ? '간단히' : '자세히'),
              style: TextButton.styleFrom(foregroundColor: textDim, padding: const EdgeInsets.symmetric(horizontal: 16)),
            ),
          ),
        if (showMore) ...advanced,
      ],
    );
  }

  List<List<double>> _curvePoints() {
    final v = c.recipe[curveChannel];
    if (v is List) return [for (final p in v) [(p[0] as num).toDouble(), (p[1] as num).toDouble()]];
    return [];
  }

  Widget _wheel(String title, String key) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _label(title),
        recipeSlider(c, '색', '$key.hue', min: 0, max: 360, display: (v) => '${v.round()}°', track: hueGradient),
        recipeSlider(c, '세기', '$key.sat', min: 0, max: 1),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.only(top: 12, bottom: 24), children: [
      _section('빛', Icons.wb_sunny_outlined, [
        recipeSlider(c, '밝기', 'exposure', min: -3, max: 3, display: evDisplay),
        recipeSlider(c, '대비', 'contrast'),
        recipeSlider(c, '밝은 곳', 'highlights'),
        recipeSlider(c, '어두운 곳', 'shadows'),
      ], [
        HistogramView(c.histogram),
        recipeSlider(c, '가장 밝은 점', 'whites'),
        recipeSlider(c, '가장 어두운 점', 'blacks'),
        _label('톤 커브'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            for (final e in curveChannels.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(e.value.$1),
                  selected: curveChannel == e.key,
                  onSelected: (_) => setState(() => curveChannel = e.key),
                ),
              ),
            const Spacer(),
            TextButton(
                onPressed: () => c.edit((r) => r[curveChannel] = <List<double>>[], commit: true), child: const Text('초기화')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: CurveEditor(
            points: _curvePoints(),
            color: curveChannels[curveChannel]!.$2,
            onChanged: (p) => c.edit((r) => r[curveChannel] = p),
            onChangeEnd: (p) => c.edit((r) => r[curveChannel] = p, commit: true),
          ),
        ),
        const Center(child: Text('탭: 점 추가 · 드래그: 이동 · 더블탭: 삭제', style: TextStyle(color: textDim, fontSize: 12))),
      ]),
      _section('색', Icons.palette_outlined, [
        recipeSlider(c, '따뜻함', 'temperature', track: tempGradient),
        recipeSlider(c, '생동감', 'vibrance'),
        recipeSlider(c, '색 진하기', 'saturation'),
        SwitchListTile(
          dense: true,
          title: const Text('흑백', style: TextStyle(fontSize: 13)),
          value: getBool(c.recipe, 'monochrome'),
          onChanged: (v) => c.edit((r) => r['monochrome'] = v, commit: true),
        ),
      ], [
        recipeSlider(c, '초록 ↔ 자홍', 'tint', track: tintGradient),
        recipeSlider(c, '피부톤 보호', 'skin_protect', min: 0, max: 1),
        _label('색깔별 조정'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (var i = 0; i < 8; i++)
              Tooltip(
                message: hslBandNames[i],
                child: GestureDetector(
                  onTap: () => setState(() => band = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: band == i ? 30 : 24,
                    height: band == i ? 30 : 24,
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
        recipeSlider(c, '${hslBandNames[band]} 진하기', 'hsl.$band.sat'),
        recipeSlider(c, '${hslBandNames[band]} 밝기', 'hsl.$band.lum'),
        _wheel('어두운 곳에 색 입히기', 'grade_shadows'),
        _wheel('중간 밝기에 색 입히기', 'grade_midtones'),
        _wheel('밝은 곳에 색 입히기', 'grade_highlights'),
        recipeSlider(c, '균형 (어두운 곳 ↔ 밝은 곳)', 'grade_balance'),
        _label('원색 보정'),
        recipeSlider(c, '빨강 색조', 'cal_red_hue'),
        recipeSlider(c, '빨강 진하기', 'cal_red_sat'),
        recipeSlider(c, '초록 색조', 'cal_green_hue'),
        recipeSlider(c, '초록 진하기', 'cal_green_sat'),
        recipeSlider(c, '파랑 색조', 'cal_blue_hue'),
        recipeSlider(c, '파랑 진하기', 'cal_blue_sat'),
      ]),
      _section('분위기', Icons.blur_on, [
        recipeSlider(c, '빛바랜 느낌', 'fade', min: 0, max: 1),
        recipeSlider(c, '필름 입자', 'grain', min: 0, max: 1),
        recipeSlider(c, '빛 번짐', 'bloom', min: 0, max: 1),
        recipeSlider(c, '주변 어둡게 ↔ 밝게', 'vignette'),
      ], [
        recipeSlider(c, '입자 크기', 'grain_size', min: 0, max: 1),
        recipeSlider(c, '붉은 빛 번짐 (할레이션)', 'halation', min: 0, max: 1),
        recipeSlider(c, '안개 걷기', 'dehaze'),
      ]),
      _section('선명함', Icons.center_focus_strong, [
        recipeSlider(c, '선명하게', 'sharpen', min: 0, max: 1),
        recipeSlider(c, '질감', 'texture'),
        recipeSlider(c, '또렷함', 'clarity'),
      ], [
        recipeSlider(c, '노이즈 줄이기', 'noise_reduction', min: 0, max: 1),
        recipeSlider(c, '색 노이즈 줄이기', 'color_noise_reduction', min: 0, max: 1),
      ]),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text('슬라이더 이름을 두 번 누르면 원래 값으로 돌아가요.', style: TextStyle(color: textDim, fontSize: 12)),
      ),
    ]);
  }
}
