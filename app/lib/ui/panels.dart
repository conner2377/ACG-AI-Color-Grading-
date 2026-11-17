import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../engine/recipe.dart';
import 'editor_controller.dart';
import 'theme.dart';
import 'widgets.dart';

const templateCategories = ['기본', '필름', '감성', '깊이감', '시네마', '인물', '풍경', '야경', '흑백', '특수'];

/// Builds a slider bound to a recipe field.
Widget recipeSlider(EditorController c, String label, String path,
    {double min = -1, double max = 1, double reset = 0, String Function(double)? display, Gradient? track}) {
  return AdjustSlider(
    label: label,
    value: path.contains('.') ? getNum(c.recipe, path) : getVal(c.recipe, path),
    min: min,
    max: max,
    reset: reset,
    display: display,
    track: track,
    onChanged: (v) => c.edit((r) => setNum(r, path, v)),
    onChangeEnd: (_) => c.commitHistory(),
  );
}

String evDisplay(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)} EV';
String pctDisplay(double v) => '${(v * 100).round()}';

/// Responsive grid of square photo tiles that fills the panel width.
class ThumbGrid extends StatelessWidget {
  const ThumbGrid({super.key, required this.count, required this.builder, this.minTile = 98});
  final int count;
  final Widget Function(int i, double size) builder;
  final double minTile;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        const gap = 10.0;
        final w = box.maxWidth - 32;
        final cols = math.max(2, ((w + gap) / (minTile + gap)).floor());
        final size = ((w - (cols - 1) * gap) / cols).floorToDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: gap, runSpacing: gap, children: [for (var i = 0; i < count; i++) builder(i, size)]),
        );
      });
}

/// Strength of the look that is currently applied (0–150%).
class AmountSlider extends StatelessWidget {
  const AmountSlider(this.c, {super.key});
  final EditorController c;
  @override
  Widget build(BuildContext context) => SoftCard(
        title: c.activeTemplate ?? '적용한 스타일',
        icon: Icons.auto_awesome_rounded,
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
        child: AdjustSlider(
          label: '강도',
          value: c.templateAmount,
          min: 0,
          max: 1.5,
          reset: 1,
          display: (v) => '${(v * 100).round()}%',
          onChanged: (v) => c.setTemplateAmount(v),
          onChangeEnd: (v) => c.setTemplateAmount(v, commit: true),
        ),
      );
}

// ---------------------------------------------------------------- 추천 (auto)

class AutoPanel extends StatelessWidget {
  const AutoPanel(this.c, {super.key});
  final EditorController c;

  static const sceneNames = {'Portrait': '인물', 'Landscape': '풍경', 'Night': '야경', 'Sunset': '노을', 'General': '일반'};
  static const sceneIcons = {
    'Portrait': Icons.face_retouching_natural_rounded,
    'Landscape': Icons.landscape_rounded,
    'Night': Icons.nightlight_round,
    'Sunset': Icons.wb_twilight_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final scene = c.stats?['scene'] as String?;
    final cands = c.candidateThumbs;
    return ListView(padding: const EdgeInsets.only(top: 4, bottom: 20), children: [
      if (cands.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: GradientButton(
            label: '사진 분석하고 보정안 만들기',
            icon: Icons.auto_awesome_rounded,
            expand: true,
            height: 52,
            onPressed: c.busy == null ? c.runAuto : null,
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
          child: Row(children: [
            if (scene != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(sceneIcons[scene] ?? Icons.photo_rounded, size: 15, color: AppColors.accent),
                  const SizedBox(width: 6),
                  Text('${sceneNames[scene] ?? scene} 사진으로 인식했어요',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.accent, fontWeight: FontWeight.w600)),
                ]),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: c.busy == null ? c.runAuto : null,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('다시 분석'),
            ),
          ]),
        ),
      if (c.templateBlendActive) AmountSlider(c),
      if (cands.isNotEmpty)
        ThumbGrid(
          count: cands.length,
          minTile: 104,
          builder: (i, size) => ThumbTile(
            size: size,
            label: cands[i].name,
            image: cands[i].image,
            badge: i == 0 ? '추천' : null,
            selected: c.activeTemplate == cands[i].name,
            onTap: () => c.applyTemplate(cands[i].recipe, layer: false),
          ),
        ),
      const SizedBox(height: 10),
      const HintText('마음에 드는 안을 누르세요. 강도를 줄이거나 조정 탭에서 이어서 다듬을 수 있어요.'),
    ]);
  }
}

