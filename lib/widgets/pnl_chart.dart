import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/identity/pnl_series_store.dart';

/// P&L over a trade's life (2026-10-25, per the user: "build something like
/// that chart where you show P&L chart"). Plots P&L % when every point has
/// one, otherwise P&L in $; area above 0 green, below 0 red, dotted 0 line,
/// max/0/min on the right, times along the bottom.
class PnlChart extends StatelessWidget {
  const PnlChart({super.key, required this.points, this.height = 150});

  final List<PnlPoint> points;
  final double height;

  bool get _usePercent => points.isNotEmpty && points.every((p) => p.percent != null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (points.length < 2) {
      return SizedBox(
        height: 40,
        child: Center(
          child: Text(
            'P&L chart: not enough samples yet',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _PnlPainter(
          points: points,
          usePercent: _usePercent,
          up: Colors.green.shade600,
          down: Colors.red.shade600,
          axis: scheme.outline,
          text: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 10) ??
              const TextStyle(fontSize: 10),
        ),
      ),
    );
  }
}

class _PnlPainter extends CustomPainter {
  _PnlPainter({
    required this.points,
    required this.usePercent,
    required this.up,
    required this.down,
    required this.axis,
    required this.text,
  });

  final List<PnlPoint> points;
  final bool usePercent;
  final Color up;
  final Color down;
  final Color axis;
  final TextStyle text;

  double _v(PnlPoint p) => usePercent ? p.percent! : p.profit;

  String _fmt(double v) {
    final sign = v > 0 ? '+' : '';
    return usePercent ? '$sign${v.toStringAsFixed(1)} %' : '$sign\$${v.toStringAsFixed(2)}';
  }

  String _time(int epoch) {
    final d = DateTime.fromMillisecondsSinceEpoch(epoch * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  void _label(Canvas canvas, String s, Offset at, {bool right = false, bool center = false}) {
    final tp = TextPainter(text: TextSpan(text: s, style: text), textDirection: TextDirection.ltr)..layout();
    final dx = right ? at.dx - tp.width : center ? at.dx - tp.width / 2 : at.dx;
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const labelW = 52.0;
    const labelH = 16.0;
    final plot = Rect.fromLTWH(0, 6, size.width - labelW, size.height - labelH - 6);

    final t0 = points.first.time;
    final t1 = math.max(points.last.time, t0 + 1);
    var maxV = points.map(_v).reduce(math.max);
    var minV = points.map(_v).reduce(math.min);
    maxV = math.max(maxV, 0);
    minV = math.min(minV, 0);
    if (maxV - minV < 1e-9) {
      maxV += 1;
      minV -= 1;
    }
    final pad = (maxV - minV) * 0.08;
    maxV += pad;
    minV -= pad;

    double x(int t) => plot.left + (t - t0) / (t1 - t0) * plot.width;
    double y(double v) => plot.top + (maxV - v) / (maxV - minV) * plot.height;
    final zeroY = y(0);

    final line = Path()..moveTo(x(points.first.time), y(_v(points.first)));
    for (final p in points.skip(1)) {
      line.lineTo(x(p.time), y(_v(p)));
    }
    final area = Path.from(line)
      ..lineTo(x(points.last.time), zeroY)
      ..lineTo(x(points.first.time), zeroY)
      ..close();

    void fillClipped(Rect clip, Color c) {
      canvas.save();
      canvas.clipRect(clip);
      canvas.drawPath(area, Paint()..color = c.withValues(alpha: 0.18));
      canvas.drawPath(
        line,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      canvas.restore();
    }

    fillClipped(Rect.fromLTRB(plot.left, plot.top - 6, plot.right, zeroY), up);
    fillClipped(Rect.fromLTRB(plot.left, zeroY, plot.right, plot.bottom + 6), down);

    // Dotted zero line.
    final dash = Paint()
      ..color = axis
      ..strokeWidth = 1;
    for (var dx = plot.left; dx < plot.right; dx += 6) {
      canvas.drawLine(Offset(dx, zeroY), Offset(math.min(dx + 3, plot.right), zeroY), dash);
    }

    final lx = size.width - 2;
    _label(canvas, _fmt(maxV - pad), Offset(lx, y(maxV - pad)), right: true);
    _label(canvas, usePercent ? '0.0 %' : '\$0', Offset(lx, zeroY), right: true);
    _label(canvas, _fmt(minV + pad), Offset(lx, y(minV + pad)), right: true);

    final lastY = y(_v(points.last));
    canvas.drawCircle(
      Offset(x(points.last.time), lastY),
      3,
      Paint()..color = _v(points.last) >= 0 ? up : down,
    );

    final by = size.height - labelH / 2;
    for (var i = 0; i < 4; i++) {
      final t = t0 + ((t1 - t0) * i / 3).round();
      final px = x(t);
      if (i == 0) {
        _label(canvas, _time(t), Offset(px, by));
      } else if (i == 3) {
        _label(canvas, _time(t), Offset(px, by), right: true);
      } else {
        _label(canvas, _time(t), Offset(px, by), center: true);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PnlPainter old) =>
      old.points.length != points.length ||
      (points.isNotEmpty && old.points.isNotEmpty && old.points.last.profit != points.last.profit);
}
