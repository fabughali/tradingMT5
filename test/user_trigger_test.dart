import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/user_trigger_check.dart';
import 'package:trading_mt5/data/identity/user_trigger_store.dart';

void main() {
  group('userTriggerHit - each trigger compared in its own unit', () {
    test('P&L % TP / SL', () {
      const tp = UserTrigger(TriggerKind.pct, 4);
      const sl = UserTrigger(TriggerKind.pct, -2);
      expect(userTriggerHit(trigger: tp, isTp: true, isLong: true, pct: 3.99), isFalse);
      expect(userTriggerHit(trigger: tp, isTp: true, isLong: false, pct: 4.0), isTrue);
      expect(userTriggerHit(trigger: sl, isTp: false, isLong: true, pct: -1.9), isFalse);
      expect(userTriggerHit(trigger: sl, isTp: false, isLong: false, pct: -2.1), isTrue);
    });

    test('dollars, incl. a negative TP (reduce a loss)', () {
      const tp = UserTrigger(TriggerKind.usd, -2);
      expect(userTriggerHit(trigger: tp, isTp: true, isLong: true, usd: -6), isFalse);
      expect(userTriggerHit(trigger: tp, isTp: true, isLong: true, usd: -1.5), isTrue);
      const sl = UserTrigger(TriggerKind.usd, -3);
      expect(userTriggerHit(trigger: sl, isTp: false, isLong: true, usd: -3), isTrue);
    });

    test('price: buy TP above / SL below, sell the mirror', () {
      expect(userTriggerHit(trigger: const UserTrigger(TriggerKind.price, 2.6), isTp: true, isLong: true, price: 2.61), isTrue);
      expect(userTriggerHit(trigger: const UserTrigger(TriggerKind.price, 2.4), isTp: false, isLong: true, price: 2.45), isFalse);
      expect(userTriggerHit(trigger: const UserTrigger(TriggerKind.price, 2.4), isTp: true, isLong: false, price: 2.39), isTrue);
      expect(userTriggerHit(trigger: const UserTrigger(TriggerKind.price, 2.6), isTp: false, isLong: false, price: 2.6), isTrue);
      expect(userTriggerHit(trigger: const UserTrigger(TriggerKind.price, 2.6), isTp: false, isLong: false, price: 2.5), isFalse);
    });

    test('unknown live value never fires', () {
      expect(userTriggerHit(trigger: const UserTrigger(TriggerKind.pct, 1), isTp: true, isLong: true), isFalse);
    });
  });

  group('userTriggerInvalidReason - TP better than now, SL worse', () {
    test('running trade', () {
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.pct, 4), isTp: true, isLong: true, pct: 2), isNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.pct, 1), isTp: true, isLong: true, pct: 2), isNotNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.usd, -3), isTp: false, isLong: true, usd: 1), isNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.usd, 2), isTp: false, isLong: true, usd: 1), isNotNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.price, 2.4), isTp: true, isLong: false, price: 2.5), isNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.price, 2.6), isTp: true, isLong: false, price: 2.5), isNotNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.price, 2.6), isTp: false, isLong: false, price: 2.5), isNull);
    });

    test('waiting pair: P&L starts at 0, price needs a direction', () {
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.usd, 5), isTp: true, isLong: null, filled: false), isNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.pct, -1), isTp: true, isLong: null, filled: false), isNotNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.pct, -1), isTp: false, isLong: null, filled: false), isNull);
      expect(userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.price, 2), isTp: true, isLong: null, filled: false), isNotNull);
      expect(
        userTriggerInvalidReason(trigger: const UserTrigger(TriggerKind.price, 2.6), isTp: true, isLong: true, price: 2.5, filled: false),
        isNull,
      );
    });
  });
}
