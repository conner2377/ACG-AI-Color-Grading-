import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

const accent = AppColors.accent;

/// Labeled slider whose fill grows from its neutral point (0 for most adjustments),
/// so you can see at a glance which way and how far something was pushed.
/// Double-tap anywhere on the row to reset.
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
    final shown = display?.call(value) ?? _defaultDisplay(value);
    final changed = (value - reset).abs() > 1e-4;
    final origin = ((reset - min) / (max - min)).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTap: () {
        onChanged(reset);
        onChangeEnd(reset);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(label,
                style: TextStyle(
                  fontSize: 13,
                  color: changed ? AppColors.text : AppColors.textDim,
                  fontWeight: changed ? FontWeight.w600 : FontWeight.w400,
                )),
            const Spacer(),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 150),
              style: TextStyle(
                fontSize: 12.5,
                color: changed ? AppColors.accent : AppColors.textFaint,
                fontWeight: FontWeight.w600,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
              child: Text(shown),
            ),
          ]),
          SizedBox(
            height: 30,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: track == null ? 4 : 6,
                trackShape: _OriginTrackShape(origin, track),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8, elevation: 3, pressedElevation: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                overlayColor: AppColors.accent.withValues(alpha: 0.16),
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: AppColors.surface3,
                thumbColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  static String _defaultDisplay(double v) {
    final n = (v * 100).round();
    return n > 0 ? '+$n' : '$n';
  }
}

class _OriginTrackShape extends RoundedRectSliderTrackShape {
  const _OriginTrackShape(this.origin, this.gradient);
  final double origin;
  final Gradient? gradient;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final canvas = context.canvas;
    final r = Radius.circular(rect.height / 2);
    final base = Paint()..color = sliderTheme.inactiveTrackColor ?? AppColors.surface3;
    if (gradient != null) base.shader = gradient!.createShader(rect);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, r), base);
    if (gradient != null) return;
    final ox = rect.left + rect.width * origin;
    final a = math.min(ox, thumbCenter.dx), b = math.max(ox, thumbCenter.dx);
    if (b - a > 0.5) {
      canvas.drawRRect(
        RRect.fromLTRBR(a, rect.top, b, rect.bottom, r),
        Paint()..shader = accentGradient.createShader(Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom)),
      );
    }
    if (origin > 0.01 && origin < 0.99) {
      canvas.drawCircle(Offset(ox, rect.center.dy), 2, Paint()..color = AppColors.textFaint);
    }
  }
}

const hueGradient = LinearGradient(colors: [
  Color(0xFFFF4D4D), Color(0xFFFFE14D), Color(0xFF4DFF6A), Color(0xFF4DE8FF),
  Color(0xFF4D6BFF), Color(0xFFE84DFF), Color(0xFFFF4D4D),
]);
const tempGradient = LinearGradient(colors: [Color(0xFF5B8CFF), Color(0xFFD9D9E0), Color(0xFFFFB347)]);
const tintGradient = LinearGradient(colors: [Color(0xFF54D16A), Color(0xFFD9D9E0), Color(0xFFE25BD8)]);

/// Photo card used for templates, auto candidates and AI variations: the look itself
/// is the button, with its name laid over the bottom of the picture.
class ThumbTile extends StatelessWidget {
  const ThumbTile({
    super.key,
    required this.label,
    this.image,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.size = 104,
    this.badge,
  });
  final String label;
  final ui.Image? image;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double size;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: size,
          height: size,
          padding: EdgeInsets.all(selected ? 2.5 : 0),
          decoration: BoxDecoration(
            gradient: selected ? accentGradient : null,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(selected ? 13.5 : 16),
            child: Stack(fit: StackFit.expand, children: [
              Container(color: AppColors.surface2),
              if (image == null)
                const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
              else
                RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 18, 8, 7),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xCC000000)],
                    ),
                  ),
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
              if (badge != null)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(gradient: accentGradient, borderRadius: BorderRadius.circular(8)),
                    child: Text(badge!, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (selected)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(gradient: accentGradient, shape: BoxShape.circle),
                    child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Primary call-to-action with the accent gradient.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, required this.onPressed, this.icon, this.expand = false, this.height = 44});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: accentGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: enabled
              ? [BoxShadow(color: AppColors.accent2.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 6))]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: SizedBox(
              height: height,
              width: expand ? double.infinity : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: Colors.white), const SizedBox(width: 8)],
                  Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented pill selector (sub-tabs inside a mode).
class PillTabs extends StatelessWidget {
  const PillTabs({super.key, required this.labels, required this.index, required this.onChanged});
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == index ? AppColors.surface3 : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: i == index ? const [BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2))] : null,
                  ),
                  child: Text(labels[i],
                      style: TextStyle(
                        fontSize: 12.5,
                        color: i == index ? AppColors.text : AppColors.textDim,
                        fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                      )),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Soft rounded block that groups related controls.
class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.title, this.icon, this.trailing, this.padding = const EdgeInsets.fromLTRB(0, 14, 0, 14)});
  final Widget child;
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: padding,
      decoration: BoxDecoration(color: AppColors.surface2.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 12, 6),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 16, color: AppColors.accent), const SizedBox(width: 8)],
              Expanded(child: Text(title!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.text))),
              ?trailing,
            ]),
          ),
        child,
      ]),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 11.5, letterSpacing: 0.4, color: AppColors.textFaint, fontWeight: FontWeight.w700)),
          ),
          ?trailing,
        ]),
      );
}

class HintText extends StatelessWidget {
  const HintText(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        child: Text(text, style: const TextStyle(color: AppColors.textFaint, fontSize: 12, height: 1.45)),
      );
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
        margin: const EdgeInsets.fromLTRB(20, 4, 20, 4),
        decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(14)),
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
