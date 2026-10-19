import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/sl_ratchet_ladder.dart';

void main() {
  group('highestSlRatchetThresholdCrossed', () {
    test('below the first rung returns null', () {
      expect(highestSlRatchetThresholdCrossed(-10), isNull);
      expect(highestSlRatchetThresholdCrossed(0), isNull);
      expect(highestSlRatchetThresholdCrossed(4.99), isNull);
    });

    test('exactly on a rung returns that rung', () {
      expect(highestSlRatchetThresholdCrossed(5), 5);
      expect(highestSlRatchetThresholdCrossed(10), 10);
      expect(highestSlRatchetThresholdCrossed(25), 25);
    });

    test('between rungs returns the highest one crossed, never rounds up', () {
      expect(highestSlRatchetThresholdCrossed(5.1), 5);
      expect(highestSlRatchetThresholdCrossed(9.99), 5);
      expect(highestSlRatchetThresholdCrossed(14.99), 10);
      expect(highestSlRatchetThresholdCrossed(18.48), 15); // real ALGOUSD.lv peak from the PRD's own history
    });

    test('keeps climbing past the documented table with no ceiling', () {
      expect(highestSlRatchetThresholdCrossed(97), 95);
      expect(highestSlRatchetThresholdCrossed(100), 100);
    });
  });

  group('slRatioForThreshold', () {
    test('the +5% rung is the one special case - locks to +2%, not 0%', () {
      expect(slRatioForThreshold(5), 2);
    });

    test('every rung from +10% on locks to threshold-5', () {
      expect(slRatioForThreshold(10), 5);
      expect(slRatioForThreshold(15), 10);
      expect(slRatioForThreshold(20), 15);
      expect(slRatioForThreshold(100), 95);
    });
  });
}
