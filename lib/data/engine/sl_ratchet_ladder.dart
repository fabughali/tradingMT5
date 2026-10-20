/// Tightening-only stop-loss ladder keyed off a running position's live
/// floating P&L percentage (2026-10-13, per the user, while exploring
/// porting tradingPionex's "Stop Loss Lock" concept). Deliberately NOT
/// tradingPionex's own +100%/+200% thresholds — studied this account's own
/// real trade history first (123 real app-driven closed trades, computed
/// each one's actual peak floating P&L% from real MT5 H1 candle data, not
/// just the final close): 94% never even reached +10% peak, and every
/// single one of the 7 that DID cross +10% went on to close at a LOSS —
/// full swings of 20-37 percentage points (e.g. ALGOUSD.lv peaked +18.48%,
/// closed at -18.41%). tradingPionex's +100% gate would never have fired
/// once against this account's real behavior. This ladder uses half-size
/// rungs (5% steps, not 10%) scaled to the range that actually matters
/// here, per the user's own confirmed table.
library;

///
/// 2026-10-20 (v1.6.32), per the user: the ladder is now keyed off live
/// PROFIT IN DOLLARS, not P&L% of notional - same rung table, so +$5 locks
/// +$2, +$10 locks +$5, +$15 locks +$10, ... The functions below are unit-
/// agnostic; the engine feeds them dollars.

/// Highest rung (5, 10, 15, 20, 25, ...) [pnl] has crossed, or null if
/// still below the first rung (+5) or at a loss.
int? highestSlRatchetThresholdCrossed(double pnl) {
  if (pnl < 5) return null;
  return (pnl ~/ 5) * 5;
}

/// The profit to lock in once [threshold] has been crossed. +5 is the one
/// special case (locks to +2, not 0 — matches tradingPionex's own "+10%
/// locks to +5%, not 0%" precedent for its first rung); every rung from
/// +10 on is just threshold-5.
double slRatioForThreshold(int threshold) =>
    threshold == 5 ? 2 : (threshold - 5).toDouble();
