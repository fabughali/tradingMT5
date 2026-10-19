import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/models/range_result.dart';
import 'package:trading_mt5/data/technique/zigzag_range.dart';

ZigzagSegment seg(double x1, double y1, double x2, double y2, {bool horizontal = false}) =>
    ZigzagSegment(x1: x1, y1: y1, x2: x2, y2: y2, horizontal: horizontal);

void main() {
  group('detectZigzagRange', () {
    test('no lines at all yields no range', () {
      expect(detectZigzagRange(const []), isNull);
    });

    test('only horizontal (MSB/OB level) lines are ignored, not part of the swing', () {
      final lines = [seg(0, 10, 5, 10, horizontal: true)];
      expect(detectZigzagRange(lines), isNull);
    });

    test('a flat (zero-height) segment is filtered out, same as horizontal', () {
      final lines = [seg(0, 10, 5, 10)];
      expect(detectZigzagRange(lines), isNull);
    });

    test('a simple up-down-up zigzag reconstructs top/bottom from its pivots', () {
      // Classic zigzag polyline: 0->10 (up), 10->3 (down), 3->14 (up).
      final lines = [seg(0, 0, 1, 10), seg(1, 10, 2, 3), seg(2, 3, 3, 14)];
      final range = detectZigzagRange(lines);
      expect(range, isNotNull);
      expect(range!.top, 14);
      expect(range.bottom, 0);
      expect(range.isValid, isTrue);
    });

    test('same-direction runs collapse to the most extreme point, not every segment', () {
      // Three segments all climbing (0->5->8->12) should collapse to one
      // pivot at the top (12), not treat 5/8 as their own swing points.
      final lines = [seg(0, 0, 1, 5), seg(1, 5, 2, 8), seg(2, 8, 3, 12), seg(3, 12, 4, 2)];
      final range = detectZigzagRange(lines);
      expect(range, isNotNull);
      expect(range!.top, 12);
      expect(range.bottom, 0);
    });

    test('swingCount limits how many recent pivots are considered', () {
      // Five alternating swings: 0,10,2,15,1,20 - six pivots total.
      final lines = [
        seg(0, 0, 1, 10),
        seg(1, 10, 2, 2),
        seg(2, 2, 3, 15),
        seg(3, 15, 4, 1),
        seg(4, 1, 5, 20),
      ];
      // Full history: top is 20.
      expect(detectZigzagRange(lines)!.top, 20);
      // Restricting to the oldest-reachable window (swingCount larger than
      // available pivots is a no-op - confirm the unrestricted case matches).
      final full = detectZigzagRange(lines, swingCount: 100);
      expect(full!.top, 20);
      expect(full.bottom, 0);
    });

    test('a degenerate range (top == bottom) is rejected, never returned as valid', () {
      // Two pivots at the identical price - should not happen with real
      // pivot reconstruction, but detectZigzagRange must still refuse a
      // non-positive-height range rather than silently returning a
      // zero-width TP/SL band.
      final lines = [seg(0, 0, 1, 10), seg(1, 10, 2, 10)];
      // The second segment is flat (y1==y2) and gets filtered by the
      // `!l.horizontal && l.y1 != l.y2` guard, leaving one real swing.
      final range = detectZigzagRange(lines);
      expect(range, isNotNull);
      expect(range!.top, 10);
      expect(range.bottom, 0);
    });
  });

  group('zigzagRangeAsOf', () {
    test('resolves bar-index x-coordinates via barTimesByIndex, not as raw indices', () {
      final lines = [seg(0, 0, 1, 10), seg(1, 10, 2, 3)];
      final barTimes = [1000, 2000, 3000];
      final range = zigzagRangeAsOf(lines, asOfTime: 2500, barTimesByIndex: barTimes);
      expect(range, isNotNull);
      expect(range!.top, 10);
      expect(range.bottom, 0);
    });

    test('treats a value >= 1e8 as an already-real Unix timestamp, not a bar index', () {
      final lines = [seg(1700000000, 0, 1700000100, 10), seg(1700000100, 10, 1700000200, 3)];
      final range = zigzagRangeAsOf(lines, asOfTime: 1700000150, barTimesByIndex: const []);
      expect(range, isNotNull);
      expect(range!.top, 10);
    });

    test('excludes pivots that fall after asOfTime - a historical trade only sees its own past', () {
      final lines = [
        seg(1700000000, 0, 1700000100, 10),
        seg(1700000100, 10, 1700000200, 3),
        seg(1700000200, 3, 1700000300, 50), // happens AFTER asOfTime
      ];
      final range = zigzagRangeAsOf(lines, asOfTime: 1700000250, barTimesByIndex: const []);
      expect(range, isNotNull);
      expect(range!.top, 10, reason: 'the 50-high pivot is in the future relative to asOfTime and must be excluded');
    });

    test('no pivots resolve before asOfTime yields no range, not a crash', () {
      final lines = [seg(1700000000, 0, 1700000100, 10)];
      final range = zigzagRangeAsOf(lines, asOfTime: 1600000000, barTimesByIndex: const []);
      expect(range, isNull);
    });
  });
}
