// AI color grading: the model reads the photo (small JPEG), its statistics and the
// user's request, and answers with recipe VALUES only. The engine then applies
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
You are an expert photo colorist working inside a non-destructive editor (like Lightroom).
You NEVER generate or redraw images. You only choose edit parameter values; the editor
applies them to the original full-resolution photo.

Reply with ONE JSON object and nothing else. Include only the fields you want to set
(absolute values, not deltas). Omitted fields keep their current value.

Fields (all optional):
- "name": short Korean name for this look (e.g. "적외선 느낌")
- exposure (-5..5 stops), contrast, highlights, shadows, whites, blacks (-1..1)
- temperature (-1 cool .. 1 warm), tint (-1 green .. 1 magenta)
- vibrance, saturation (-1..1); clarity, dehaze (-1..1); sharpen (0..1)
- vignette (-1 dark corners .. 1 bright corners); grain (0..1); fade (0..1, matte blacks)
- "hsl": array of exactly 8 bands in this order [red, orange, yellow, green, aqua, blue, purple, magenta],
  each {"hue": -45..45 degrees, "sat": -1..1, "lum": -1..1}
- "grade_shadows", "grade_midtones", "grade_highlights": {"hue": 0..360, "sat": 0..1} color wheels
- "curve", "curve_r", "curve_g", "curve_b": tone curve points [[x,y],...] with x,y in 0..1, sorted by x,
  at least 2 points, display (gamma) space. [] = identity.
- "channel_mixer": 3x3 matrix [[rr,rg,rb],[gr,gg,gb],[br,bg,bb]] in linear RGB (null = off).
  Rows are output R,G,B; e.g. for false-color infrared you may move green into red.
- "monochrome": true for black & white.

Guidance:
- Typical tasteful values are small (|value| <= 0.5). Avoid clipping skin tones.
- Look at the photo and its statistics; correct problems first (exposure, white balance), then style.
- Effects like "flash", "infrared", "film", "cinematic" must be emulated with these parameters only.
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

  /// Ask the model for a recipe. Returns the merged, validated recipe.
  Future<Map<String, dynamic>> grade({
    required Map<String, dynamic> current,
    required String imageB64,
    required Map<String, dynamic> stats,
    String request = '',
    String? guideText,
    String? referenceImageB64,
  }) async {
    if (settings.apiKey.trim().isEmpty) {
      throw AiException('${settings.provider.label} API 키를 설정에서 입력해 주세요.');
    }
    final currentForPrompt = cloneRecipe(current)..remove('lut');
    final buf = StringBuffer()
      ..writeln('Photo statistics: ${jsonEncode(stats)}')
      ..writeln('Current edit values: ${jsonEncode(currentForPrompt)}');
    if (guideText != null && guideText.isNotEmpty) {
      buf
        ..writeln('A color-grading guide the user wants applied (follow its steps, convert to fields):')
        ..writeln('"""')
        ..writeln(guideText)
        ..writeln('"""');
    }
    if (referenceImageB64 != null) {
      buf.writeln('The SECOND image is a reference whose color style the user wants. Match its look.');
    }
    buf.writeln('User request: ${request.isEmpty ? '이 사진에 가장 잘 어울리는 전문가 수준의 보정' : request}');
    final images = [imageB64, ?referenceImageB64];

    final text = switch (settings.provider) {
      AiProvider.gemini => await _gemini(buf.toString(), images),
      AiProvider.claude => await _claude(buf.toString(), images),
      AiProvider.openai => await _openai(buf.toString(), images),
    };
    final json = _extractJson(text);
    return mergeAiRecipe(current, json);
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
      'generationConfig': {'responseMimeType': 'application/json', 'temperature': 0.4},
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
