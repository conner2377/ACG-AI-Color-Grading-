import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// Design tokens: a soft, slightly violet-tinted dark UI with one violet accent.
// Camera details (aperture mark, viewfinder corners, AF-point selection, dial ticks)
// are used sparingly as accents, not as decoration everywhere.
const accent = Color(0xFF8B6CFF);
const accentDim = Color(0x298B6CFF);
const accent2 = Color(0xFF6E4BFF);
const accentGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF9B7DFF), Color(0xFF6E4BFF)],
);
const bgColor = Color(0xFF0B0B0F);
const surfaceColor = Color(0xFF121218);
const cardColor = Color(0xFF1A1A22);
const borderColor = Color(0xFF25252F);
const textDim = Color(0xFF8E8E9E);
const onAccent = Color(0xFFFFFFFF);
const plateGradient = LinearGradient(colors: [surfaceColor, surfaceColor]);
const radius = 12.0;

/// EVF-style readout text (slider values, counters).
const readout = TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: ['Menlo', 'DejaVu Sans Mono', 'monospace'],
  fontFeatures: [ui.FontFeature.tabularFigures()],
);

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
    final t = (value.clamp(min, max) - min) / (max - min);
    final origin = bipolar ? (reset.clamp(min, max) - min) / (max - min) : 0.0;
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        trackShape: const RoundedRectSliderTrackShape(),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5, elevation: 0),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
        overlayColor: accentDim,
        activeTrackColor: Colors.transparent,
        inactiveTrackColor: Colors.transparent,
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
                Text(label, style: TextStyle(fontSize: 12.5, color: (value - reset).abs() < 1e-6 ? Colors.white70 : Colors.white)),
                const Spacer(),
                Text(shown, style: readout.copyWith(fontSize: 12.5, color: (value - reset).abs() < 1e-6 ? textDim : accent)),
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
            // Dial-style scale: fine ticks under a hairline track, filled from the
            // origin (center for two-sided sliders) toward the thumb.
            Stack(alignment: Alignment.center, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: CustomPaint(size: const Size(double.infinity, 12), painter: _ScalePainter(t, origin)),
              ),
              slider,
            ]),
        ],
      ),
    );
  }
}

class _ScalePainter extends CustomPainter {
  _ScalePainter(this.t, this.origin);
  final double t, origin;
  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, mid - 1.5, size.width, 3), const Radius.circular(2)),
        Paint()..color = Colors.white10);
    final tick = Paint()
      ..color = const Color(0x40FFFFFF)
      ..strokeWidth = 1;
    const n = 20;
    for (var i = 0; i <= n; i++) {
      final x = size.width * i / n;
      final major = i % 5 == 0;
      canvas.drawLine(Offset(x, mid + 3), Offset(x, mid + (major ? 7 : 5)), tick);
    }
    final a = origin * size.width, b = t * size.width;
    if ((a - b).abs() > 0.5) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(a < b ? a : b, mid - 1.5, a < b ? b : a, mid + 1.5), const Radius.circular(2)),
          Paint()..color = accent);
    }
    if (origin > 0) canvas.drawRect(Rect.fromLTWH(a - 0.75, mid - 5, 1.5, 4), Paint()..color = Colors.white54);
  }

  @override
  bool shouldRepaint(_ScalePainter old) => old.t != t || old.origin != origin;
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
              borderRadius: BorderRadius.circular(10),
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
        decoration: BoxDecoration(color: const Color(0xFF0E0E0E), borderRadius: BorderRadius.circular(10)),
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


/// Look tile (LUT-list style): preview with the name underneath, a favorite heart.
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
    final tile = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? accent : Colors.transparent, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(fit: StackFit.expand, children: [
            if (image != null)
              RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium)
            else
              const Center(child: ApertureSpinner(size: 16)),
            // Selected look: an AF point locked on it.
            if (selected) const FrameCorners(color: Colors.white, length: 10, width: 2, inset: 5),
            if (favorite != null && (favorite! || onFavorite != null))
              Positioned(
                top: 0,
                right: 0,
                child: _TinyIcon(
                  icon: favorite! ? Icons.favorite : Icons.favorite_border,
                  color: favorite! ? accent : Colors.white70,
                  onTap: onFavorite,
                ),
              ),
            if (onDelete != null)
              Positioned(top: 0, left: 0, child: _TinyIcon(icon: Icons.close, color: Colors.white70, onTap: onDelete)),
          ]),
        ),
      ),
      const SizedBox(height: 4),
      Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: selected ? accent : Colors.white70, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
    ]);
    return Tooltip(
      message: subtitle ?? '',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, child: tile)),
    );
  }
}

