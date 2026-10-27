import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/close_fill.dart';

void main() {
  // The live pre-close snapshot and MT5 history record of BCH ticket
  // 1662352559, closed 2026-10-27 18:00:51Z.
  final snapshot = <String, dynamic>{
    'position_id': '1662352559',
    'action': 'buy',
    'volume': 0.04,
    'price_open': 273.35,
    'price_last': 290.45,
    'profit': 0.684,
  };
  final record = <String, dynamic>{
    'position_id': '1662352559',
    'type': 'buy',
    'open_price': 273.35,
    'close_price': 290.25,
    'commission': -0.1,
    'swaps': -0.01,
    'profit': 0.68,
  };

  test('uses the real close price and profit from the history record', () {
    final out = withActualCloseFill(snapshot, [record], 1662352559);
    expect(out['price_last'], 290.25);
    expect(out['profit'], 0.68);
    expect(out['price_open'], 273.35);
    expect(out['volume'], 0.04);
    expect(snapshot['price_last'], 290.45, reason: 'input must not be mutated');
  });

  test('keeps the snapshot when the ticket is not in history yet', () {
    final other = {...record, 'position_id': '1'};
    expect(identical(withActualCloseFill(snapshot, [other], 1662352559), snapshot), isTrue);
    expect(identical(withActualCloseFill(snapshot, const [], 1662352559), snapshot), isTrue);
  });

  test('matches a numeric position_id too', () {
    final out = withActualCloseFill(snapshot, [{...record, 'position_id': 1662352559}], 1662352559);
    expect(out['price_last'], 290.25);
  });

  test('a record with neither close price nor profit changes nothing', () {
    final bare = {'position_id': '1662352559'};
    expect(identical(withActualCloseFill(snapshot, [bare], 1662352559), snapshot), isTrue);
  });
}
