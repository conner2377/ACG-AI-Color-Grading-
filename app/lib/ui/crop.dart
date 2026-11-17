// Crop & straighten: an overlay on the (uncropped) preview with a draggable crop
// rectangle and rule-of-thirds grid, plus a panel with aspect ratios, straighten,
// 90° rotation and flips. All of it only edits recipe values (lossless).

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'widgets.dart';

List<double> cropOf(Map<String, dynamic> r) {
  final c = r['crop'];
  if (c is List && c.length == 4) return [for (final v in c) (v as num).toDouble()];
  return [0, 0, 1, 1];
}

/// Largest centered crop of pixel aspect [aspect] (w/h) in an image of [iw]x[ih].
List<double> centeredCrop(double aspect, int iw, int ih) {
  final na = aspect * ih / iw; // normalized w/h
  var w = 1.0, h = 1.0;
  if (na >= 1) {
    h = 1 / na;
  } else {
    w = na;
  }
  return [(1 - w) / 2, (1 - h) / 2, w, h];
}

class CropOverlay extends StatefulWidget {
  const CropOverlay({super.key, required this.c, required this.image});
  final EditorController c;
  final ui.Image image;
  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  int _mode = -1; // 0..3 corners (TL, TR, BR, BL), 4 = move
  late List<double> _start;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
      final scale = math.min(box.maxWidth / iw, box.maxHeight / ih);
      final dw = iw * scale, dh = ih * scale;
      final ox = (box.maxWidth - dw) / 2, oy = (box.maxHeight - dh) / 2;
      final crop = cropOf(widget.c.recipe);
      final rect = Rect.fromLTWH(ox + crop[0] * dw, oy + crop[1] * dh, crop[2] * dw, crop[3] * dh);

      void start(Offset p) {
        final corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft];
        _mode = -1;
        for (var i = 0; i < 4; i++) {
          if ((corners[i] - p).distance < 28) _mode = i;
        }
        if (_mode < 0 && rect.inflate(4).contains(p)) _mode = 4;
        _start = crop;
      }

      void update(Offset delta, {bool commit = false}) {
        if (_mode < 0) return;
        var [x, y, w, h] = cropOf(widget.c.recipe);
        final dx = delta.dx / dw, dy = delta.dy / dh;
        if (_mode == 4) {
          x = (x + dx).clamp(0.0, 1 - w);
          y = (y + dy).clamp(0.0, 1 - h);
        } else {
          var x0 = x, y0 = y, x1 = x + w, y1 = y + h;
          if (_mode == 0 || _mode == 3) x0 = (x0 + dx).clamp(0.0, x1 - 0.05);
          if (_mode == 1 || _mode == 2) x1 = (x1 + dx).clamp(x0 + 0.05, 1.0);
          if (_mode == 0 || _mode == 1) y0 = (y0 + dy).clamp(0.0, y1 - 0.05);
          if (_mode == 2 || _mode == 3) y1 = (y1 + dy).clamp(y0 + 0.05, 1.0);
          final aspect = widget.c.cropAspect;
          if (aspect != null) {
            // Keep the ratio, anchored at the opposite corner.
            final na = aspect * ih / iw;
            var nw = x1 - x0, nh = nw / na;
            final maxH = (_mode == 0 || _mode == 1) ? y1 : 1 - y0;
            if (nh > maxH) {
              nh = maxH;
              nw = nh * na;
            }
            if (_mode == 0 || _mode == 3) {
              x0 = x1 - nw;
            } else {
              x1 = x0 + nw;
            }
            if (_mode == 0 || _mode == 1) {
              y0 = y1 - nh;
            } else {
              y1 = y0 + nh;
            }
          }
          x = x0;
          y = y0;
          w = x1 - x0;
          h = y1 - y0;
        }
        widget.c.editGeometry((r) => r['crop'] = [x, y, w, h], commit: commit);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => start(d.localPosition),
        onPanUpdate: (d) => update(d.delta),
        onPanEnd: (_) {
          if (_mode >= 0 && cropOf(widget.c.recipe).join() != _start.join()) widget.c.commitHistory();
          _mode = -1;
        },
        child: CustomPaint(
          size: Size(box.maxWidth, box.maxHeight),
          painter: _CropPainter(rect, Rect.fromLTWH(ox, oy, dw, dh)),
        ),
      );
    });
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect, this.image);
  final Rect rect;
  final Rect image;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(image), Path()..addRect(rect)),
      dim,
    );
    final line = Paint()
      ..color = Colors.white70
      ..strokeWidth = 0.7;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3, y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), line);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), line);
    }
    canvas.drawRect(rect, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
    final h = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square;
    const l = 18.0;
    for (final (c, sx, sy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomRight, -1.0, -1.0),
      (rect.bottomLeft, 1.0, -1.0),
    ]) {
      canvas.drawLine(c, c + Offset(l * sx, 0), h);
      canvas.drawLine(c, c + Offset(0, l * sy), h);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect || old.image != image;
}

