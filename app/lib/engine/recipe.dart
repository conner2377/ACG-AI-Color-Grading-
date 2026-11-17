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
  'texture': (-1, 1),
  'noise_reduction': (0, 1),
  'color_noise_reduction': (0, 1),
  'halation': (0, 1),
  'bloom': (0, 1),
  'grain_size': (0, 1),
  'skin_protect': (0, 1),
  'grade_balance': (-1, 1),
  'cal_red_hue': (-1, 1),
  'cal_red_sat': (-1, 1),
  'cal_green_hue': (-1, 1),
  'cal_green_sat': (-1, 1),
  'cal_blue_hue': (-1, 1),
  'cal_blue_sat': (-1, 1),
};

/// Engine defaults for keys whose neutral value is not 0.
const recipeDefaults = <String, double>{'grain_size': 0.3, 'skin_protect': 0.6, 'lut_strength': 1.0};

double getVal(Map<String, dynamic> r, String key) =>
    r[key] is num ? (r[key] as num).toDouble() : (recipeDefaults[key] ?? 0.0);

/// Keys that add up when a style is layered on a base correction (mirrors Recipe::layered).
const _nonAdditive = {'grain_size', 'skin_protect'};

const gradeKeys = ['grade_shadows', 'grade_midtones', 'grade_highlights'];
const curveKeys = ['curve', 'curve_r', 'curve_g', 'curve_b'];

/// Layer a template on top of a base correction: scalar adjustments add, grading,
/// curves, mixer and LUT come from the style when it sets them. Geometry stays.
Map<String, dynamic> layerRecipe(Map<String, dynamic> base, Map<String, dynamic> style) {
  final out = cloneRecipe(base);
  for (final k in ['name', 'category', 'description']) {
    if (style[k] != null) out[k] = style[k];
  }
  for (final e in recipeRanges.entries) {
    final k = e.key;
    if (_nonAdditive.contains(k)) continue;
    final v = getVal(base, k) + getVal(style, k);
    out[k] = v.clamp(k == 'exposure' ? -5.0 : e.value.$1, k == 'exposure' ? 5.0 : e.value.$2);
  }
  out['skin_protect'] = getVal(style, 'skin_protect');
  if (getVal(style, 'grain') > 0) out['grain_size'] = getVal(style, 'grain_size');
  for (var i = 0; i < 8; i++) {
    for (final f in ['hue', 'sat', 'lum']) {
      setNum(out, 'hsl.$i.$f', getNum(base, 'hsl.$i.$f') + getNum(style, 'hsl.$i.$f'));
    }
  }
  for (final g in gradeKeys) {
    if (getNum(style, '$g.sat') > 0) out[g] = cloneRecipe({'v': style[g]})['v'];
  }
  for (final k in curveKeys) {
    if (style[k] is List && (style[k] as List).isNotEmpty) out[k] = cloneRecipe({'v': style[k]})['v'];
  }
  if (style['channel_mixer'] != null) out['channel_mixer'] = cloneRecipe({'v': style['channel_mixer']})['v'];
  if (style['monochrome'] == true) out['monochrome'] = true;
  if (style['lut'] != null) {
    out['lut'] = style['lut'];
    out['lut_strength'] = getVal(style, 'lut_strength');
  }
  return out;
}

/// Blend from [from] toward [to] by [a] (0 = from, 1 = to, up to 1.5 = exaggerated).
/// Scalars, HSL, grading strength, curves and LUT strength all interpolate.
Map<String, dynamic> blendRecipe(Map<String, dynamic> from, Map<String, dynamic> to, double a) {
  final out = cloneRecipe(a >= 0.5 ? to : from);
  for (final e in recipeRanges.entries) {
    final f = getVal(from, e.key), t = getVal(to, e.key);
    out[e.key] = (f + (t - f) * a).clamp(e.key == 'exposure' ? -5.0 : e.value.$1, e.key == 'exposure' ? 5.0 : e.value.$2);
  }
  for (var i = 0; i < 8; i++) {
    for (final f in ['hue', 'sat', 'lum']) {
      final x = getNum(from, 'hsl.$i.$f'), y = getNum(to, 'hsl.$i.$f');
      setNum(out, 'hsl.$i.$f', x + (y - x) * a);
    }
  }
  for (final g in gradeKeys) {
    final fs = getNum(from, '$g.sat'), ts = getNum(to, '$g.sat');
    if (ts > 0 || fs > 0) {
      final hue = ts > 0 ? getNum(to, '$g.hue') : getNum(from, '$g.hue');
      out[g] = {'hue': hue, 'sat': (fs + (ts - fs) * a).clamp(0.0, 1.5)};
    }
  }
  for (final k in curveKeys) {
    final t = (to[k] is List) ? (to[k] as List) : const [];
    if (t.isNotEmpty) {
      // Blend the curve toward identity (y = x) by the amount.
      out[k] = [
        for (final p in t)
          [getNumList(p, 0), (getNumList(p, 0) + (getNumList(p, 1) - getNumList(p, 0)) * a).clamp(0.0, 1.0)]
      ];
    }
  }
  if (to['lut'] != null) {
    out['lut'] = to['lut'];
    out['lut_strength'] = (getVal(to, 'lut_strength') * a).clamp(0.0, 1.5);
  }
  if (to['channel_mixer'] != null && from['channel_mixer'] == null && to['monochrome'] != true) {
    // Fade a color mixer in from identity.
    final m = to['channel_mixer'] as List;
    out['channel_mixer'] = [
      for (var i = 0; i < 3; i++)
        [for (var j = 0; j < 3; j++) (i == j ? 1.0 : 0.0) + ((m[i] as List)[j] as num).toDouble() * a - (i == j ? a : 0.0)]
    ];
  }
  return out;
}

double getNumList(dynamic p, int i) => p is List && p.length > i && p[i] is num ? (p[i] as num).toDouble() : 0.0;

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
