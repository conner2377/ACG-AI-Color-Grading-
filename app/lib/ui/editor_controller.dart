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
import 'work_store.dart';

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

  /// Recently opened photos (most recent first).
  List<String> recent = [];

  Future<void> loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    recent = (prefs.getStringList('recent') ?? []).where((p) => File(p).existsSync()).toList();
    notifyListeners();
  }

  Future<void> _remember(String p) async {
    recent
      ..remove(p)
      ..insert(0, p);
    if (recent.length > 12) recent = recent.sublist(0, 12);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recent', recent);
  }

  /// Close the photo and go back to the start screen.
  void closePhoto() {
    flushAutosave();
    final s = session;
    session = null;
    path = null;
    preview = original = null;
    recipe = emptyRecipe();
    _blendFrom = _blendTo = null;
    activeTemplate = null;
    candidateThumbs = [];
    aiThumbs = [];
    compareSplit = false;
    notifyListeners();
    s?.close();
    loadRecent();
  }

  Future<void> openPhoto(String p) async {
    _setBusy('사진 불러오는 중…');
    try {
      final old = session;
      session = await EngineSession.open(p);
      unawaited(old?.close());
      path = p;
      unawaited(_remember(p));
      fitNotes = [];
      fitStrength = null;
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
      savedWorks = await WorkStore.saved(p);
      final prev = await WorkStore.current(p);
      if (prev != null && !_isUnedited(prev) && path == p) {
        recipe = cloneRecipe(prev);
        _history
          ..clear()
          ..add(jsonEncode(emptyRecipe()))
          ..add(jsonEncode(recipe));
        _hIndex = 1;
        _scheduleRender();
        notice = '지난번 작업을 이어서 불러왔어요';
        notifyListeners();
      }
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
    _scheduleAutosave();
    notifyListeners();
  }

  Timer? _autosave;

  /// Write a pending autosave now (on close).
  void flushAutosave() {
    final t = _autosave;
    if (t == null || !t.isActive) return;
    t.cancel();
    final p = path;
    if (p != null) WorkStore.autosave(p, cloneRecipe(recipe));
  }

  void _scheduleAutosave() {
    final p = path;
    if (p == null) return;
    _autosave?.cancel();
    final r = cloneRecipe(recipe);
    _autosave = Timer(const Duration(milliseconds: 800), () => WorkStore.autosave(p, r));
  }

  /// Named versions of the open photo's edit.
  List<SavedWork> savedWorks = [];

  /// Shown once after a photo reopens with its previous edit.
  String? notice;

  Future<void> saveWork(String name) async {
    final p = path;
    if (p == null) return;
    await WorkStore.save(p, name, cloneRecipe(recipe));
    savedWorks = await WorkStore.saved(p);
    notice = '작업을 저장했어요: $name';
    notifyListeners();
  }

  Future<void> loadWork(SavedWork w) async {
    _blendFrom = _blendTo = null;
    activeTemplate = null;
    setRecipe(w.recipe);
  }

  Future<void> deleteWork(SavedWork w) async {
    final p = path;
    if (p == null) return;
    await WorkStore.delete(p, w);
    savedWorks = await WorkStore.saved(p);
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

  /// Fit looks to the photo (on by default). Off = plain preset, like a LUT pasted on.
  bool autoFit = true;

  /// Why the last look was adjusted for this photo, and how strongly it was applied.
  List<String> fitNotes = [];
  double? fitStrength;

  /// Apply a look. Built-in looks are layered on the base and, with [autoFit], fitted to
  /// this photo by the engine (statistics + strength search). Saved looks apply as-is.
  Future<void> applyTemplate(Map<String, dynamic> t, {bool layer = true}) async {
    final base = _templateBase();
    Map<String, dynamic> to;
    fitNotes = [];
    fitStrength = null;
    if (layer && autoFit && session != null) {
      final res = await session!.adaptLook(base, t);
      to = res['recipe'] as Map<String, dynamic>;
      final rep = res['report'] as Map<String, dynamic>;
      fitNotes = (rep['notes'] as List).cast<String>();
      fitStrength = (rep['strength'] as num).toDouble();
    } else {
      to = layer ? layerRecipe(base, t) : withGeometryOf(t, recipe);
    }
    _blendFrom = base;
    _blendTo = to;
    activeTemplate = t['name'] as String?;
    templateAmount = 1.0;
    recipe = cloneRecipe(to);
    _scheduleRender();
    commitHistory();
    notifyListeners();
  }

  void setAutoFit(bool v) {
    autoFit = v;
    notifyListeners();
    final p = activePreset;
    if (p != null) applyTemplate(p);
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

  /// The last AI request, so "한 번 더 다듬기" can refer to it.
  String aiRequest = '';

  /// Run the AI: the engine computes the physical baseline, then the model analyzes the
  /// photo and decides the edit values itself (3 variations). With a reference photo the
  /// engine also blends an exact color match.
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
    final refB64 = referencePath == null ? null : await EngineSession.thumbnailOf(referencePath);
    final img = await s.aiThumbnail(base, size: 640);
    final plan = await AiService(settings).plan(
      current: base,
      imageB64: img,
      stats: stats ?? await s.analyze(),
      request: request,
      guideText: guideText,
      referenceImageB64: refB64,
    );
    final recipes = <Map<String, dynamic>>[];
    for (final v in plan.variations) {
      var r = v.toRecipe(base);
      if (referencePath != null && v.referenceMatch > 0) {
        final matched = await s.matchReference(r, referencePath, v.referenceMatch);
        for (final k in ['name', 'category', 'description']) {
          matched[k] = r[k];
        }
        r = matched;
      }
      recipes.add(await _finishAi(r, base, cleanOnly: request.trim().isEmpty && guideText == null && referencePath == null));
    }
    aiRequest = request;
    aiRound = 1;
    await _showAi(plan.analysis, recipes, base);
  }

  /// How many follow-up rounds the current AI edit has been through (1 = first answer).
  int aiRound = 1;

  /// Follow-up pass on the AI edit that is on screen: the model compares the baseline
  /// with it and changes it per [followUp] (2차, 3차 수정…), or just polishes it when
  /// [followUp] is empty. The result is added as a new card and applied.
  Future<void> refineAi(AiSettings settings, {String followUp = ''}) async {
    final s = session;
    if (s == null) return;
    final base = withGeometryOf(autoBase ?? emptyRecipe(), recipe);
    final current = cloneRecipe(recipe);
    final before = await s.aiThumbnail(base, size: 640);
    final after = await s.aiThumbnail(current, size: 640);
    final plan = await AiService(settings).refine(
      beforeB64: before,
      afterB64: after,
      currentRecipe: current,
      request: aiRequest,
      followUp: followUp,
    );
    final v = plan.variations.first;
    var r = v.toRecipe(current);
    r = await _finishAi(r, base, cleanOnly: aiRequest.trim().isEmpty && followUp.trim().isEmpty);
    aiRound++;
    final label = followUp.trim().isEmpty ? '다듬기' : followUp.trim();
    r['name'] = '$aiRound차 · ${label.length > 14 ? '${label.substring(0, 14)}…' : label}';
    if (v.reason.isNotEmpty) r['description'] = v.reason;
    final thumbs = await _thumbs([r]);
    aiThumbs = [...thumbs, ...aiThumbs];
    if (plan.analysis.isNotEmpty) aiAnalysis = plan.analysis;
    pickAiVariation(r);
  }

  /// Finishing pass on an AI edit, like a retoucher's last check: with no specific mood
  /// requested, effects that make a photo look processed (grain, glow, heavy matte,
  /// strong vignette, crunchy clarity) are kept to clean amounts; then the engine renders
  /// it and fixes clipped highlights, crushed shadows, over-saturated colors and skin.
  Future<Map<String, dynamic>> _finishAi(Map<String, dynamic> r, Map<String, dynamic> base, {required bool cleanOnly}) async {
    final s = session;
    if (s == null) return r;
    var out = cloneRecipe(r);
    if (cleanOnly) {
      const caps = {'grain': 0.0, 'halation': 0.0, 'bloom': 0.0, 'fade': 0.08, 'clarity': 0.35, 'texture': 0.3, 'dehaze': 0.3, 'sharpen': 0.3};
      caps.forEach((k, max) {
        if (getVal(out, k) > max) out[k] = max;
      });
      if (getVal(out, 'vignette') < -0.2) out['vignette'] = -0.2;
    }
    try {
      final res = await s.polish(out, base);
      final fixed = (res['recipe'] as Map).cast<String, dynamic>();
      final notes = (res['notes'] as List?)?.cast<String>() ?? const [];
      for (final k in ['name', 'category', 'description']) {
        fixed[k] = r[k];
      }
      if (notes.isNotEmpty) {
        final d = (r['description'] as String?) ?? '';
        fixed['description'] = '${d.isEmpty ? '' : '$d\n'}마무리: ${notes.join(' ')}';
      }
      out = fixed;
    } catch (_) {
      // The check is a refinement; the AI edit is still valid without it.
    }
    return out;
  }

  Future<void> _showAi(String analysis, List<Map<String, dynamic>> recipes, Map<String, dynamic> base) async {
    aiAnalysis = analysis;
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
