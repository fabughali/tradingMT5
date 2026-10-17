import '../models/range_result.dart';

/// Shared pivot reconstruction - factored out (2026-10-17) so the backtest's
/// own [zigzagRangeAsOf] can reuse the EXACT same ZigZag logic
/// [detectZigzagRange] already uses live, rather than risking the two ever
/// drifting apart. See [detectZigzagRange]'s own doc comment for the
/// algorithm itself.
List<ZigzagPoint> _reconstructPivots(List<ZigzagSegment> lines) {
  final segs = lines.where((l) => !l.horizontal && l.y1 != l.y2).toList();
  if (segs.isEmpty) return const [];

  final pts = <ZigzagPoint>[];
  for (final s in segs) {
    pts.add(ZigzagPoint(s.x1, s.y1));
    pts.add(ZigzagPoint(s.x2, s.y2));
  }
  pts.sort((a, b) {
    final byX = a.x.compareTo(b.x);
    return byX != 0 ? byX : a.y.compareTo(b.y);
  });

  final series = <ZigzagPoint>[];
  for (final pt in pts) {
    final last = series.isEmpty ? null : series.last;
    if (last == null || last.x != pt.x || last.y != pt.y) series.add(pt);
  }
  if (series.length < 2) return const [];

  // ZigZag pivots: keep local extrema, collapsing same-direction runs into
  // the most extreme point of that run (a proper ZigZag reconstruction).
  final pivots = <ZigzagPoint>[];
  int dir = 0;
  for (var i = 1; i < series.length; i++) {
    final point = series[i];
    final prev = series[i - 1];
    final d = (point.y - prev.y).sign.toInt();
    if (d == 0) continue;
    if (dir == 0) {
      pivots.add(prev);
      pivots.add(point);
      dir = d;
      continue;
    }
    if (d == dir) {
      final lastPivot = pivots.last;
      if ((dir > 0 && point.y > lastPivot.y) ||
          (dir < 0 && point.y < lastPivot.y)) {
        pivots[pivots.length - 1] = point;
      }
    } else {
      pivots.add(prev);
      pivots.add(point);
      dir = d;
    }
  }

  final uniq = <ZigzagPoint>[];
  for (final pt in pivots) {
    final last = uniq.isEmpty ? null : uniq.last;
    if (last == null || last.x != pt.x || last.y != pt.y) uniq.add(pt);
  }
  return uniq;
}

/// The sole range rule, ported verbatim from tradingPionex (PRD §6.2): read
/// the Daily MSB/OB script's zigzag polyline (`dwg-lines`), reconstruct
/// swing pivots, take the last [swingCount] of them, top = max pivot,
/// bottom = min pivot. No label/box fallback — if this returns null, the
/// caller must skip the cycle, never fall back to a different range source.
RangeResult? detectZigzagRange(
  List<ZigzagSegment> lines, {
  int swingCount = 20,
}) {
  final uniq = _reconstructPivots(lines);
  if (uniq.isEmpty) return null;

  final recent = uniq.length > swingCount
      ? uniq.sublist(uniq.length - swingCount)
      : uniq;
  if (recent.isEmpty) return null;

  final top = recent.map((p) => p.y).reduce((a, b) => a > b ? a : b);
  final bottom = recent.map((p) => p.y).reduce((a, b) => a < b ? a : b);
  if (!(top > bottom)) return null;

  return RangeResult(top: top, bottom: bottom, pivotCount: recent.length);
}

/// Backtest-only: the SAME zigzag range rule, but as it would have read at
/// [asOfTime] (a real Unix-seconds timestamp) rather than today - a
/// historical trade's own TP/SL must be computed from whatever range was
/// actually confirmed as of ITS OWN open time, not the live/current one
/// (2026-10-17, per the user's backtester spec: "same broker rules same
/// mt5 rules").
///
/// [lines]' own x-coordinates are whatever unit the source drawing object
/// carries - bar index or bar time (see [ZigzagPoint]'s own doc comment,
/// confirmed ambiguous from the live Pine API itself). Resolved adaptively
/// rather than assumed: a value >= 1e8 is unambiguously already a real
/// Unix-seconds timestamp (bar indices never reach anywhere near that for
/// any realistic chart history); anything smaller is treated as a bar
/// index and looked up in [barTimesByIndex] (the same bar array the
/// backtest already pulled for its own OHLC price-path simulation, so no
/// extra chart read is needed here).
RangeResult? zigzagRangeAsOf(
  List<ZigzagSegment> lines, {
  required int asOfTime,
  required List<int> barTimesByIndex,
  int swingCount = 20,
}) {
  final pivots = _reconstructPivots(lines);
  if (pivots.isEmpty) return null;

  double resolveTime(double x) {
    if (x >= 1e8) return x;
    final i = x.round();
    if (i < 0 || i >= barTimesByIndex.length) return double.nan;
    return barTimesByIndex[i].toDouble();
  }

  final eligible = <ZigzagPoint>[];
  for (final p in pivots) {
    final t = resolveTime(p.x);
    if (!t.isNaN && t <= asOfTime) eligible.add(p);
  }
  if (eligible.isEmpty) return null;

  final recent = eligible.length > swingCount
      ? eligible.sublist(eligible.length - swingCount)
      : eligible;

  final top = recent.map((p) => p.y).reduce((a, b) => a > b ? a : b);
  final bottom = recent.map((p) => p.y).reduce((a, b) => a < b ? a : b);
  if (!(top > bottom)) return null;

  return RangeResult(top: top, bottom: bottom, pivotCount: recent.length);
}
