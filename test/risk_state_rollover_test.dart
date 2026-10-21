import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/models/risk_state.dart';

void main() {
  test('UTC-midnight rollover keeps open positions + cooldown, resets only daily P&L', () {
    final yesterday = RiskState(
      dayStartUtcMs: RiskState.utcMidnightMs(DateTime.now()) - const Duration(days: 1).inMilliseconds,
      dayPnlPct: -3.5,
      openPositions: {'BTCUSD.lv|ONE_HOUR': 1, 'ETHUSD.lv|ONE_HOUR': 1, 'BNBUSD.lv|ONE_HOUR': 1},
      cooldownUntilMs: 123456,
    );
    final today = yesterday.rolledOverToToday();
    expect(today.dayStartUtcMs, RiskState.utcMidnightMs(DateTime.now()));
    expect(today.dayPnlPct, 0);
    // The live bug: these were wiped to {} at 00:00 UTC, so the position
    // cap saw 0 open with ~13 really open.
    expect(today.totalOpenPositions, 3);
    expect(today.cooldownUntilMs, 123456);
    // A copy, not shared - later changes to one must not leak into the other.
    today.openPositions['XRPUSD.lv|ONE_HOUR'] = 1;
    expect(yesterday.totalOpenPositions, 3);
  });
}