// ---------------------------------------------------------------- 스타일 (templates)

class TemplatesPanel extends StatelessWidget {
  const TemplatesPanel(this.c, {super.key});
  final EditorController c;

  Future<void> _save(BuildContext context) async {
    final ctrl = TextEditingController(text: (c.recipe['name'] as String?) ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('내 스타일로 저장'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '이름 (예: 우리집 고양이 톤)')),
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
    await c.withBusy('스타일 가져오는 중…', () async {
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

  Future<void> _confirmDelete(BuildContext context, PhotoThumb t) async {
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

  @override
  Widget build(BuildContext context) {
    final presets = c.presetThumbs.where((t) => c.templateCategory == null || t.recipe['category'] == c.templateCategory).toList();
    final user = c.userThumbs;
    return ListView(padding: const EdgeInsets.only(bottom: 20), children: [
      SizedBox(
        height: 38,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          for (final cat in [null, ...templateCategories])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(cat ?? '전체'),
                selected: c.templateCategory == cat,
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  color: c.templateCategory == cat ? AppColors.accent : AppColors.textDim,
                  fontWeight: c.templateCategory == cat ? FontWeight.w700 : FontWeight.w500,
                ),
                onSelected: (_) {
                  c.templateCategory = cat;
                  c.touch();
                },
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      if (c.templateBlendActive) AmountSlider(c),
      ThumbGrid(
        count: presets.length,
        builder: (i, size) => Tooltip(
          message: (presets[i].recipe['description'] as String?) ?? '',
          child: ThumbTile(
            size: size,
            label: presets[i].name,
            image: presets[i].image,
            selected: c.activeTemplate == presets[i].name,
            onTap: () => c.applyTemplate(presets[i].recipe),
          ),
        ),
      ),
      SectionLabel('내 스타일', trailing: PopupMenuButton<int>(
        tooltip: '내 스타일 관리',
        icon: const Icon(Icons.more_horiz_rounded, size: 20, color: AppColors.textDim),
        color: AppColors.surface2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onSelected: (v) => switch (v) {
          0 => _save(context),
          1 => _import(),
          _ => _export(),
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 0, child: Text('지금 보정을 저장')),
          PopupMenuItem(value: 1, child: Text('파일에서 가져오기 (.json / .cube)')),
          PopupMenuItem(value: 2, child: Text('지금 보정을 파일로 내보내기')),
        ],
      )),
      if (user.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _save(context),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.line),
              ),
              child: const Row(children: [
                Icon(Icons.bookmark_add_outlined, color: AppColors.textDim),
                SizedBox(width: 12),
                Expanded(
                  child: Text('지금 보정을 저장해 두면 다른 사진에도 한 번에 적용할 수 있어요.',
                      style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
                ),
              ]),
            ),
          ),
        )
      else
        ThumbGrid(
          count: user.length,
          builder: (i, size) => ThumbTile(
            size: size,
            label: user[i].name,
            image: user[i].image,
            selected: c.activeTemplate == user[i].name,
            onTap: () => c.applyTemplate(user[i].recipe, layer: false),
            onLongPress: () => _confirmDelete(context, user[i]),
          ),
        ),
      if (user.isNotEmpty) const HintText('길게 누르거나 우클릭하면 삭제할 수 있어요.'),
    ]);
  }
}

// ---------------------------------------------------------------- 조정 (adjust)

class AdjustPanel extends StatefulWidget {
  const AdjustPanel(this.c, {super.key});
  final EditorController c;
  @override
  State<AdjustPanel> createState() => _AdjustPanelState();
}