class _TinyIcon extends StatelessWidget {
  const _TinyIcon({required this.icon, required this.color, this.onTap});
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
          child: Icon(icon, size: 13, color: color),
        ),
      );
}

/// Small uppercase-like group label used in panels.
class PanelLabel extends StatelessWidget {
  const PanelLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 4),
        child: Row(children: [
          Text(text, style: const TextStyle(color: Color(0xFFA9ABB1), fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
          const SizedBox(width: 8),
          const Expanded(child: Divider(color: borderColor, height: 1)),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      );
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

/// Primary button: violet gradient, rounded.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, this.icon, this.onPressed});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return Opacity(
      opacity: on ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: accentGradient,
          borderRadius: BorderRadius.circular(10),
          boxShadow: on ? const [BoxShadow(color: Color(0x406E4BFF), blurRadius: 16, offset: Offset(0, 4))] : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[Icon(icon, size: 17, color: Colors.white), const SizedBox(width: 8)],
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white, fontSize: 13.5)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ camera details

/// Aperture iris: a ring with six blades. Used as the logo and (spinning) as the
/// loading indicator.
class ApertureMark extends StatelessWidget {
  const ApertureMark({super.key, this.size = 24, this.filled = true});
  final double size;
  final bool filled;
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: _AperturePainter(filled)));
}

class _AperturePainter extends CustomPainter {
  _AperturePainter(this.filled);
  final bool filled;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    if (filled) canvas.drawCircle(c, r, Paint()..shader = accentGradient.createShader(rect));
    final line = Paint()
      ..color = filled ? Colors.white : accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, r * 0.11)
      ..strokeCap = StrokeCap.round;
    final inner = r * 0.62;
    if (!filled) canvas.drawCircle(c, r - line.strokeWidth / 2, line);
    // Six blades: each a chord from the inner hexagon out toward the rim.
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3 - math.pi / 2;
      final p0 = c + Offset(math.cos(a), math.sin(a)) * inner * 0.55;
      final p1 = c + Offset(math.cos(a + 0.9), math.sin(a + 0.9)) * inner;
      canvas.drawLine(p0, p1, line);
    }
  }

  @override
  bool shouldRepaint(_AperturePainter old) => old.filled != filled;
}

/// Spinning aperture used for "working…" states.
class ApertureSpinner extends StatefulWidget {
  const ApertureSpinner({super.key, this.size = 16});
  final double size;
  @override
  State<ApertureSpinner> createState() => _ApertureSpinnerState();
}

class _ApertureSpinnerState extends State<ApertureSpinner> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: _c, child: ApertureMark(size: widget.size, filled: false));
}

/// Viewfinder / AF-point corner brackets drawn inside a box.
class FrameCorners extends StatelessWidget {
  const FrameCorners({super.key, this.color = Colors.white38, this.length = 14, this.width = 1.5, this.inset = 0});
  final Color color;
  final double length;
  final double width;
  final double inset;
  @override
  Widget build(BuildContext context) =>
      IgnorePointer(child: CustomPaint(painter: _CornersPainter(color, length, width, inset), size: Size.infinite));
}

class _CornersPainter extends CustomPainter {
  _CornersPainter(this.color, this.length, this.width, this.inset);
  final Color color;
  final double length, width, inset;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final r = (Offset.zero & size).deflate(inset + width / 2);
    final l = math.min(length, r.shortestSide / 3);
    for (final (o, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawPath(
          Path()
            ..moveTo(o.dx + l * dx, o.dy)
            ..lineTo(o.dx, o.dy)
            ..lineTo(o.dx, o.dy + l * dy),
          p);
    }
  }

  @override
  bool shouldRepaint(_CornersPainter old) => old.color != color || old.length != length || old.inset != inset;
}
