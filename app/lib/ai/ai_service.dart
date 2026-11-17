// AI color grading: the model reads the photo (small JPEG), its statistics and the
// user's request, analyzes it like a colorist and answers with edit VALUES (slider deltas,
// HSL, color wheels, curve) for 3 variations; a second pass lets it look at its own result
// and correct it. The histogram baseline is computed by the engine. The engine then applies
// them at full resolution, so the photo is never regenerated and never loses quality.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/recipe.dart';

enum AiProvider { gemini, claude, openai }

extension AiProviderInfo on AiProvider {
  String get label => switch (this) {
        AiProvider.gemini => 'Gemini',
        AiProvider.claude => 'Claude',
        AiProvider.openai => 'ChatGPT',
      };
  String get defaultModel => switch (this) {
        AiProvider.gemini => 'gemini-2.5-flash',
        AiProvider.claude => 'claude-opus-5-5',
        AiProvider.openai => 'gpt-5-mini',
      };
  String get keyHelpUrl => switch (this) {
        AiProvider.gemini => 'https://aistudio.google.com/apikey',
        AiProvider.claude => 'https://console.anthropic.com/settings/keys',
        AiProvider.openai => 'https://platform.openai.com/api-keys',
      };
}

class AiSettings {
  AiSettings({required this.provider, required this.model, required this.apiKey});
  AiProvider provider;
  String model;
  String apiKey;

  static const _secure = FlutterSecureStorage();

  static Future<AiSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final p = AiProvider.values.firstWhere((e) => e.name == prefs.getString('ai.provider'),
        orElse: () => AiProvider.gemini);
    final model = prefs.getString('ai.model.${p.name}') ?? p.defaultModel;
    final key = await _secure.read(key: 'ai.key.${p.name}') ?? '';
    return AiSettings(provider: p, model: model, apiKey: key);
  }

  static Future<AiSettings> loadFor(AiProvider p) async {
    final prefs = await SharedPreferences.getInstance();
    return AiSettings(
      provider: p,
      model: prefs.getString('ai.model.${p.name}') ?? p.defaultModel,
      apiKey: await _secure.read(key: 'ai.key.${p.name}') ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai.provider', provider.name);
    await prefs.setString('ai.model.${provider.name}', model.trim().isEmpty ? provider.defaultModel : model.trim());
    await _secure.write(key: 'ai.key.${provider.name}', value: apiKey.trim());
  }
}

class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _systemPrompt = '''
You are a senior colorist operating a non-destructive photo editor. You NEVER generate,
redraw or retouch pixels: you only set slider values, curves and color wheels, and the
editor renders them at full resolution, so the photo keeps its original quality.

You do NOT pick presets. You analyze THIS photo and decide the edit yourself, the way a
human retoucher works in Lightroom, in this order:
1. Light: exposure, contrast, highlights, shadows, whites, blacks (fix what is wrong first:
   underexposed subject, blown sky, flat haze, crushed shadows).
2. Color: white balance (temperature, tint), vibrance, saturation, and per-color HSL
   (e.g. calmer greens, bluer sky, natural skin in orange/red).
3. Mood: tone curve, color grading wheels (shadows/midtones/highlights), fade, clarity,
   texture, dehaze, grain, halation, bloom, vignette.
The editor has already applied a neutral physical baseline from the histogram (exposure,
white balance, black/white points). The FIRST image is the photo with that baseline.
Your "adjust" values are DELTAS on top of it.

Reply with ONE JSON object and nothing else:
{
  "analysis": "한국어 2문장: 사진에서 본 것(장면·빛·색·문제점)과 보정 방향",
  "variations": [
    {
      "name": "짧은 한국어 이름",
      "reason": "한국어 한 줄: 무엇을 왜 바꿨는지",
      "adjust": { "exposure": 0.2, "shadows": 0.25, "temperature": 0.08 },
      "hsl": [ {"hue":0,"sat":0,"lum":0}, ... 8 bands ],
      "grade_shadows": {"hue": 210, "sat": 0.15},
      "grade_midtones": {"hue": 0, "sat": 0},
      "grade_highlights": {"hue": 45, "sat": 0.1},
      "curve": [[0,0.03],[0.25,0.22],[0.75,0.8],[1,0.98]],
      "monochrome": false
    }
  ]
}

Return EXACTLY 3 variations of the same direction: #1 your best edit, #2 a bolder take,
#3 a subtler, more natural take. All keys except name/reason/adjust are optional; omit
what you don't change.

Limits:
- adjust (deltas): exposure ±1.5; contrast, highlights, shadows, whites, blacks, temperature,
  tint, vibrance, saturation, clarity, texture, dehaze, vignette ±0.8;
  fade, grain, grain_size, halation, bloom, sharpen, noise_reduction 0..0.8.
- hsl: 8 bands in order [red, orange, yellow, green, aqua, blue, purple, magenta],
  hue -45..45 degrees, sat -1..1, lum -1..1. Absolute values.
- grade_*: hue 0..360, sat 0..1 (0.05-0.25 is already visible). Absolute values.
- curve: 3-6 points [x,y] in 0..1, gentle; it multiplies with contrast, so don't double up.

Taste:
- Correct problems first, then style. A harmonious, believable photo beats a filter.
- Keep skin natural (orange band hue within ±8, sat within ±0.2) unless asked otherwise;
  the editor also protects skin automatically.
- Watch the statistics: don't push highlights that are already near clipping, and don't
  crush shadows that are already dark.
- If the user asks for a mood (film, cinematic, infrared, flash, warm, moody), commit to it
  with these tools; when they ask for nothing specific, make the photo look its best.
''';

