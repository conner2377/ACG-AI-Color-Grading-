// AI color grading: the model reads the photo (small JPEG), its statistics and the
// user's request, and answers with a PLAN: which vetted template, how strong, and small
// bounded adjustments (4 variations). The histogram baseline is computed by the engine,
// not the model. The engine then applies
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
You are a senior colorist directing a non-destructive photo editor (like Lightroom presets).
You NEVER generate, redraw or retouch pixels. You only choose WHICH vetted template to use,
HOW STRONGLY, and small bounded adjustments. The editor has already applied a physical
baseline (exposure, white balance, black/white points from the histogram), so do not
re-correct exposure or white balance unless the user asks for a mood that needs it.

Workflow:
1. Read the photo, its statistics and the user's request (and the reference photo / guide, if given).
2. Decide the creative direction (mood, palette, contrast, era/film/cinema look).
3. Return EXACTLY 4 variations, all faithful to the request but distinct:
   #1 your best match, #2 a stronger/more dramatic take, #3 a softer/subtler take,
   #4 an alternative interpretation (different template or palette).

Reply with ONE JSON object and nothing else:
{
  "analysis": "한국어 1~2문장: 사진 특징과 선택한 방향",
  "variations": [
    {
      "name": "짧은 한국어 이름",
      "template": "<exact template name from the catalog, or empty string for none>",
      "strength": 1.0,
      "adjust": { "contrast": 0.1, "temperature": -0.1 },
      "advanced": { },
      "reference_match": 0.0
    }
  ]
}

Field rules:
- strength: 0.0-1.5, how much of the template (1 = as designed).
- adjust (optional): deltas added on top. Allowed keys and limits:
  exposure ±1; contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance,
  saturation, clarity, texture, dehaze, fade, grain, vignette, halation, bloom ±0.5.
- advanced (optional, use sparingly): absolute overrides only when no template can express it:
  "hsl": 8 bands [red,orange,yellow,green,aqua,blue,purple,magenta] of {"hue":-45..45,"sat":-1..1,"lum":-1..1};
  "grade_shadows"/"grade_midtones"/"grade_highlights": {"hue":0..360,"sat":0..1};
  "curve"/"curve_r"/"curve_g"/"curve_b": [[x,y],...] in 0..1; "channel_mixer": 3x3 linear RGB; "monochrome": bool.
- reference_match: 0.0-1.0, ONLY when a reference photo is given: how much exact color matching to blend in.

