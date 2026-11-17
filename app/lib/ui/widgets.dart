import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const accent = Color(0xFF4DA3FF);

/// Lightroom-style labeled slider. Double-tap the label to reset.
class AdjustSlider extends StatelessWidget {
  const AdjustSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.min = -1,
    this.max = 1,
    this.reset = 0,
    this.display,
    this.track,
  });

  final String label;
  final double value;
  final double min, max, reset;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String Function(double)? display;
  final Gradient? track;

  @override
  Widget build(BuildContext context) {
    final shown = display?.call(value) ?? (value * 100).round().toString();
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: track == null ? accent : Colors.transparent,
        inactiveTrackColor: track == null ? Colors.white24 : Colors.transparent,
        thumbColor: Colors.white,
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onDoubleTap: () {
              onChanged(reset);
              onChangeEnd(reset);
            },
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, top: 6),
              child: Row(children: [
                Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                const Spacer(),
                Text(shown, style: const TextStyle(fontSize: 13, color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()])),
              ]),
            ),
          ),
          if (track != null)
            Stack(alignment: Alignment.center, children: [
              Container(
                height: 4,
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(gradient: track, borderRadius: BorderRadius.circular(2)),
              ),
              slider,
            ])
          else
            slider,
        ],
      ),
    );
  }
}

const hueGradient = LinearGradient(colors: [
  Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00), Color(0xFF00FFFF),
  Color(0xFF0000FF), Color(0xFFFF00FF), Color(0xFFFF0000),
]);
const tempGradient = LinearGradient(colors: [Color(0xFF3B7BFF), Color(0xFFDDDDDD), Color(0xFFFFB23B)]);
const tintGradient = LinearGradient(colors: [Color(0xFF3BD14A), Color(0xFFDDDDDD), Color(0xFFE23BE0)]);

/// Thumbnail tile used for templates and auto candidates.
class ThumbTile extends StatelessWidget {
  const ThumbTile({super.key, required this.label, this.image, this.selected = false, this.onTap, this.onLongPress});
  final String label;
  final ui.Image? image;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Container(
        width: 96,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(children: [
          Container(
            height: 96,
            decoration: BoxDecoration(
              border: Border.all(color: selected ? accent : Colors.transparent, width: 2),
              borderRadius: BorderRadius.circular(6),
              color: Colors.white10,
            ),
            clipBehavior: Clip.antiAlias,
            child: image == null
                ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : RawImage(image: image, fit: BoxFit.cover),
          ),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: selected ? accent : Colors.white70)),
        ]),
      ),
    );
  }
}

/// Tone curve editor: drag points, tap to add, double-tap a point to remove.
class CurveEditor extends StatefulWidget {
  const CurveEditor({super.key, required this.points, required this.onChanged, required this.onChangeEnd, this.color = Colors.white});
  final List<List<double>> points;
  final ValueChanged<List<List<double>>> onChanged;
  final ValueChanged<List<List<double>>> onChangeEnd;
  final Color color;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor> {
  int? _drag;

  List<List<double>> get _pts =>
      widget.points.length >= 2 ? widget.points.map((p) => [p[0], p[1]]).toList() : [[0.0, 0.0], [1.0, 1.0]];

  Offset _toLocal(List<double> p, Size s) => Offset(p[0] * s.width, (1 - p[1]) * s.height);
  List<double> _fromLocal(Offset o, Size s) =>
      [(o.dx / s.width).clamp(0.0, 1.0), (1 - o.dy / s.height).clamp(0.0, 1.0)];

  int? _hit(Offset o, Size s) {
    final pts = _pts;
    for (var i = 0; i < pts.length; i++) {
      if ((_toLocal(pts[i], s) - o).distance < 18) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          onTapUp: (d) {
            if (_hit(d.localPosition, size) != null) return;
            final pts = _pts..add(_fromLocal(d.localPosition, size));
            pts.sort((a, b) => a[0].compareTo(b[0]));
            widget.onChangeEnd(pts);
          },
          onDoubleTapDown: (d) {
            final i = _hit(d.localPosition, size);
            final pts = _pts;
            if (i != null && i != 0 && i != pts.length - 1) {
              pts.removeAt(i);
              widget.onChangeEnd(pts);
            }
          },
          onPanStart: (d) => _drag = _hit(d.localPosition, size),
          onPanUpdate: (d) {
            final i = _drag;
            if (i == null) return;
            final pts = _pts;
            var p = _fromLocal(d.localPosition, size);
            final lo = i == 0 ? 0.0 : pts[i - 1][0] + 0.01;
            final hi = i == pts.length - 1 ? 1.0 : pts[i + 1][0] - 0.01;
            p = [p[0].clamp(lo, math.max(lo, hi)), p[1]];
            pts[i] = p;
            widget.onChanged(pts);
          },
          onPanEnd: (_) {
            if (_drag != null) widget.onChangeEnd(_pts);
            _drag = null;
          },
          child: CustomPaint(painter: _CurvePainter(_pts, widget.color), size: size),
        );
      }),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.pts, this.color);
  final List<List<double>> pts;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final x = s.width * i / 4, y = s.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, s.height), grid);
      canvas.drawLine(Offset(0, y), Offset(s.width, y), grid);
    }
    canvas.drawLine(Offset(0, s.height), Offset(s.width, 0), grid..color = Colors.white24);
    // Catmull-Rom-ish preview (engine uses monotone cubic; close enough for display).
    final path = Path();
    for (var i = 0; i <= 100; i++) {
      final x = i / 100;
      final y = _interp(x);
      final o = Offset(x * s.width, (1 - y) * s.height);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    for (final p in pts) {
      canvas.drawCircle(Offset(p[0] * s.width, (1 - p[1]) * s.height), 6, Paint()..color = color);
    }
  }

  double _interp(double x) {
    if (x <= pts.first[0]) return pts.first[1];
    if (x >= pts.last[0]) return pts.last[1];
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i], b = pts[i + 1];
      if (x >= a[0] && x <= b[0]) {
        final t = (x - a[0]) / math.max(1e-6, b[0] - a[0]);
        final tt = t * t * (3 - 2 * t);
        return a[1] + (b[1] - a[1]) * tt;
      }
    }
    return x;
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) => true;
}
