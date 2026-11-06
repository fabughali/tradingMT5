import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/user_trigger_check.dart';

void main() {
  group('brokerSideAction - user TP/SL overrides the trade\'s own TP/SL', () {
    test('setting a trigger removes the default once', () {
      expect(brokerSideAction(userActive: true, saved: null, current: 2.7, isTp: true, isLong: true), BrokerSideAction.remove);
      expect(brokerSideAction(userActive: true, saved: 2.7, current: 0, isTp: true, isLong: true), BrokerSideAction.none);
      // Something put a level back while the trigger is on - removed again.
      expect(brokerSideAction(userActive: true, saved: 2.7, current: 2.7, isTp: true, isLong: true), BrokerSideAction.remove);
      // Trade had no default - saved as 0, nothing sent.
      expect(brokerSideAction(userActive: true, saved: null, current: 0, isTp: false, isLong: true), BrokerSideAction.remove);
    });

    test('removing the trigger restores the default', () {
      expect(brokerSideAction(userActive: false, saved: 2.7, current: 0, isTp: true, isLong: true, price: 2.5),
          BrokerSideAction.restore);
      expect(brokerSideAction(userActive: false, saved: 1.2, current: 0, isTp: false, isLong: true, price: 2.5),
          BrokerSideAction.restore);
      expect(brokerSideAction(userActive: false, saved: 0, current: 0, isTp: true, isLong: true, price: 2.5),
          BrokerSideAction.dropSaved);
      expect(brokerSideAction(userActive: false, saved: 2.7, current: 2.7, isTp: true, isLong: true, price: 2.5),
          BrokerSideAction.dropSaved);
      expect(brokerSideAction(userActive: false, saved: 2.7, current: 0, isTp: true, isLong: true), BrokerSideAction.none);
      expect(brokerSideAction(userActive: false, saved: null, current: 2.7, isTp: true, isLong: true, price: 2.5),
          BrokerSideAction.none);
    });

    test('price already past the default closes, as the default would have', () {
      // buy TP 2.7, price 2.8 - TP would have hit.
      expect(brokerSideAction(userActive: false, saved: 2.7, current: 0, isTp: true, isLong: true, price: 2.8),
          BrokerSideAction.closeDefault);
      // sell SL 2.7, price 2.8.
      expect(brokerSideAction(userActive: false, saved: 2.7, current: 0, isTp: false, isLong: false, price: 2.8),
          BrokerSideAction.closeDefault);
      // sell TP 2.3, price 2.5 - not yet.
      expect(brokerSideAction(userActive: false, saved: 2.3, current: 0, isTp: true, isLong: false, price: 2.5),
          BrokerSideAction.restore);
    });
  });
}