Guidance:
- Prefer templates + strength + small adjust.
- Skin tones are protected automatically; keep faces natural unless asked otherwise.
- Don't be timid: if the user asks for a strong mood (film, cinematic, moody, emotional), commit to it.
- Effects such as infrared, flash, film, cinematic must be built from templates/parameters only.
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

  /// Ask the model for a grading plan: 4 variations, each a template + strength +
  /// bounded adjustments. The caller turns them into recipes on top of the baseline.
  Future<AiPlan> plan({
    required Map<String, dynamic> current,
    required String imageB64,
    required Map<String, dynamic> stats,
    required List<Map<String, dynamic>> templates,
    String request = '',
    String? guideText,
    String? referenceImageB64,
  }) async {
    if (settings.apiKey.trim().isEmpty) {
      throw AiException('${settings.provider.label} API 키를 설정에서 입력해 주세요.');
    }
    final currentForPrompt = cloneRecipe(current)..remove('lut');
    final buf = StringBuffer()..writeln('Template catalog (name | category | look):');
    for (final t in templates) {
      buf.writeln('- ${t['name']} | ${t['category'] ?? ''} | ${t['description'] ?? ''}');
    }
    buf
      ..writeln()
      ..writeln('Photo statistics (original): ${jsonEncode(stats)}')
      ..writeln('Baseline correction already applied (do not repeat it): ${jsonEncode(currentForPrompt)}');
    if (guideText != null && guideText.isNotEmpty) {
      buf
        ..writeln('A color-grading guide the user wants applied (translate its steps into template/adjust/advanced):')
        ..writeln('<guide>')
        ..writeln(guideText)
        ..writeln('</guide>');
    }
    if (referenceImageB64 != null) {
      buf.writeln('The SECOND image is a reference photo whose color style the user wants. '
          'Pick templates/adjustments that reproduce its palette, contrast and mood, and set reference_match '
          '(0.3-0.8 typical) so the engine also blends an exact color match.');
    }
    buf.writeln('User request: ${request.isEmpty ? '이 사진에 가장 잘 어울리는 전문가 수준의 감성 보정' : request}');
    final images = [imageB64, ?referenceImageB64];

    final text = switch (settings.provider) {
      AiProvider.gemini => await _gemini(buf.toString(), images),
      AiProvider.claude => await _claude(buf.toString(), images),
      AiProvider.openai => await _openai(buf.toString(), images),
    };
    return AiPlan.fromJson(_extractJson(text), templates.map((t) => t['name'] as String).toSet());
  }

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

  Future<String> _gemini(String prompt, List<String> images) async {
    final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${settings.model}:generateContent');
    final body = {
      'systemInstruction': {
        'parts': [
          {'text': _systemPrompt}
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

  Future<String> _claude(String prompt, List<String> images) async {
    final body = {
      'model': settings.model,
      'max_tokens': 16000,
      'output_config': {'effort': 'low'},
      'fallbacks': 'default',
      'system': _systemPrompt,
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

  Future<String> _openai(String prompt, List<String> images) async {
    final body = {
      'model': settings.model,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
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

/// Bounded deltas the AI may add on top of a template.
const aiAdjustRanges = <String, double>{
  'exposure': 1.0, 'contrast': 0.5, 'highlights': 0.5, 'shadows': 0.5, 'whites': 0.5, 'blacks': 0.5,
  'temperature': 0.5, 'tint': 0.5, 'vibrance': 0.5, 'saturation': 0.5, 'clarity': 0.5, 'texture': 0.5,
  'dehaze': 0.5, 'fade': 0.5, 'grain': 0.5, 'vignette': 0.5, 'halation': 0.5, 'bloom': 0.5,
};

class AiVariation {
  AiVariation({
    required this.name,
    this.template,
    this.strength = 1.0,
    this.adjust = const {},
    this.advanced = const {},
    this.referenceMatch = 0,
  });
  final String name;
  final String? template;
  final double strength;
  final Map<String, double> adjust;
  final Map<String, dynamic> advanced;
  final double referenceMatch;

  /// Build the recipe: baseline → template at strength → bounded deltas → advanced overrides.
  Map<String, dynamic> toRecipe(Map<String, dynamic> base, Map<String, dynamic>? templateRecipe) {
    var r = cloneRecipe(base);
    if (templateRecipe != null) r = blendRecipe(base, layerRecipe(base, templateRecipe), strength);
    for (final e in adjust.entries) {
      final range = recipeRanges[e.key]!;
      final lo = e.key == 'exposure' ? -5.0 : range.$1, hi = e.key == 'exposure' ? 5.0 : range.$2;
      r[e.key] = (getVal(r, e.key) + e.value).clamp(lo, hi);
    }
    if (advanced.isNotEmpty) r = mergeAiRecipe(r, advanced);
    r['name'] = name;
    r['category'] = 'AI';
    r['description'] = [
      if (template != null) '$template ${(strength * 100).round()}%',
      if (referenceMatch > 0) '참조 매칭 ${(referenceMatch * 100).round()}%',
    ].join(' · ');
    return r;
  }
}

class AiPlan {
  AiPlan(this.analysis, this.variations);
  final String analysis;
  final List<AiVariation> variations;

  factory AiPlan.fromJson(Map<String, dynamic> j, Set<String> templateNames) {
    double n(dynamic v, double d) => v is num ? v.toDouble() : d;
    final vars = <AiVariation>[];
    final list = j['variations'] is List ? j['variations'] as List : [j];
    for (final v in list.whereType<Map>()) {
      final t = v['template'] is String && templateNames.contains(v['template']) ? v['template'] as String : null;
      final adjust = <String, double>{};
      if (v['adjust'] is Map) {
        (v['adjust'] as Map).forEach((k, val) {
          final lim = aiAdjustRanges[k];
          if (lim != null && val is num) adjust[k as String] = val.toDouble().clamp(-lim, lim);
        });
      }
      vars.add(AiVariation(
        name: v['name'] is String && (v['name'] as String).isNotEmpty ? v['name'] as String : 'AI 보정 ${vars.length + 1}',
        template: t,
        strength: n(v['strength'], 1.0).clamp(0.0, 1.5),
        adjust: adjust,
        advanced: v['advanced'] is Map ? (v['advanced'] as Map).cast<String, dynamic>() : const {},
        referenceMatch: n(v['reference_match'], 0).clamp(0.0, 1.0),
      ));
      if (vars.length == 6) break;
    }
    if (vars.isEmpty) throw AiException('AI가 보정안을 만들지 못했습니다. 다시 시도해 주세요.');
    return AiPlan(j['analysis'] is String ? j['analysis'] as String : '', vars);
  }
}
