// Runs against the Rust engine built for the host:
//   cargo build --release (in ../engine), then
//   LD_LIBRARY_PATH=../engine/target/release flutter test   (Linux)
// On Windows, put photo_grade_engine.dll on PATH.

import 'dart:io';

import 'package:acg/ai/ai_service.dart';
import 'package:acg/engine/engine.dart';
import 'package:acg/engine/recipe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layering adds scalars, keeps geometry, takes style grading', () {
    final base = {'name': 'b', 'exposure': 0.5, 'temperature': 0.1, 'crop': [0.1, 0.1, 0.5, 0.5]};
    final style = {
      'name': '필름',
      'category': '필름',
      'exposure': -0.2,
      'temperature': 0.1,
      'grain': 0.3,
      'grain_size': 0.6,
      'grade_shadows': {'hue': 200, 'sat': 0.3},
    };
    final out = layerRecipe(base, style);
    expect(getVal(out, 'exposure'), closeTo(0.3, 1e-9));
    expect(getVal(out, 'temperature'), closeTo(0.2, 1e-9));
    expect(out['crop'], [0.1, 0.1, 0.5, 0.5]);
    expect(out['name'], '필름');
    expect(getVal(out, 'grain_size'), 0.6);
    expect(getNum(out, 'grade_shadows.sat'), 0.3);
    // Blending: 0 = base, 1 = layered, 1.5 = exaggerated.
    expect(getVal(blendRecipe(base, out, 0), 'exposure'), closeTo(0.5, 1e-9));
    expect(getVal(blendRecipe(base, out, 1.5), 'exposure'), closeTo(0.2, 1e-9));
    expect(getNum(blendRecipe(base, out, 0.5), 'grade_shadows.sat'), closeTo(0.15, 1e-9));
  });

  test('AI plan is validated and builds recipes', () {
    final plan = AiPlan.fromJson({
      'analysis': '테스트',
      'variations': [
        {'name': 'A', 'template': '필름', 'strength': 9, 'adjust': {'contrast': 3, 'bogus': 1}},
        {'name': 'B', 'template': '없는 템플릿', 'adjust': {'exposure': -0.3}},
      ],
    }, {'필름'});
    expect(plan.variations.length, 2);
    expect(plan.variations[0].strength, 1.5);
    expect(plan.variations[0].adjust, {'contrast': 0.5});
    expect(plan.variations[1].template, isNull);
    final r = plan.variations[1].toRecipe({'exposure': 0.4}, null);
    expect(getVal(r, 'exposure'), closeTo(0.1, 1e-9));
    expect(r['name'], 'B');
  });

  test('merge clamps AI values and ignores unknown keys', () {
    final out = mergeAiRecipe(emptyRecipe(), {
      'exposure': 99,
      'contrast': 0.3,
      'evil': 'x',
      'hsl': [
        {'hue': 100, 'sat': 0.2, 'lum': 0}
      ],
      'curve': [[1, 1], [0, 0.1]],
    });
    expect(out['exposure'], 5.0);
    expect(out['contrast'], 0.3);
    expect(out.containsKey('evil'), isFalse);
    expect((out['hsl'] as List).length, 8);
    expect(out['hsl'][0]['hue'], 45.0);
    expect(out['curve'][0], [0.0, 0.1]);
  });

  final sample = Platform.environment['ACG_SAMPLE'];
  test('engine renders and exports', () async {
    final presets = enginePresets();
    expect(presets.length, greaterThanOrEqualTo(10));
    final s = await EngineSession.open(sample!, previewSize: 400);
    final f = await s.renderPreview(presets.first);
    expect(f.rgba.length, f.width * f.height * 4);
    final auto = await s.autoCandidates();
    expect((auto['candidates'] as List).length, greaterThan(3));
    final matched = await s.matchReference(emptyRecipe(), sample, 0.8);
    expect(matched['lut'], isNotNull);
    final out = '${Directory.systemTemp.path}/acg_test_out.tif';
    await s.export(matched, out);
    expect(File(out).lengthSync(), greaterThan(1000));
    final b64 = await EngineSession.thumbnailOf(sample);
    expect(b64.length, greaterThan(1000));
    await s.close();
  }, skip: sample == null ? 'set ACG_SAMPLE to an image path' : null);
}
