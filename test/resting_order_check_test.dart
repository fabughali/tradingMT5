import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/resting_order_check.dart';
import 'package:trading_mt5/data/models/trade_direction.dart';

void main() {
  bool check({
    TradeDirection resting = TradeDirection.long,
    TradeDirection next = TradeDirection.long,
    double? sl = 0.0867,
    double targetSl = 0.0867,
    double? tp = 0.2887,
    double targetTp = 0.2887,
  }) => restingOrderNeedsReplace(
    restingDirection: resting,
    newDirection: next,
    restingSl: sl,
    targetSl: targetSl,
    restingTp: tp,
    targetTp: targetTp,
  );

  test('2026-10-25 ADA: SL 0.0867 -> 0.0859 (0.9%) no longer re-places the order', () {
    expect(check(targetSl: 0.0859), isFalse);
  });

  test('a direction change always re-places', () {
    expect(check(next: TradeDirection.short), isTrue);
  });

  test('SL or TP moving more than 1% re-places', () {
    expect(check(targetSl: 0.0800), isTrue);
    expect(check(targetTp: 0.3100), isTrue);
  });

  test('identical levels do nothing', () {
    expect(check(), isFalse);
  });

  test('a resting order with no SL gets one', () {
    expect(check(sl: null), isTrue);
    expect(check(sl: 0), isTrue);
  });
}