class _AdjustPanelState extends State<AdjustPanel> {
  static int _tab = 0; // remembered while the app runs
  static const tabs = ['빛', '색', '질감', '필름', '프로'];

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final body = switch (_tab) {
      0 => _light(c),
      1 => _color(c),
      2 => _texture(c),
      3 => _film(c),
      _ => [_ProTools(c)],
    };
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: PillTabs(labels: tabs, index: _tab, onChanged: (i) => setState(() => _tab = i)),
      ),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: ListView(
            key: ValueKey(_tab),
            padding: const EdgeInsets.only(bottom: 24),
            children: body,
          ),
        ),
      ),
    ]);
  }

  List<Widget> _light(EditorController c) => [
        HistogramView(c.histogram, height: 64),
        recipeSlider(c, '노출', 'exposure', min: -5, max: 5, display: evDisplay),
        recipeSlider(c, '대비', 'contrast'),
        recipeSlider(c, '밝은 부분', 'highlights'),
        recipeSlider(c, '어두운 부분', 'shadows'),
        recipeSlider(c, '흰색 계열', 'whites'),
        recipeSlider(c, '검정 계열', 'blacks'),
        recipeSlider(c, '페이드 (매트)', 'fade', min: 0, max: 1),
        const HintText('줄을 더블클릭하면 0으로 돌아가요.'),
      ];

  List<Widget> _color(EditorController c) => [
        recipeSlider(c, '색온도', 'temperature', track: tempGradient),
        recipeSlider(c, '색조', 'tint', track: tintGradient),
        recipeSlider(c, '생동감', 'vibrance'),
        recipeSlider(c, '채도', 'saturation'),
        recipeSlider(c, '피부톤 보호', 'skin_protect', min: 0, max: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
          child: Row(children: [
            const Expanded(child: Text('흑백으로', style: TextStyle(fontSize: 13, color: AppColors.textDim))),
            Switch(
              value: getBool(c.recipe, 'monochrome'),
              onChanged: (v) => c.edit((r) => r['monochrome'] = v, commit: true),
            ),
          ]),
        ),
        const HintText('더 세밀한 색 조정(색상별 HSL, 컬러 그레이딩)은 프로 탭에 있어요.'),
      ];

  List<Widget> _texture(EditorController c) => [
        recipeSlider(c, '텍스처', 'texture'),
        recipeSlider(c, '선명도 (Clarity)', 'clarity'),
        recipeSlider(c, '안개 제거', 'dehaze'),
        recipeSlider(c, '샤프닝', 'sharpen', min: 0, max: 1),
        recipeSlider(c, '노이즈 감소', 'noise_reduction', min: 0, max: 1),
        recipeSlider(c, '색 노이즈 감소', 'color_noise_reduction', min: 0, max: 1),
      ];

  List<Widget> _film(EditorController c) => [
        recipeSlider(c, '비네팅', 'vignette'),
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
      ];
}

/// Advanced tools, folded away so the default view stays simple.
class _ProTools extends StatelessWidget {
  const _ProTools(this.c);
  final EditorController c;
  @override
  Widget build(BuildContext context) => Column(children: [
        _Fold(title: '톤 커브', icon: Icons.show_chart_rounded, initiallyOpen: true, child: _CurveTool(c)),
        _Fold(title: '컬러 그레이딩', icon: Icons.contrast_rounded, child: _GradingTool(c)),
        _Fold(title: '색상별 조정 (HSL)', icon: Icons.palette_outlined, child: _HslTool(c)),
        _Fold(
          title: '캘리브레이션',
          icon: Icons.science_outlined,
          child: Column(children: [
            recipeSlider(c, '빨강 원색 색조', 'cal_red_hue'),
            recipeSlider(c, '빨강 원색 채도', 'cal_red_sat'),
            recipeSlider(c, '초록 원색 색조', 'cal_green_hue'),
            recipeSlider(c, '초록 원색 채도', 'cal_green_sat'),
            recipeSlider(c, '파랑 원색 색조', 'cal_blue_hue'),
            recipeSlider(c, '파랑 원색 채도', 'cal_blue_sat'),
          ]),
        ),
      ]);
}

class _Fold extends StatefulWidget {
  const _Fold({required this.title, required this.icon, required this.child, this.initiallyOpen = false});
  final String title;
  final IconData icon;
  final Widget child;
  final bool initiallyOpen;
  @override
  State<_Fold> createState() => _FoldState();
}

class _FoldState extends State<_Fold> {
  late bool open = widget.initiallyOpen;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        decoration: BoxDecoration(color: AppColors.surface2.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(18)),
        child: Column(children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => setState(() => open = !open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
              child: Row(children: [
                Icon(widget.icon, size: 17, color: open ? AppColors.accent : AppColors.textDim),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.expand_more_rounded, color: AppColors.textDim),
                ),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: open ? Padding(padding: const EdgeInsets.only(bottom: 12), child: widget.child) : const SizedBox(width: double.infinity),
          ),
        ]),
      );
}