const _refinePrompt = '''
Look again. The FIRST image is the photo before editing (baseline), the SECOND is the
current edit. If the user gives a FOLLOW-UP request, change the current edit to satisfy it
while keeping everything else they already liked. Without one, compare against the original
request and fix what is still off (too strong, too weak, color cast, clipped highlights,
muddy shadows, unnatural skin). Return the same JSON
format with EXACTLY 1 variation whose "adjust" values are DELTAS on top of the SECOND image,
and absolute hsl/grade/curve values only if you change them. If it already looks right, return
small or empty adjust. Put what you changed in "reason".
''';

/// Very small HTML-to-text for guide links.
String _htmlToText(String html) {
  var s = html.replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<br\s*/?>|</p>|</li>|</h\d>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  s = s.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n');
  return s.trim();
}

/// Fetch a color-grading guide page and return readable text (truncated to a safe size
/// for the prompt; the user is told the page was long).
Future<String> fetchGuideText(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw AiException('올바른 링크(http/https)가 아닙니다.');
  }
  final res = await http.get(uri).timeout(const Duration(seconds: 20));
  if (res.statusCode >= 400) throw AiException('링크를 불러오지 못했습니다 (${res.statusCode}).');
  final text = _htmlToText(utf8.decode(res.bodyBytes, allowMalformed: true));
  const max = 30000;
  return text.length > max ? text.substring(0, max) : text;
}

class AiService {
  AiService(this.settings);
  final AiSettings settings;

  /// Ask the model to analyze the photo and decide the edit itself: 3 variations of
  /// slider deltas + optional HSL / grading / curve values.
  Future<AiPlan> plan({
    required Map<String, dynamic> current,
    required String imageB64,
    required Map<String, dynamic> stats,
    String request = '',
    String? guideText,
    String? referenceImageB64,
  }) async {
    _checkKey();
    final currentForPrompt = cloneRecipe(current)..remove('lut');
    final buf = StringBuffer()
      ..writeln('Photo statistics (original): ${jsonEncode(stats)}')
      ..writeln('Baseline already applied (your adjust values add to these): ${jsonEncode(currentForPrompt)}');
    if (guideText != null && guideText.isNotEmpty) {
      buf
        ..writeln('A color-grading guide the user wants applied (translate its steps into these controls):')
        ..writeln('<guide>')
        ..writeln(guideText)
        ..writeln('</guide>');
    }
    if (referenceImageB64 != null) {
      buf.writeln('The SECOND image is a reference photo whose color style the user wants. '
          'Reproduce its palette, contrast and mood with the controls, and set "reference_match" '
          '(0.2-0.6) on each variation so the engine also blends an exact color match.');
    }
    buf.writeln(request.trim().isEmpty
        ? 'User request: (none) 사진을 분석해서 가장 좋아 보이도록 전문가처럼 보정해 주세요.'
        : 'User request: $request');
    final text = await _ask(_systemPrompt, buf.toString(), [imageB64, ?referenceImageB64]);
    return AiPlan.fromJson(_extractJson(text));
  }

