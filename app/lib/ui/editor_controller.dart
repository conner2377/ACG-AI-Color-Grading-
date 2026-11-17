import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      stats = null;
      original = await frameToImage(await session!.renderPreview(emptyRecipe()));
      preview = original;
      error = null;
      _setBusy(null);
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

  /// Apply a template like a Lightroom preset, with an adjustable amount.
  void applyTemplate(Map<String, dynamic> t) {
    _blendFrom = cloneRecipe(_blendFrom ?? recipe);
    _blendTo = cloneRecipe(t);
    activeTemplate = t['name'] as String?;
    templateAmount = 1.0;
    recipe = cloneRecipe(t);
    _scheduleRender();
    commitHistory();
    notifyListeners();
  }

  void setTemplateAmount(double a, {bool commit = false}) {
    final from = _blendFrom, to = _blendTo;
    if (from == null || to == null) return;
    templateAmount = a;
    final out = cloneRecipe(a >= 0.5 ? to : from);
    for (final k in recipeRanges.keys) {
      final v = getNum(from, k) + (getNum(to, k) - getNum(from, k)) * a;
      out[k] = v;
    }
    for (var i = 0; i < 8; i++) {
      for (final f in ['hue', 'sat', 'lum']) {
        final v = getNum(from, 'hsl.$i.$f') + (getNum(to, 'hsl.$i.$f') - getNum(from, 'hsl.$i.$f')) * a;
        setNum(out, 'hsl.$i.$f', v);
      }
    }
    for (final g in ['grade_shadows', 'grade_midtones', 'grade_highlights']) {
      if (to[g] != null) {
        out[g] = {'hue': getNum(to, '$g.hue'), 'sat': getNum(to, '$g.sat') * a};
      }
    }
    if (to['lut'] != null) {
      out['lut'] = to['lut'];
      out['lut_strength'] = getNum(to, 'lut_strength') == 0 ? a : getNum(to, 'lut_strength') * a;
    }
    recipe = out;
    _scheduleRender();
    if (commit) commitHistory();
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
        final frame = await session!.renderPreview(recipe);
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
    presetThumbs = await _thumbs(enginePresets());
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
      candidateThumbs = await _thumbs(cands);
      _setBusy(null);
    } catch (e) {
      error = '분석 실패: $e';
      _setBusy(null);
    }
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