class CropPanel extends StatelessWidget {
  const CropPanel(this.c, {super.key});
  final EditorController c;

  static const ratios = <String, double?>{
    '자유': null,
    '원본': -1,
    '1:1': 1,
    '4:5': 4 / 5,
    '3:4': 3 / 4,
    '2:3': 2 / 3,
    '9:16': 9 / 16,
    '16:9': 16 / 9,
    '3:2': 3 / 2,
    '4:3': 4 / 3,
  };

  void _setRatio(String key) {
    final img = c.preview;
    if (img == null) return;
    var a = ratios[key];
    if (a == -1) a = img.width / img.height;
    c.cropAspect = a;
    c.cropAspectLabel = key;
    if (a == null) {
      c.touch();
      return;
    }
    c.editGeometry((r) => r['crop'] = centeredCrop(a!, img.width, img.height), commit: true);
  }

  void _rotate(int d) {
    c.editGeometry((r) {
      r['rotate90'] = (((r['rotate90'] as num?)?.toInt() ?? 0) + d) % 4;
      r.remove('crop');
    }, commit: true);
    c.cropAspect = null;
    c.cropAspectLabel = '자유';
  }

  @override
  Widget build(BuildContext context) {
    final angle = (c.recipe['angle'] as num?)?.toDouble() ?? 0;
    return ListView(padding: const EdgeInsets.symmetric(vertical: 12), children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final k in ratios.keys)
            ChoiceChip(
              label: Text(k, style: const TextStyle(fontSize: 12)),
              selected: c.cropAspectLabel == k,
              onSelected: (_) => _setRatio(k),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      AdjustSlider(
        label: '수평 맞추기',
        value: angle,
        min: -45,
        max: 45,
        display: (v) => '${v.toStringAsFixed(1)}°',
        onChanged: (v) => c.editGeometry((r) => r['angle'] = (v * 10).round() / 10),
        onChangeEnd: (_) => c.commitHistory(),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Wrap(spacing: 4, children: [
          IconButton(tooltip: '왼쪽으로 90° 회전', onPressed: () => _rotate(3), icon: const Icon(Icons.rotate_left)),
          IconButton(tooltip: '오른쪽으로 90° 회전', onPressed: () => _rotate(1), icon: const Icon(Icons.rotate_right)),
          IconButton(
            tooltip: '좌우 반전',
            onPressed: () => c.editGeometry((r) => r['flip_h'] = !(r['flip_h'] == true), commit: true),
            icon: const Icon(Icons.flip),
          ),
          IconButton(
            tooltip: '상하 반전',
            onPressed: () => c.editGeometry((r) => r['flip_v'] = !(r['flip_v'] == true), commit: true),
            icon: Transform.rotate(angle: math.pi / 2, child: const Icon(Icons.flip)),
          ),
          TextButton(
            onPressed: () {
              c.cropAspect = null;
              c.cropAspectLabel = '자유';
              c.editGeometry((r) {
                for (final k in ['crop', 'angle', 'rotate90', 'flip_h', 'flip_v']) {
                  r.remove(k);
                }
              }, commit: true);
            },
            child: const Text('자르기 초기화'),
          ),
        ]),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text('사진 위 모서리를 끌어 크기를, 안쪽을 끌어 위치를 바꿉니다. 다른 도구로 가면 잘린 결과가 보여요.',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    ]);
  }
}