  /// Second pass (RetouchLLM-style feedback loop): the model sees before/after and corrects.
  Future<AiPlan> refine({
    required String beforeB64,
    required String afterB64,
    required Map<String, dynamic> currentRecipe,
    String request = '',
    String followUp = '',
  }) async {
    _checkKey();
    final r = cloneRecipe(currentRecipe)..remove('lut');
    final prompt = 'Current edit values: ${jsonEncode(r)}\n'
        'Original request: ${request.trim().isEmpty ? '(none) 가장 좋아 보이게' : request}\n'
        '${followUp.trim().isEmpty ? 'No follow-up: just review and polish.' : 'FOLLOW-UP request on the current edit: $followUp'}';
    final text = await _ask('$_systemPrompt\n$_refinePrompt', prompt, [beforeB64, afterB64]);
    return AiPlan.fromJson(_extractJson(text), max: 1);
  }

  void _checkKey() {
    if (settings.apiKey.trim().isEmpty) {
      throw AiException('${settings.provider.label} API 키를 설정에서 입력해 주세요.');
    }
  }

  Future<String> _ask(String system, String prompt, List<String> images) => switch (settings.provider) {
        AiProvider.gemini => _gemini(system, prompt, images),
        AiProvider.claude => _claude(system, prompt, images),
        AiProvider.openai => _openai(system, prompt, images),
      };

  Map<String, dynamic> _extractJson(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) throw AiException('AI 응답에서 보정값을 찾지 못했습니다.');
    try {
      return jsonDecode(text.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (_) {
      throw AiException('AI 응답 형식이 올바르지 않습니다. 다시 시도해 주세요.');
    }
  }

  Never _httpError(http.Response r) {
    String msg = r.body;
    try {
      final j = jsonDecode(r.body);
      msg = (j['error']?['message'] ?? j['error'] ?? r.body).toString();
    } catch (_) {}
    if (msg.length > 300) msg = '${msg.substring(0, 300)}…';
    throw AiException('${settings.provider.label} 오류 (${r.statusCode}): $msg');
  }

  Future<String> _gemini(String system, String prompt, List<String> images) async {
    final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${settings.model}:generateContent');
    final body = {
      'systemInstruction': {
        'parts': [
          {'text': system}
        ]
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            for (final b64 in images) {'inline_data': {'mime_type': 'image/jpeg', 'data': b64}},
            {'text': prompt},
          ]
        }
      ],
      'generationConfig': {'responseMimeType': 'application/json', 'temperature': 0.7},
    };
    final r = await http
        .post(uri, headers: {'content-type': 'application/json', 'x-goog-api-key': settings.apiKey}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) _httpError(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final parts = (j['candidates'] as List?)?.firstOrNull?['content']?['parts'] as List?;
    if (parts == null) throw AiException('Gemini가 응답하지 않았습니다: ${j['promptFeedback'] ?? ''}');
    return parts.map((p) => p['text'] ?? '').join();
  }

