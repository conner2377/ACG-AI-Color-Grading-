import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_service.dart';
import '../engine/engine.dart';
import '../engine/recipe.dart';

Future<ui.Image> frameToImage(Frame f) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(f.rgba, f.width, f.height, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class PhotoThumb {
  PhotoThumb(this.recipe, this.image);
  final Map<String, dynamic> recipe;
  final ui.Image? image;
  String get name => (recipe['name'] as String?)?.isNotEmpty == true ? recipe['name'] as String : '이름 없음';
}

/// Editing state: the open photo, the current recipe, undo history and renders.
class EditorController extends ChangeNotifier {
  EngineSession? session;
  String? path;
  Map<String, dynamic> recipe = emptyRecipe();
  ui.Image? preview;
  ui.Image? original;
  bool showOriginal = false;
  String? busy;
  String? error;

  final List<String> _history = [];
  int _hIndex = -1;

  bool _rendering = false;
  bool _dirty = false;

  // Template "amount" blending.
  Map<String, dynamic>? _blendFrom;
  Map<String, dynamic>? _blendTo;
  double templateAmount = 1.0;
  String? activeTemplate;

  List<PhotoThumb> presetThumbs = [];
  List<PhotoThumb> userThumbs = [];
  List<PhotoThumb> candidateThumbs = [];
  Map<String, dynamic>? stats;

  /// Physical baseline from the histogram (exposure, WB, black/white points).
  Map<String, dynamic>? autoBase;

  /// Latest AI result: explanation and the variations to pick from.
  String? aiAnalysis;
  List<PhotoThumb> aiThumbs = [];

  /// Template category filter in the templates panel (null = all).
  String? templateCategory;

  /// True while the crop tool is open: the preview shows the uncropped frame.
  bool cropping = false;
  double? cropAspect;
  String cropAspectLabel = '자유';

  /// Live RGB + luma histogram of the current preview (64 bins each, normalized).
  List<List<double>>? histogram;

  void touch() => notifyListeners();

  /// Before/after split view: the original shows left of the divider.
  bool compareSplit = false;
  double splitPos = 0.5;
  String _originalGeoKey = '';

  /// Favorite look names (built-in templates and my looks).
  Set<String> favorites = {};

  Future<void> loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    favorites = (prefs.getStringList('favorites') ?? []).toSet();
    notifyListeners();
  }

  Future<void> toggleFavorite(String name) async {
    if (!favorites.remove(name)) favorites.add(name);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', favorites.toList());
  }

  /// Drop the active look and go back to the state before it.
  void clearLook() {
    final from = _blendFrom;
    if (from == null) return;
    recipe = withGeometryOf(from, recipe);
    _blendFrom = _blendTo = null;
    activeTemplate = null;
    _scheduleRender();
    commitHistory();
    notifyListeners();
  }

  /// Export many photos with the current look. With [perPhotoBase] each photo first
  /// gets its own histogram baseline and then the active built-in look at the current
  /// strength; otherwise the exact current values are reused. Returns files written.
  Future<int> batchExport(List<String> paths, String outDir, String ext, int quality,
      {required bool perPhotoBase, void Function(int done)? onProgress}) async {
    final style = perPhotoBase ? activePreset : null;
    final same = withGeometryOf(recipe, emptyRecipe());
    var done = 0;
    for (final p in paths) {
      final s = await EngineSession.open(p, previewSize: 1024);
      try {
        var r = same;
        if (style != null) {
          final res = await s.autoCandidates();
          final cands = (res['candidates'] as List).cast<Map<String, dynamic>>();
          final base = cands.isEmpty ? emptyRecipe() : cands.first;
          r = blendRecipe(base, layerRecipe(base, style), templateAmount);
        }
        final name = p.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
        await s.export(r, '$outDir${Platform.pathSeparator}${name}_ACG.$ext', jpegQuality: quality);
        done++;
        onProgress?.call(done);
      } finally {
        await s.close();
      }
    }
    return done;
  }

  /// The built-in look currently applied, if any.
  Map<String, dynamic>? get activePreset {
    if (_blendTo == null || activeTemplate == null) return null;
    for (final p in enginePresets()) {
      if (p['name'] == activeTemplate) return p;
    }
    return null;
  }

  bool get hasPhoto => session != null;
  bool get canUndo => _hIndex > 0;
  bool get canRedo => _hIndex < _history.length - 1;

  Future<void> openPhoto(String p) async {
    _setBusy('사진 불러오는 중…');
    try {
      final old = session;
      session = await EngineSession.open(p);
      unawaited(old?.close());
      path = p;
      recipe = emptyRecipe();
      _history
        ..clear()
        ..add(jsonEncode(recipe));
      _hIndex = 0;
      _blendFrom = _blendTo = null;
      activeTemplate = null;
      candidateThumbs = [];
      aiThumbs = [];
      aiAnalysis = null;
      stats = null;
      autoBase = null;
      cropping = false;
      cropAspect = null;
      cropAspectLabel = '자유';
      original = await frameToImage(await session!.renderPreview(emptyRecipe()));
      preview = original;
      _originalGeoKey = jsonEncode(withGeometryOf(emptyRecipe(), emptyRecipe()));
      histogram = null;
      _scheduleRender();
      error = null;
      _setBusy(null);
      await runAuto();
      unawaited(refreshTemplateThumbs());
    } catch (e) {
      error = '사진을 열 수 없습니다: $e';
      _setBusy(null);
    }
  }

  void _setBusy(String? b) {
    busy = b;
    notifyListeners();
  }

  void setError(String? e) {
    error = e;
    notifyListeners();
  }

  /// Live edit (slider drag): render without adding history every frame.
  void edit(void Function(Map<String, dynamic> r) f, {bool commit = false}) {
    f(recipe);
    _blendFrom = _blendTo = null;
    activeTemplate = null;
    _scheduleRender();
    if (commit) commitHistory();
    notifyListeners();
  }

  void commitHistory() {
    final s = jsonEncode(recipe);
    if (_hIndex >= 0 && _history[_hIndex] == s) return;
    _history.removeRange(_hIndex + 1, _history.length);
    _history.add(s);
    if (_history.length > 200) _history.removeAt(0);
    _hIndex = _history.length - 1;
    notifyListeners();
  }

  void setRecipe(Map<String, dynamic> r) {
    recipe = cloneRecipe(r);
    _scheduleRender();
    commitHistory();
    notifyListeners();
  }

  void undo() {
    if (!canUndo) return;
    _hIndex--;
    recipe = jsonDecode(_history[_hIndex]) as Map<String, dynamic>;
    _blendFrom = _blendTo = null;
    _scheduleRender();
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _hIndex++;
    recipe = jsonDecode(_history[_hIndex]) as Map<String, dynamic>;
    _blendFrom = _blendTo = null;
    _scheduleRender();
    notifyListeners();
  }

  void reset() => setRecipe(emptyRecipe());

  /// The edit a template is layered on: the state before the last template (so
  /// clicking through templates doesn't stack them), or the histogram baseline when the
  /// photo hasn't been edited yet. Geometry (crop/rotate) is always kept.
  Map<String, dynamic> _templateBase() {
    final from = _blendFrom ?? recipe;
    if (_isUnedited(from) && autoBase != null) return withGeometryOf(autoBase!, from);
    return cloneRecipe(from);
  }

  static const _geometryKeys = ['angle', 'rotate90', 'flip_h', 'flip_v', 'crop'];

  static Map<String, dynamic> withGeometryOf(Map<String, dynamic> r, Map<String, dynamic> geo) {
    final out = cloneRecipe(r);
    for (final k in _geometryKeys) {
      if (geo.containsKey(k)) {
        out[k] = geo[k];
      } else {
        out.remove(k);
      }
    }
    return out;
  }

  bool _isUnedited(Map<String, dynamic> r) {
    final stripped = cloneRecipe(r)..removeWhere((k, _) => _geometryKeys.contains(k) || k == 'name');
    return stripped.isEmpty;
  }

  /// Apply a template like a Lightroom preset (layered on the base), with an amount.
  void applyTemplate(Map<String, dynamic> t, {bool layer = true}) {
    final base = _templateBase();
    _blendFrom = base;
    _blendTo = layer ? layerRecipe(base, t) : withGeometryOf(t, recipe);
    activeTemplate = t['name'] as String?;
    templateAmount = 1.0;
    recipe = cloneRecipe(_blendTo!);
    _scheduleRender();
    commitHistory();
    notifyListeners();
  }

  /// Template strength 0..150%.
  void setTemplateAmount(double a, {bool commit = false}) {
    final from = _blendFrom, to = _blendTo;
    if (from == null || to == null) return;
    templateAmount = a;
    recipe = blendRecipe(from, to, a);
    _scheduleRender();
    if (commit) commitHistory();
    notifyListeners();
  }

  /// Edit geometry without breaking a template blend in progress.
  void editGeometry(void Function(Map<String, dynamic> r) f, {bool commit = false}) {
    f(recipe);
    for (final m in [_blendFrom, _blendTo]) {
      if (m != null) {
        for (final k in _geometryKeys) {
          if (recipe.containsKey(k)) {
            m[k] = recipe[k];
          } else {
            m.remove(k);
          }
        }
      }
    }
    _scheduleRender();
    if (commit) commitHistory();
    notifyListeners();
  }

  void setCropping(bool v) {
    cropping = v;
    _scheduleRender();
    notifyListeners();
  }

  bool get templateBlendActive => _blendTo != null;

  void _scheduleRender() {
    if (session == null) return;
    _dirty = true;
    if (!_rendering) _renderLoop();
  }

  Future<void> _renderLoop() async {
    _rendering = true;
    try {
      while (_dirty && session != null) {
        _dirty = false;
        final r = cropping ? (cloneRecipe(recipe)..remove('crop')) : recipe;
        final geo = withGeometryOf(emptyRecipe(), r);
        final geoKey = jsonEncode(geo);
        if (geoKey != _originalGeoKey) {
          // Keep the "before" image framed like the edit so compare lines up.
          original = await frameToImage(await session!.renderPreview(geo));
          _originalGeoKey = geoKey;
        }
        final frame = await session!.renderPreview(r);
        histogram = _histogram(frame);
        preview = await frameToImage(frame);
        notifyListeners();
      }
    } catch (e) {
      error = '렌더링 오류: $e';
      notifyListeners();
    } finally {
      _rendering = false;
    }
  }

  static List<List<double>> _histogram(Frame f) {
    final h = List.generate(4, (_) => List<double>.filled(64, 0));
    final px = f.rgba;
    final step = math.max(1, (f.width * f.height / 120000).floor()) * 4;
    for (var i = 0; i + 3 < px.length; i += step) {
      final r = px[i], g = px[i + 1], b = px[i + 2];
      h[0][r >> 2]++;
      h[1][g >> 2]++;
      h[2][b >> 2]++;
      h[3][((r * 54 + g * 183 + b * 19) >> 8) >> 2]++;
    }
    for (final ch in h) {
      // Normalize ignoring the extreme bins so clipping spikes don't flatten the rest.
      var m = 1.0;
      for (var i = 1; i < 63; i++) {
        m = math.max(m, ch[i]);
      }
      for (var i = 0; i < 64; i++) {
        ch[i] = math.min(1.0, ch[i] / m);
      }
    }
    return h;
  }

  // ---------- templates ----------

  static Future<List<Map<String, dynamic>>> loadUserTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('templates') ?? [])
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .toList();
  }

  Future<void> saveUserTemplate(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('templates') ?? [];
    final t = cloneRecipe(recipe)..['name'] = name;
    list.removeWhere((s) => (jsonDecode(s) as Map)['name'] == name);
    list.insert(0, jsonEncode(t));
    await prefs.setStringList('templates', list);
    await refreshTemplateThumbs();
  }

  Future<void> deleteUserTemplate(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('templates') ?? [];
    list.removeWhere((s) => (jsonDecode(s) as Map)['name'] == name);
    await prefs.setStringList('templates', list);
    await refreshTemplateThumbs();
  }

  Future<void> importTemplate(Map<String, dynamic> t) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('templates') ?? [];
    list.insert(0, jsonEncode(t));
    await prefs.setStringList('templates', list);
    await refreshTemplateThumbs();
  }

  Future<List<PhotoThumb>> _thumbs(List<Map<String, dynamic>> recipes) async {
    final s = session;
    final out = <PhotoThumb>[];
    for (final r in recipes) {
      ui.Image? img;
      if (s != null) {
        try {
          img = await frameToImage(await s.renderThumb(r));
        } catch (_) {}
      }
      out.add(PhotoThumb(r, img));
    }
    return out;
  }

  Future<void> refreshTemplateThumbs() async {
    final base = autoBase ?? emptyRecipe();
    final thumbs = await _thumbs([for (final p in enginePresets()) layerRecipe(base, p)]);
    // Keep the original template (not the layered one) so applying it layers correctly.
    presetThumbs = [for (var i = 0; i < thumbs.length; i++) PhotoThumb(enginePresets()[i], thumbs[i].image)];
    notifyListeners();
    userThumbs = await _thumbs(await loadUserTemplates());
    notifyListeners();
  }

  Future<void> runAuto() async {
    final s = session;
    if (s == null) return;
    _setBusy('사진 분석 중…');
    try {
      final res = await s.autoCandidates();
      stats = res['stats'] as Map<String, dynamic>;
      final cands = (res['candidates'] as List).cast<Map<String, dynamic>>();
      if (cands.isNotEmpty) autoBase = cands.first;
      candidateThumbs = await _thumbs(cands);
      _setBusy(null);
    } catch (e) {
      error = '분석 실패: $e';
      _setBusy(null);
    }
  }

  /// Run the AI plan: baseline first (engine), then the model picks templates, strength
  /// and bounded tweaks; each variation becomes a recipe, optionally blended with an
  /// exact color match to the reference photo.
  Future<void> runAi({
    required AiSettings settings,
    String request = '',
    String? guideText,
    String? referencePath,
  }) async {
    final s = session;
    if (s == null) return;
    if (autoBase == null) await runAuto();
    final base = withGeometryOf(autoBase ?? emptyRecipe(), recipe);
    final templates = enginePresets();
    final refB64 = referencePath == null ? null : await EngineSession.thumbnailOf(referencePath);
    final img = await s.aiThumbnail(base);
    final plan = await AiService(settings).plan(
      current: base,
      imageB64: img,
      stats: stats ?? await s.analyze(),
      templates: templates,
      request: request,
      guideText: guideText,
      referenceImageB64: refB64,
    );
    final byName = {for (final t in templates) t['name'] as String: t};
    final recipes = <Map<String, dynamic>>[];
    for (final v in plan.variations) {
      var r = v.toRecipe(base, v.template == null ? null : byName[v.template]);
      if (referencePath != null && v.referenceMatch > 0) {
        final matched = await s.matchReference(r, referencePath, v.referenceMatch);
        matched['name'] = r['name'];
        matched['category'] = r['category'];
        matched['description'] = r['description'];
        r = matched;
      }
      recipes.add(r);
    }
    aiAnalysis = plan.analysis;
    aiThumbs = await _thumbs(recipes);
    if (recipes.isNotEmpty) {
      _blendFrom = base;
      _blendTo = recipes.first;
      templateAmount = 1.0;
      activeTemplate = recipes.first['name'] as String?;
      setRecipe(recipes.first);
    }
    notifyListeners();
  }

  /// Pick one of the AI variations (keeps the strength slider working on it).
  void pickAiVariation(Map<String, dynamic> r) {
    final base = withGeometryOf(autoBase ?? emptyRecipe(), recipe);
    _blendFrom = base;
    _blendTo = withGeometryOf(r, recipe);
    templateAmount = 1.0;
    activeTemplate = r['name'] as String?;
    recipe = cloneRecipe(_blendTo!);
    _scheduleRender();
    commitHistory();
    notifyListeners();
  }

  Future<T?> withBusy<T>(String label, Future<T> Function() f) async {
    _setBusy(label);
    try {
      return await f();
    } catch (e) {
      error = '$e';
      return null;
    } finally {
      _setBusy(null);
    }
  }
}
