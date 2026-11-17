import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// Design tokens: warm, soft and simple.
const accent = Color(0xFFFFA36C);
const accent2 = Color(0xFFFF6F91);
const accentGradient = LinearGradient(colors: [accent, accent2]);
const bgColor = Color(0xFF0E0E11);
const surfaceColor = Color(0xFF16161B);
const cardColor = Color(0xFF1F1F26);
const textDim = Color(0xFF9A9AA6);

/// Labeled slider. Double-tap the label to reset.
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
    final bipolar = track == null && reset > min && reset < max;
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        trackShape: const RoundedRectSliderTrackShape(),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8, elevation: 2),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: track == null && !bipolar ? accent : Colors.transparent,
        inactiveTrackColor: track == null && !bipolar ? Colors.white12 : Colors.transparent,
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
      padding: const EdgeInsets.symmetric(horizontal: 4),
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
                Text(shown,
                    style: TextStyle(
                        fontSize: 13,
                        color: (value - reset).abs() < 1e-6 ? textDim : accent,
                        fontFeatures: const [ui.FontFeature.tabularFigures()])),
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
          else if (bipolar)
            // Two-sided sliders fill from the middle toward the thumb.
            Stack(alignment: Alignment.center, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: CustomPaint(
                  size: const Size(double.infinity, 4),
                  painter: _CenterFillPainter((value.clamp(min, max) - min) / (max - min), (reset.clamp(min, max) - min) / (max - min)),
                ),
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

class _CenterFillPainter extends CustomPainter {
  _CenterFillPainter(this.t, this.origin);
  final double t, origin;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = Colors.white12);
    final a = origin * size.width, b = t * size.width;
    if ((a - b).abs() > 0.5) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(a < b ? a : b, 0, a < b ? b : a, size.height), r), Paint()..color = accent);
    }
    canvas.drawRect(Rect.fromLTWH(a - 1, -2, 2, size.height + 4), Paint()..color = Colors.white30);
  }

  @override
  bool shouldRepaint(_CenterFillPainter old) => old.t != t || old.origin != origin;
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

/// RGB + luminance histogram, Lightroom-style.
class HistogramView extends StatelessWidget {
  const HistogramView(this.data, {super.key, this.height = 72});
  final List<List<double>>? data;
  final double height;
  @override
  Widget build(BuildContext context) => Container(
        height: height,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        decoration: BoxDecoration(color: const Color(0xFF0E0E0E), borderRadius: BorderRadius.circular(6)),
        child: data == null ? null : CustomPaint(painter: _HistPainter(data!), size: Size.infinite),
      );
}

class _HistPainter extends CustomPainter {
  _HistPainter(this.h);
  final List<List<double>> h;
  @override
  void paint(Canvas canvas, Size size) {
    const colors = [Color(0x99FF4040), Color(0x9940FF40), Color(0x994080FF), Color(0x55FFFFFF)];
    for (var c = 0; c < 4; c++) {
      final path = Path()..moveTo(0, size.height);
      final n = h[c].length;
      for (var i = 0; i < n; i++) {
        path.lineTo(i / (n - 1) * size.width, size.height * (1 - h[c][i] * 0.95));
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()
        ..color = colors[c]
        ..blendMode = BlendMode.plus);
    }
  }

  @override
  bool shouldRepaint(_HistPainter old) => old.h != h;
}


/// Big look card: photo preview with the name over a soft gradient and a heart.
class LookCard extends StatelessWidget {
  const LookCard({
    super.key,
    required this.label,
    this.subtitle,
    this.image,
    this.selected = false,
    this.favorite,
    this.onTap,
    this.onFavorite,
    this.onDelete,
  });
  final String label;
  final String? subtitle;
  final ui.Image? image;
  final bool selected;
  final bool? favorite;
  final VoidCallback? onTap;
  final VoidCallback? onFavorite;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: selected ? accentGradient : null,
        color: selected ? null : Colors.transparent,
      ),
      padding: const EdgeInsets.all(2.5),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: cardColor),
          if (image != null) RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.transparent, Color(0xCC000000)],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 8,
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
          if (favorite != null)
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onFavorite,
                icon: Icon(favorite! ? Icons.favorite : Icons.favorite_border,
                    color: favorite! ? accent2 : Colors.white70,
                    shadows: const [Shadow(blurRadius: 6, color: Colors.black54)]),
              ),
            ),
          if (onDelete != null)
            Positioned(
              top: 2,
              left: 2,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: '삭제',
                onPressed: onDelete,
                icon: const Icon(Icons.close, color: Colors.white70, shadows: [Shadow(blurRadius: 6, color: Colors.black54)]),
              ),
            ),
        ]),
      ),
    );
    return Tooltip(
      message: subtitle ?? '',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, child: card)),
    );
  }
}

/// Collapsible rounded section used in the adjust tab.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.children,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
              child: Row(children: [
                Icon(icon, size: 20, color: accent),
                const SizedBox(width: 10),
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                ?trailing,
                Icon(open ? Icons.expand_less : Icons.expand_more, color: textDim),
              ]),
            ),
          ),
          if (open) ...children,
          if (open) const SizedBox(height: 10),
        ]),
      );
}

/// Pill button filled with the accent gradient.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, this.icon, this.onPressed});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(gradient: accentGradient, borderRadius: BorderRadius.circular(24)),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: Colors.black87), const SizedBox(width: 6)],
                  Text(label, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        ),
      );
}