  Future<String> _claude(String system, String prompt, List<String> images) async {
    final body = {
      'model': settings.model,
      'max_tokens': 16000,
      'output_config': {'effort': 'low'},
      'fallbacks': 'default',
      'system': system,
      'messages': [
        {
          'role': 'user',
          'content': [
            for (final b64 in images)
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': b64}
              },
            {'type': 'text', 'text': prompt},
          ]
        }
      ],
    };
    final r = await http
        .post(Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'content-type': 'application/json',
              'x-api-key': settings.apiKey,
              'anthropic-version': '2026-10-21',
              'anthropic-beta': 'server-side-fallback-2026-07-01',
            },
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 180));
    if (r.statusCode != 200) _httpError(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j['stop_reason'] == 'refusal') throw AiException('Claude가 이 요청을 처리하지 않았습니다.');
    return (j['content'] as List).where((b) => b['type'] == 'text').map((b) => b['text']).join();
  }

  Future<String> _openai(String system, String prompt, List<String> images) async {
    final body = {
      'model': settings.model,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': system},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            for (final b64 in images)
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$b64'}
              },
          ]
        }
      ],
    };
    final r = await http
        .post(Uri.parse('https://api.openai.com/v1/chat/completions'),
            headers: {'content-type': 'application/json', 'authorization': 'Bearer ${settings.apiKey}'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 180));
    if (r.statusCode != 200) _httpError(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return (j['choices'] as List).first['message']['content'] as String;
  }
}

/// Bounded deltas the AI may add on top of the baseline.
final aiAdjustRanges = <String, (double, double)>{
  'exposure': (-1.5, 1.5),
  for (final k in ['contrast', 'highlights', 'shadows', 'whites', 'blacks', 'temperature', 'tint', 'vibrance',
      'saturation', 'clarity', 'texture', 'dehaze', 'vignette'])
    k: (-0.8, 0.8),
  for (final k in ['fade', 'grain', 'grain_size', 'halation', 'bloom', 'sharpen', 'noise_reduction']) k: (-0.8, 0.8),
};

const _absoluteKeys = ['hsl', 'grade_shadows', 'grade_midtones', 'grade_highlights', 'curve', 'curve_r', 'curve_g', 'curve_b', 'monochrome'];

class AiVariation {
  AiVariation({
    required this.name,
    this.reason = '',
    this.adjust = const {},
    this.absolute = const {},
    this.referenceMatch = 0,
  });
  final String name;
  final String reason;
  final Map<String, double> adjust;
  final Map<String, dynamic> absolute;
  final double referenceMatch;

  /// base + deltas (clamped to the recipe ranges) + absolute HSL / grading / curve values.
  Map<String, dynamic> toRecipe(Map<String, dynamic> base) {
    var r = cloneRecipe(base);
    for (final e in adjust.entries) {
      final range = recipeRanges[e.key]!;
      r[e.key] = (getVal(r, e.key) + e.value).clamp(range.$1, range.$2);
    }
    if (absolute.isNotEmpty) r = mergeAiRecipe(r, absolute);
    r['name'] = name;
    r['category'] = 'AI';
    r['description'] = reason;
    return r;
  }
}

class AiPlan {
  AiPlan(this.analysis, this.variations);
  final String analysis;
  final List<AiVariation> variations;

  factory AiPlan.fromJson(Map<String, dynamic> j, {int max = 4}) {
    double n(dynamic v, double d) => v is num ? v.toDouble() : d;
    final vars = <AiVariation>[];
    final list = j['variations'] is List ? j['variations'] as List : [j];
    for (final v in list.whereType<Map>()) {
      final adjust = <String, double>{};
      if (v['adjust'] is Map) {
        (v['adjust'] as Map).forEach((k, val) {
          final lim = aiAdjustRanges[k];
          if (lim != null && val is num) adjust[k as String] = val.toDouble().clamp(lim.$1, lim.$2);
        });
      }
      final absolute = <String, dynamic>{
        for (final k in _absoluteKeys)
          if (v[k] != null) k: v[k],
      };
      vars.add(AiVariation(
        name: v['name'] is String && (v['name'] as String).isNotEmpty ? v['name'] as String : 'AI 보정 ${vars.length + 1}',
        reason: v['reason'] is String ? v['reason'] as String : '',
        adjust: adjust,
        absolute: absolute,
        referenceMatch: n(v['reference_match'], 0).clamp(0.0, 1.0),
      ));
      if (vars.length == max) break;
    }
    if (vars.isEmpty) throw AiException('AI가 보정안을 만들지 못했습니다. 다시 시도해 주세요.');
    return AiPlan(j['analysis'] is String ? j['analysis'] as String : '', vars);
  }
}
