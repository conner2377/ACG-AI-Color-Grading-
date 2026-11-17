// dart:ffi bindings to the Rust engine (engine/src/ffi.rs).
//
// All calls that touch a session are serialized through [EngineSession._queue]
// and run on a background isolate so the UI never blocks.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _OpenN = Pointer<Void> Function(Pointer<Utf8>, Uint32);
typedef _OpenD = Pointer<Void> Function(Pointer<Utf8>, int);
typedef _CloseN = Void Function(Pointer<Void>);
typedef _CloseD = void Function(Pointer<Void>);
typedef _SizeN = Void Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>);
typedef _SizeD = void Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>);
typedef _RenderN = Pointer<Uint8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>, Pointer<Uint32>);
typedef _RenderD = Pointer<Uint8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>, Pointer<Uint32>);
typedef _ThumbN = Pointer<Uint8> Function(Pointer<Void>, Pointer<Utf8>, Uint32, Pointer<Uint32>, Pointer<Uint32>);
typedef _ThumbD = Pointer<Uint8> Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Uint32>, Pointer<Uint32>);
typedef _ExportN = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Uint32);
typedef _ExportD = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _StrSN = Pointer<Utf8> Function(Pointer<Void>);
typedef _StrN = Pointer<Utf8> Function();
typedef _MatchN = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Float);
typedef _MatchD = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, double);
typedef _AdaptN = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AiThumbN = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Uint32);
typedef _AiThumbD = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _CubeN = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeN = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);

class EngineException implements Exception {
  EngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Raw library bindings. Cheap to construct; each isolate makes its own.
class _Lib {
  _Lib() : _l = _open();

  final DynamicLibrary _l;

  static DynamicLibrary _open() {
    if (Platform.isWindows) return DynamicLibrary.open('photo_grade_engine.dll');
    if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libphoto_grade_engine.so');
    if (Platform.isMacOS) return DynamicLibrary.open('libphoto_grade_engine.dylib');
    throw UnsupportedError('Unsupported platform');
  }

  late final open = _l.lookupFunction<_OpenN, _OpenD>('acg_open');
  late final close = _l.lookupFunction<_CloseN, _CloseD>('acg_close');
  late final size = _l.lookupFunction<_SizeN, _SizeD>('acg_size');
  late final renderPreview = _l.lookupFunction<_RenderN, _RenderD>('acg_render_preview');
  late final renderThumb = _l.lookupFunction<_ThumbN, _ThumbD>('acg_render_thumb');
  late final export = _l.lookupFunction<_ExportN, _ExportD>('acg_export');
  late final autoCandidates = _l.lookupFunction<_StrSN, _StrSN>('acg_auto_candidates');
  late final analyze = _l.lookupFunction<_StrSN, _StrSN>('acg_analyze');
  late final presets = _l.lookupFunction<_StrN, _StrN>('acg_presets');
  late final matchReference = _l.lookupFunction<_MatchN, _MatchD>('acg_match_reference');
  late final adaptLook = _l.lookupFunction<_AdaptN, _AdaptN>('acg_adapt_look');
  late final aiThumb = _l.lookupFunction<_AiThumbN, _AiThumbD>('acg_ai_thumbnail_b64');
  late final loadCube = _l.lookupFunction<_CubeN, _CubeN>('acg_load_cube');
  late final lastError = _l.lookupFunction<_StrN, _StrN>('acg_last_error');
  late final stringFree = _l.lookupFunction<_FreeN, _FreeD>('acg_string_free');

  String takeString(Pointer<Utf8> p) {
    if (p == nullptr) throw EngineException(error());
    try {
      return p.toDartString();
    } finally {
      stringFree(p);
    }
  }