class _HslTool extends StatefulWidget {
  const _HslTool(this.c);
  final EditorController c;
  @override
  State<_HslTool> createState() => _HslToolState();
}

class _HslToolState extends State<_HslTool> {
  int band = 0;
  static const bandColors = [
    Color(0xFFEF5350), Color(0xFFFF9F43), Color(0xFFFFD84D), Color(0xFF4CC46A),
    Color(0xFF26C6DA), Color(0xFF4D8DFF), Color(0xFFA16BFF), Color(0xFFF062A8),
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (var i = 0; i < 8; i++)
            Tooltip(
              message: hslBandNames[i],
              child: GestureDetector(
                onTap: () => setState(() => band = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 28,
                  height: 28,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: band == i ? Colors.white : Colors.transparent, width: 2),
                  ),
                  child: DecoratedBox(decoration: BoxDecoration(color: bandColors[i], shape: BoxShape.circle)),
                ),
              ),
            ),
        ]),
      ),
      recipeSlider(c, '${hslBandNames[band]} · 색상', 'hsl.$band.hue', min: -45, max: 45, display: (v) => v.round().toString()),
      recipeSlider(c, '${hslBandNames[band]} · 채도', 'hsl.$band.sat'),
      recipeSlider(c, '${hslBandNames[band]} · 밝기', 'hsl.$band.lum'),
    ]);
  }
}

class _GradingTool extends StatelessWidget {
  const _GradingTool(this.c);
  final EditorController c;
  @override
  Widget build(BuildContext context) {
    Widget zone(String title, String key) {
      final hue = getNum(c.recipe, '$key.hue');
      final sat = getNum(c.recipe, '$key.sat');
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Row(children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: HSVColor.fromAHSV(1, hue.clamp(0, 360), sat.clamp(0, 1) * 0.9, 0.95).toColor(),
                border: Border.all(color: AppColors.line),
              ),
            ),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.text)),
          ]),
        ),
        recipeSlider(c, '색상', '$key.hue', min: 0, max: 360, display: (v) => '${v.round()}°', track: hueGradient),
        recipeSlider(c, '강도', '$key.sat', min: 0, max: 1),
      ]);
    }

    return Column(children: [
      zone('어두운 부분', 'grade_shadows'),
      zone('중간 톤', 'grade_midtones'),
      zone('밝은 부분', 'grade_highlights'),
      recipeSlider(c, '균형 (어둠 ↔ 밝음)', 'grade_balance'),
    ]);
  }
}

class _CurveTool extends StatefulWidget {
  const _CurveTool(this.c);
  final EditorController c;
  @override
  State<_CurveTool> createState() => _CurveToolState();
}

class _CurveToolState extends State<_CurveTool> {
  int ch = 0;
  static const keys = ['curve', 'curve_r', 'curve_g', 'curve_b'];
  static const colors = [Colors.white, Color(0xFFFF6B6B), Color(0xFF5EE38A), Color(0xFF5BA8FF)];

  List<List<double>> _points() {
    final v = widget.c.recipe[keys[ch]];
    if (v is List) return [for (final p in v) [(p[0] as num).toDouble(), (p[1] as num).toDouble()]];
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final key = keys[ch];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: [
        Row(children: [
          Expanded(child: PillTabs(labels: const ['전체', 'R', 'G', 'B'], index: ch, onChanged: (i) => setState(() => ch = i))),
          IconButton(
            tooltip: '이 커브 초기화',
            onPressed: () => c.edit((r) => r[key] = <List<double>>[], commit: true),
            icon: const Icon(Icons.restart_alt_rounded, size: 20),
          ),
        ]),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.all(10),
            child: CurveEditor(
              points: _points(),
              color: colors[ch],
              onChanged: (p) => c.edit((r) => r[key] = p),
              onChangeEnd: (p) => c.edit((r) => r[key] = p, commit: true),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('클릭: 점 추가 · 드래그: 이동 · 더블클릭: 점 삭제',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.textFaint, fontSize: 11.5)),
        ),
      ]),
    );
  }
}
