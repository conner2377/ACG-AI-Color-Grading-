// Saved work per photo: the latest edit is kept automatically, and the user can save
// named versions at any time (Ctrl+S) and bring them back later. Stored as small JSON
// files in the app's data folder, never next to the user's photos.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class SavedWork {
  SavedWork(this.name, this.time, this.recipe);
  final String name;
  final DateTime time;
  final Map<String, dynamic> recipe;

  Map<String, dynamic> toJson() => {'name': name, 'time': time.toIso8601String(), 'recipe': recipe};
  static SavedWork fromJson(Map<String, dynamic> j) => SavedWork(
        j['name'] as String? ?? '저장한 작업',
        DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
        (j['recipe'] as Map).cast<String, dynamic>(),
      );
}

class WorkStore {
  static Directory get dir {
    final base = Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path)
        : p.join(Platform.environment['HOME'] ?? Directory.systemTemp.path, '.config');
    return Directory(p.join(base, 'ACG', 'edits'));
  }

  static File _file(String photo) {
    final h = photo.toLowerCase().codeUnits.fold<int>(0x811c9dc5, (h, c) => ((h ^ c) * 0x01000193) & 0xFFFFFFFF);
    return File(p.join(dir.path, '${h.toRadixString(16).padLeft(8, '0')}_${p.basenameWithoutExtension(photo)}.json'));
  }

  static Future<Map<String, dynamic>> _read(String photo) async {
    try {
      final f = _file(photo);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        if (j['path'] == photo) return j;
      }
    } catch (_) {}
    return {'path': photo, 'saved': <dynamic>[]};
  }

  static Future<void> _write(String photo, Map<String, dynamic> j) async {
    try {
      await dir.create(recursive: true);
      j['path'] = photo;
      await _file(photo).writeAsString(jsonEncode(j));
    } catch (_) {}
  }

  /// The edit that was on screen last time (autosaved), if any.
  static Future<Map<String, dynamic>?> current(String photo) async {
    final c = (await _read(photo))['current'];
    return c is Map ? c.cast<String, dynamic>() : null;
  }

  static Future<void> autosave(String photo, Map<String, dynamic> recipe) async {
    final j = await _read(photo);
    j['current'] = recipe;
    j['updated'] = DateTime.now().toIso8601String();
    await _write(photo, j);
  }

  static Future<List<SavedWork>> saved(String photo) async {
    final list = (await _read(photo))['saved'] as List? ?? const [];
    return [for (final e in list.whereType<Map>()) SavedWork.fromJson(e.cast<String, dynamic>())]
      ..sort((a, b) => b.time.compareTo(a.time));
  }

  static Future<void> save(String photo, String name, Map<String, dynamic> recipe) async {
    final j = await _read(photo);
    final list = [...(j['saved'] as List? ?? const []), SavedWork(name, DateTime.now(), recipe).toJson()];
    j['saved'] = list;
    j['current'] = recipe;
    await _write(photo, j);
  }

  static Future<void> delete(String photo, SavedWork w) async {
    final j = await _read(photo);
    j['saved'] = [
      for (final e in (j['saved'] as List? ?? const []).whereType<Map>())
        if (!(e['name'] == w.name && e['time'] == w.time.toIso8601String())) e
    ];
    await _write(photo, j);
  }
}