  String error() {
    final p = lastError();
    if (p == nullptr) return 'unknown engine error';
    final s = p.toDartString();
    stringFree(p);
    return s;
  }
}

/// A rendered RGBA8 frame.
class Frame {
  Frame(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

Frame _render(_Lib lib, int addr, String recipe, int? thumb) {
  return using((arena) {
    final w = arena<Uint32>();
    final h = arena<Uint32>();
    final r = recipe.toNativeUtf8(allocator: arena);
    final s = Pointer<Void>.fromAddress(addr);
    final px = thumb == null ? lib.renderPreview(s, r, w, h) : lib.renderThumb(s, r, thumb, w, h);
    if (px == nullptr) throw EngineException(lib.error());
    final n = w.value * h.value * 4;
    return Frame(w.value, h.value, Uint8List.fromList(px.asTypedList(n)));
  });
}

/// Built-in templates (synchronous, small).
List<Map<String, dynamic>> enginePresets() {
  final lib = _Lib();
  return (jsonDecode(lib.takeString(lib.presets())) as List).cast<Map<String, dynamic>>();
}

/// Load a .cube LUT file as a template recipe.
Future<Map<String, dynamic>> engineLoadCube(String path) => Isolate.run(() {
      final lib = _Lib();
      return using((arena) =>
          jsonDecode(lib.takeString(lib.loadCube(path.toNativeUtf8(allocator: arena)))) as Map<String, dynamic>);
    });

class EngineSession {
  EngineSession._(this._addr, this.width, this.height);

  final int _addr;
  final int width;
  final int height;
  Future<void> _queue = Future.value();
  bool _closed = false;

  /// Serialize calls: the Rust session is not thread-safe.
  Future<T> _run<T>(T Function(_Lib lib, int addr) f) {
    final addr = _addr;
    final result = _queue.then((_) => Isolate.run(() => f(_Lib(), addr)));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<EngineSession> open(String path, {int previewSize = 1600}) async {
    final (addr, w, h) = await Isolate.run(() {
      final lib = _Lib();
      return using((arena) {
        final s = lib.open(path.toNativeUtf8(allocator: arena), previewSize);
        if (s == nullptr) throw EngineException(lib.error());
        final pw = arena<Uint32>();
        final ph = arena<Uint32>();
        lib.size(s, pw, ph);
        return (s.address, pw.value, ph.value);
      });
    });
    return EngineSession._(addr, w, h);
  }

  Future<Frame> renderPreview(Map<String, dynamic> recipe) {
    final json = jsonEncode(recipe);
    return _run((lib, a) => _render(lib, a, json, null));
  }

  Future<Frame> renderThumb(Map<String, dynamic> recipe, {int size = 220}) {
    final json = jsonEncode(recipe);
    return _run((lib, a) => _render(lib, a, json, size));
  }

  /// Full-resolution export. `.jpg` uses [jpegQuality]; `.png`/`.tif` are 16-bit lossless.
  Future<void> export(Map<String, dynamic> recipe, String path, {int jpegQuality = 100}) {
    final json = jsonEncode(recipe);
    return _run((lib, a) => using((arena) {
          final rc = lib.export(Pointer.fromAddress(a), json.toNativeUtf8(allocator: arena),
              path.toNativeUtf8(allocator: arena), jpegQuality);
          if (rc != 0) throw EngineException(lib.error());
        }));
  }

  /// Analysis + auto-graded candidates: {stats, candidates: [recipe...]}.
  Future<Map<String, dynamic>> autoCandidates() =>
      _run((lib, a) => jsonDecode(lib.takeString(lib.autoCandidates(Pointer.fromAddress(a)))) as Map<String, dynamic>);

  Future<Map<String, dynamic>> analyze() =>
      _run((lib, a) => jsonDecode(lib.takeString(lib.analyze(Pointer.fromAddress(a)))) as Map<String, dynamic>);

  /// Returns [base] plus a 3D LUT that matches the reference photo's look.
  Future<Map<String, dynamic>> matchReference(Map<String, dynamic> base, String referencePath, double strength) {
    final json = jsonEncode(base);
    return _run((lib, a) => using((arena) => jsonDecode(lib.takeString(lib.matchReference(Pointer.fromAddress(a),
        json.toNativeUtf8(allocator: arena), referencePath.toNativeUtf8(allocator: arena), strength))) as Map<String, dynamic>));
  }

  /// Fit [look] to this photo on top of [base]. Returns {recipe, report:{strength, change, notes}}.
  Future<Map<String, dynamic>> adaptLook(Map<String, dynamic> base, Map<String, dynamic> look) {
    final b = jsonEncode(base), l = jsonEncode(look);
    return _run((lib, a) => using((arena) => jsonDecode(lib.takeString(lib.adaptLook(
        Pointer.fromAddress(a), b.toNativeUtf8(allocator: arena), l.toNativeUtf8(allocator: arena)))) as Map<String, dynamic>));
  }

  /// Small JPEG (base64) of the photo with [recipe] applied, for AI requests.
  Future<String> aiThumbnail(Map<String, dynamic> recipe, {int size = 768}) {
    final json = jsonEncode(recipe);
    return _run((lib, a) => using((arena) =>
        lib.takeString(lib.aiThumb(Pointer.fromAddress(a), json.toNativeUtf8(allocator: arena), size))));
  }

  /// Small JPEG (base64) of any image file, e.g. a reference photo for AI.
  static Future<String> thumbnailOf(String path, {int size = 768}) async {
    final s = await EngineSession.open(path, previewSize: size);
    try {
      return await s.aiThumbnail(const {}, size: size);
    } finally {
      await s.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _run((lib, a) => lib.close(Pointer.fromAddress(a)));
  }
}
