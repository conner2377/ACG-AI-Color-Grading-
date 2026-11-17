// Runs against the Rust engine built for the host:
//   cargo build --release (in ../engine), then
//   LD_LIBRARY_PATH=../engine/target/release flutter test   (Linux)
// On Windows, put photo_grade_engine.dll on PATH.

import 'dart:io';

import 'package:acg/engine/engine.dart';
import 'package:acg/engine/recipe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
