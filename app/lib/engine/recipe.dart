// Recipes are kept as JSON maps so they round-trip exactly with the Rust engine
// (including LUT data). These helpers give typed access for the UI.

import 'dart:convert';

const hslBandNames = ['빨강', '주황', '노랑', '초록', '아쿠아', '파랑', '보라', '마젠타'];

Map<String, dynamic> emptyRecipe() => {'name': ''};

Map<String, dynamic> cloneRecipe(Map<String, dynamic> r) => jsonDecode(jsonEncode(r)) as Map<String, dynamic>;

double getNum(Map<String, dynamic> r, String path) {
  dynamic v = r;
  for (final part in path.split('.')) {
    if (v is Map) {
      v = v[part];
    } else if (v is List) {
      final i = int.parse(part);
      v = i < v.length ? v[i] : null;
    } else {
      return 0;
    }
  }
  return v is num ? v.toDouble() : 0;
}

void setNum(Map<String, dynamic> r, String path, double value) {
  final parts = path.split('.');
  dynamic cur = r;
  for (var i = 0; i < parts.length - 1; i++) {
    final p = parts[i];
    final nextIsIndex = int.tryParse(parts[i + 1]) != null;
    if (cur is Map) {
      cur[p] ??= nextIsIndex ? List.generate(8, (_) => <String, dynamic>{'hue': 0.0, 'sat': 0.0, 'lum': 0.0}) : <String, dynamic>{};
      cur = cur[p];
    } else if (cur is List) {
      cur = cur[int.parse(p)];
    }
  }
  final last = parts.last;
  if (cur is Map) cur[last] = value;
}

bool getBool(Map<String, dynamic> r, String key) => r[key] == true;

/// Scalar keys the AI is allowed to set, with valid ranges. Shared with the AI prompt.
const recipeRanges = <String, (double, double)>{
  'exposure': (-5, 5),
  'contrast': (-1, 1),
  'highlights': (-1, 1),
  'shadows': (-1, 1),
  'whites': (-1, 1),
  'blacks': (-1, 1),
  'temperature': (-1, 1),
  'tint': (-1, 1),
  'vibrance': (-1, 1),
  'saturation': (-1, 1),
  'clarity': (-1, 1),
  'dehaze': (-1, 1),
  'sharpen': (0, 1),
  'vignette': (-1, 1),
  'grain': (0, 1),
  'fade': (0, 1),
};

double _clampNum(dynamic v, double lo, double hi) => (v is num ? v.toDouble() : 0.0).clamp(lo, hi);

/// Validate and merge an AI-proposed recipe onto [base]. Unknown keys are ignored and
/// all values are clamped, so a model can never produce an invalid edit.
Map<String, dynamic> mergeAiRecipe(Map<String, dynamic> base, Map<String, dynamic> ai) {
  final out = cloneRecipe(base);
  if (ai['name'] is String) out['name'] = ai['name'];
  for (final e in recipeRanges.entries) {
    if (ai.containsKey(e.key)) out[e.key] = _clampNum(ai[e.key], e.value.$1, e.value.$2);
  }
  if (ai['hsl'] is List) {
    final list = ai['hsl'] as List;
    out['hsl'] = List.generate(8, (i) {
      final b = i < list.length && list[i] is Map ? list[i] as Map : const {};
      return {
        'hue': _clampNum(b['hue'], -45, 45),
        'sat': _clampNum(b['sat'], -1, 1),
        'lum': _clampNum(b['lum'], -1, 1),
      };
    });
  }
  for (final k in ['grade_shadows', 'grade_midtones', 'grade_highlights']) {
    if (ai[k] is Map) {
      final m = ai[k] as Map;
      out[k] = {'hue': _clampNum(m['hue'], 0, 360), 'sat': _clampNum(m['sat'], 0, 1)};
    }
  }
  for (final k in ['curve', 'curve_r', 'curve_g', 'curve_b']) {
    if (ai[k] is List) {
      final pts = <List<double>>[];
      for (final p in ai[k] as List) {
        if (p is List && p.length == 2) pts.add([_clampNum(p[0], 0, 1), _clampNum(p[1], 0, 1)]);
      }
      pts.sort((a, b) => a[0].compareTo(b[0]));
      out[k] = pts.length >= 2 ? pts : <List<double>>[];
    }
  }
  if (ai['channel_mixer'] is List) {
    final m = ai['channel_mixer'] as List;
    if (m.length == 3 && m.every((r) => r is List && r.length == 3)) {
      out['channel_mixer'] = [for (final r in m) [for (final v in r as List) _clampNum(v, -2, 2)]];
    }
  } else if (ai.containsKey('channel_mixer') && ai['channel_mixer'] == null) {
    out['channel_mixer'] = null;
  }
  if (ai['monochrome'] is bool) out['monochrome'] = ai['monochrome'];
  return out;
}
