import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/sl_ratchet_ladder.dart';
import 'package:trading_mt5/data/engine/spread_guard.dart';

void main() {
  group('spread guard (\$1 limit)', () {
    test('the live XRP rollover case is blocked: 0.06 spread x 100 = \$6', () {
      expect(spreadCost(bid: 1.30515, ask: 1.36515, volume: 100, contractSize: 1), closeTo(6.0, 1e-9));
      expect(spreadTooWide(bid: 1.30515, ask: 1.36515, volume: 100, contractSize: 1), isTrue);
    });

    test('a normal XRP spread at 100 is allowed', () {
      expect(spreadTooWide(bid: 1.3050, ask: 1.3080, volume: 100, contractSize: 1), isFalse); // $0.30
    });

    test('ETH 0.3 with a ~\$1.5 spread is allowed (\$0.45)', () {
      expect(spreadTooWide(bid: 2438.0, ask: 2439.5, volume: 0.3, contractSize: 1), isFalse);
    });

    test('exactly at the limit is allowed; just over is blocked', () {
      expect(spreadTooWide(bid: 1.00, ask: 1.01, volume: 100, contractSize: 1), isFalse); // $1.00
      expect(spreadTooWide(bid: 1.00, ask: 1.0101, volume: 100, contractSize: 1), isTrue); // $1.01
    });
  });

  group('copy -\$1 stop-loss survivability', () {
    test('the live ETH copy case is refused: \$1 SL distance inside a ~\$2 spread', () {
      expect(
        copyStopLossSurvives(bid: 2447.6, ask: 2449.8, volume: 1, contractSize: 1, point: 0.1, stopsLevelPoints: 0),
        isFalse,
      );
    });

    test('a cheap pair (DOGE, 1 lot = 1 coin here) easily survives', () {
      // 1 lot DOGE at contract size 1: \$1 SL = \$1 of price, spread 0.0006.
      expect(
        copyStopLossSurvives(bid: 0.0812, ask: 0.0818, volume: 1, contractSize: 1, point: 0.00001, stopsLevelPoints: 0),
        isTrue,
      );
    });

    test('the broker minimum stop distance counts too', () {
      // spread 0.5 + 10 points * 0.1 = 1.5 minimum > \$1 distance -> refused
      expect(
        copyStopLossSurvives(bid: 100.0, ask: 100.5, volume: 1, contractSize: 1, point: 0.1, stopsLevelPoints: 10),
        isFalse,
      );
    });
  });

  group('SLL dollar ladder (same rung functions, fed live profit in \$)', () {
    test('the ETH case: +\$5.10 profit now locks +\$2 (it never moved under the % ladder)', () {
      final rung = highestSlRatchetThresholdCrossed(5.10);
      expect(rung, 5);
      expect(slRatioForThreshold(rung!), 2);
    });

    test('below +\$5 nothing locks (the -\$5 baseline still applies)', () {
      expect(highestSlRatchetThresholdCrossed(4.99), isNull);
    });

    test('+\$12 locks +\$5; +\$17 locks +\$10', () {
      expect(slRatioForThreshold(highestSlRatchetThresholdCrossed(12)!), 5);
      expect(slRatioForThreshold(highestSlRatchetThresholdCrossed(17)!), 10);
    });
  });
}
